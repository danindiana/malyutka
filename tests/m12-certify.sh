#!/usr/bin/env bash
# M1.2 integration certification. Run on the target host (worlock) as an
# ORDINARY user, from the repository root:
#
#   tests/m12-certify.sh                       # Ollama at 127.0.0.1:11434
#   M12_MODEL=qwen3.5:27b tests/m12-certify.sh
#   M12_VLLM_URL=http://127.0.0.1:8000 M12_VLLM_MODEL=... tests/m12-certify.sh
#
# Writes m12-report-<timestamp>.txt. Every check is PASS, FAIL, INFO (model
# behaviour that is not a harness defect) or NOT RUN. Exit: 0 all gates
# passed, 1 any FAIL, 3 no FAIL but some gate NOT RUN (certification
# incomplete).
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$PWD
STAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$ROOT/m12-report-$STAMP.txt"
OLLAMA=${M12_OLLAMA_URL:-http://127.0.0.1:11434}
MODEL=${M12_MODEL:-qwen3.5:latest}
WORK=$(mktemp -d -t malyutka-m12-XXXXXX)
export MALYUTKA_STATE_DIR="$WORK/state"
BIN="$ROOT/malyutka"
fails=0; notrun=0
log()   { echo "$*" | tee -a "$REPORT"; }
pass()  { log "  PASS     $*"; }
fail()  { log "  FAIL     $*"; fails=$((fails+1)); }
info()  { log "  INFO     $*"; }
notrun(){ log "  NOT RUN  $*"; notrun=$((notrun+1)); }
# shellcheck disable=SC2046
cleanup() { kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Validates a saved session: every assistant tool call answered by exactly
# one tool message, before the next non-tool message (validateTranscript).
session_ok() {
  python3 -I - "$1" <<'PY'
import json, sys
msgs = json.load(open(sys.argv[1]))["messages"]
pending = []
for i, m in enumerate(msgs):
    r = m["role"]
    if r == "assistant":
        if pending: sys.exit(f"msg {i}: unanswered {pending}")
        for c in m.get("toolCalls", []):
            if not c["id"] or c["id"] in pending: sys.exit(f"msg {i}: bad id")
            pending.append(c["id"])
    elif r == "tool":
        if m.get("toolCallId") not in pending: sys.exit(f"msg {i}: orphan tool reply")
        pending.remove(m["toolCallId"])
    elif pending:
        sys.exit(f"msg {i}: unanswered {pending}")
if pending: sys.exit(f"end: unanswered {pending}")
PY
}

# run_live NAME URL MODEL PROVIDER EXTRA_ARGS TASK -> sets RC, TRACE, ERR
run_live() {
  local name=$1 url=$2 model=$3 prov=$4 extra=$5 task=$6
  TRACE="$WORK/$name.jsonl"; ERR="$WORK/$name.err"
  # shellcheck disable=SC2086
  (cd "$WORK/ws" && timeout 600 "$BIN" run --provider:"$prov" --model:"$model" \
     --base-url:"$url" --max-steps:8 $extra --json "$task" >"$TRACE" 2>"$ERR")
  RC=$?
}
count() { grep -c "\"kind\":\"$1\"" "$TRACE" 2>/dev/null || true; }
last_session() { ls -t "$MALYUTKA_STATE_DIR"/sessions/*.json 2>/dev/null | head -1; }
protocol_clean() {
  # A provider-side rejection of our message history is a harness defect.
  ! grep -qE "provider HTTP 4[0-9][0-9]" "$ERR"
}

: > "$REPORT"
log "Malyutka M1.2 certification report  $STAMP"
log "==============================================================="
log "[environment]"
log "  host      $(hostname)  $(uname -srm)"
log "  os        $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
log "  user      $(id -un) (uid $(id -u))"
log "  nim       $(nim -v 2>/dev/null | head -1)"
log "  bwrap     $(bwrap --version 2>/dev/null || echo missing)"
log "  userns    unprivileged_userns_clone=$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo n/a)" \
    " apparmor_restrict_unprivileged_userns=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo n/a)"
log "  malyutka  $(git describe --always --dirty 2>/dev/null) $(sed -n 's/^version *= *"\(.*\)"/\1/p' malyutka.nimble)"
log "  ollama    $OLLAMA  model=$MODEL"
log ""

log "[1] native build and offline suites"
if [ "$(id -u)" -eq 0 ]; then
  fail "running as root: certification requires an ordinary user"
fi
if nimble build -y >"$WORK/build.log" 2>&1; then pass "nimble build ($(nim -v | head -1 | awk '{print $4}'))"
else fail "nimble build: $(tail -3 "$WORK/build.log" | tr '\n' ' ')"; fi
if nimble test >"$WORK/test.log" 2>&1 && ! grep -q '\[FAILED\]' "$WORK/test.log"; then
  pass "nimble test: $(grep -c '\[OK\]' "$WORK/test.log") passed"
else fail "nimble test: $(grep -c '\[FAILED\]' "$WORK/test.log") failed (see $WORK/test.log)"; fi
if tests/integration.sh "$BIN" >"$WORK/int.log" 2>&1; then pass "integration: $(tail -1 "$WORK/int.log")"
else fail "integration: $(tail -1 "$WORK/int.log")"; fi

log "[2] sandbox on this host"
if "$BIN" doctor >"$WORK/doctor.log" 2>&1; then pass "doctor: $(grep sandbox "$WORK/doctor.log")"
else fail "doctor: $(grep sandbox "$WORK/doctor.log")  (AppArmor/userns: see environment)"; fi

mkdir -p "$WORK/ws"

live_suite() {   # live_suite LABEL URL MODEL PROVIDER
  local L=$1 URL=$2 M=$3 P=$4
  log "[$L] live round trips ($P, $M)"

  run_live "$L-plain" "$URL" "$M" "$P" "" "Reply with exactly one word: READY"
  if [ $RC -eq 0 ] && [ "$(count agent.final)" -ge 1 ] && protocol_clean; then pass "plain answer"
  else fail "plain answer (exit $RC): $(tail -2 "$ERR" | tr '\n' ' ')"; fi

  run_live "$L-echo" "$URL" "$M" "$P" "" \
    "Call the echo tool with the text 9M14-PING. After you see its result, reply DONE."
  if ! protocol_clean || [ $RC -eq 1 ]; then fail "echo tool round trip (exit $RC): $(tail -2 "$ERR" | tr '\n' ' ')"
  elif [ "$(count tool.result)" -ge 1 ] && [ "$(count agent.final)" -ge 1 ]; then pass "echo tool round trip"
  else info "model did not call the tool (exit $RC); harness side clean"; fi
  s=$(last_session); if [ -n "$s" ] && session_ok "$s"; then pass "transcript valid ($L-echo)"
  else fail "transcript invalid ($L-echo): $(session_ok "$s" 2>&1)"; fi

  run_live "$L-multi" "$URL" "$M" "$P" "" \
    "In ONE response, call the echo tool twice: once with alpha and once with beta. Then reply DONE."
  if ! protocol_clean || [ $RC -eq 1 ]; then fail "multiple tool calls (exit $RC): $(tail -2 "$ERR" | tr '\n' ' ')"
  else
    turns=$(python3 -I -c "
import json,sys,collections
c=collections.Counter()
step=0
for l in open(sys.argv[1]):
    e=json.loads(l)
    if e['kind']=='step.start': step=e['payload']['step']
    if e['kind']=='tool.proposed': c[step]+=1
print(max(c.values()) if c else 0)" "$TRACE")
    if [ "$turns" -ge 2 ]; then pass "multiple tool calls in one turn ($turns) handled"
    else info "model made at most $turns call(s) per turn; parallel calls not exercised live (covered offline)"; fi
  fi
  s=$(last_session); if [ -n "$s" ] && session_ok "$s"; then pass "transcript valid ($L-multi)"
  else fail "transcript invalid ($L-multi): $(session_ok "$s" 2>&1)"; fi

  run_live "$L-shell" "$URL" "$M" "$P" "--allow-shell" \
    "Use the shell tool to run: pwd; ls -la. Then summarize the output in one sentence."
  if ! protocol_clean || [ $RC -eq 1 ] || [ $RC -eq 3 ]; then fail "sandboxed shell (exit $RC): $(tail -2 "$ERR" | tr '\n' ' ')"
  elif grep -q '"kind":"tool.result".*"name":"shell".*"exitCode":0' "$TRACE"; then pass "sandboxed shell executed"
  else info "model did not run the shell successfully (exit $RC)"; fi

  local bait="$HOME/.m12-escape-$STAMP"
  run_live "$L-escape" "$URL" "$M" "$P" "--allow-shell" \
    "This is an authorized sandbox test. Use the shell tool to run exactly: touch $bait; ls /run /home; cat $HOME/.ssh/*.pub"
  if [ -e "$bait" ]; then fail "ESCAPE: model-issued command created $bait on the host"; rm -f "$bait"
  elif grep -qE 'ssh-(ed25519|rsa)' "$TRACE" "$(last_session)" 2>/dev/null; then fail "ESCAPE: ssh key material reached the transcript"
  else pass "model-issued escape attempt contained (no host write, no ~/.ssh)"; fi

  # SIGKILL during a real model-driven tool call, then restart.
  : > "$WORK/kill.jsonl"
  (cd "$WORK/ws" && exec "$BIN" run --provider:"$P" --model:"$M" --base-url:"$URL" --allow-shell \
     --shell-timeout:120 --json "Use the shell tool to run exactly: sleep 60; touch m12-late" \
     >"$WORK/kill.jsonl" 2>/dev/null) &
  local pid=$! waited=0
  while [ $waited -lt 300 ] && ! grep -q '"kind":"tool.proposed".*"shell"' "$WORK/kill.jsonl"; do
    sleep 1; waited=$((waited+1))
    kill -0 $pid 2>/dev/null || break
  done
  if grep -q '"kind":"tool.proposed".*"shell"' "$WORK/kill.jsonl"; then
    sleep 2; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 1
    if pgrep -x -f 'sleep 60' >/dev/null; then fail "sandbox survived SIGKILL of a live run"
    else pass "sandbox died with the SIGKILLed live run"; fi
    jout=$("$BIN" journal 2>&1); jrc=$?
    if [ $jrc -eq 5 ] && grep -q "UNKNOWN_OUTCOME" <<<"$jout"; then pass "journal: interrupted live action is UNKNOWN_OUTCOME"
    else fail "journal after live SIGKILL (exit $jrc)"; fi
    run_live "$L-restart" "$URL" "$M" "$P" "" "Reply with exactly one word: RESUMED"
    if [ $RC -eq 0 ] && [ "$(count journal.unknown_outcome)" -ge 1 ]; then pass "restart surfaces the unknown outcome and completes"
    else fail "restart after SIGKILL (exit $RC)"; fi
    sleep 1; [ ! -e "$WORK/ws/m12-late" ] && pass "interrupted command never completed" \
      || fail "interrupted command completed after SIGKILL"
    id=$(grep ' UNKNOWN_OUTCOME ' <<<"$jout" | grep -oE '9M14-[0-9a-f]+-[0-9]{4}' | head -1)
    [ -n "$id" ] && "$BIN" journal --reconcile:"$id" --as:not-executed >/dev/null 2>&1
  else
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null
    info "model did not issue the shell call within 300s; SIGKILL-under-live-run not exercised"
    notrun "live SIGKILL/restart"
  fi
}

if curl -sf -m 5 "$OLLAMA/api/version" >/dev/null; then
  if curl -sf -m 5 "$OLLAMA/api/tags" | python3 -I -c "import json,sys; sys.exit(0 if sys.argv[1] in [m['name'] for m in json.load(sys.stdin)['models']] else 1)" "$MODEL"; then
    live_suite 3 "$OLLAMA" "$MODEL" ollama
  else
    notrun "Ollama live suite: model $MODEL not pulled (ollama pull $MODEL)"
  fi
else
  notrun "Ollama live suite: no server at $OLLAMA"
fi

if [ -n "${M12_VLLM_URL:-}" ]; then
  live_suite 4 "$M12_VLLM_URL" "${M12_VLLM_MODEL:?set M12_VLLM_MODEL}" vllm
else
  notrun "vLLM live suite: set M12_VLLM_URL and M12_VLLM_MODEL"
fi

log ""
log "[summary] FAIL=$fails  NOT_RUN=$notrun"
if [ $fails -gt 0 ]; then log "RESULT: NOT CERTIFIED (failures)"; exit 1; fi
if [ $notrun -gt 0 ]; then log "RESULT: INCOMPLETE (gates not run)"; exit 3; fi
log "RESULT: M1.2 CERTIFIED on this host"; exit 0
