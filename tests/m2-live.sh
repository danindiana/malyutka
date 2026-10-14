#!/usr/bin/env bash
# M2 live validation: drives the real harness with real local models (Ollama)
# through the file tools, approvals, resume, memory and mandates, and checks
# what the HARNESS did, never what the model said.
#
#   tests/m2-live.sh                              # M2_MODELS="qwen3.5:9b"
#   M2_MODELS="qwen3.5:9b devstral-small-2:24b" tests/m2-live.sh
#
# Env: M2_OLLAMA_URL (default http://127.0.0.1:11434), M2_ATTEMPTS (3 per
# check), M2_TIMEOUT seconds per run (240), M2_BIN (./malyutka), M2_CHECKS (space
# separated subset, default all), M2_SEARXNG_URL (a SearXNG with json enabled; enables the websearch check), M2_KEEP=1 (keep the scratch dir and print it).
# Needs bubblewrap for the shell checks, python3, and a built ./malyutka.
#
# Results per model and check:
#   PASS   the harness did what the spec says
#   FAIL   a HARNESS invariant broke (unmatched decision, escape, corrupt journal...)
#   SKIP   the model never produced the behaviour the check needs after all
#          attempts: not a harness fault, but the check proves nothing
# Exit: 0 no FAIL; 1 any FAIL; 3 no FAIL but some check never passed on any model.
# Writes m2-live-report-<stamp>.txt (gitignored).
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$PWD
HERE=$ROOT/tests
BIN=${M2_BIN:-$ROOT/malyutka}
OLLAMA=${M2_OLLAMA_URL:-http://127.0.0.1:11434}
MODELS=${M2_MODELS:-qwen3.5:9b}
ATTEMPTS=${M2_ATTEMPTS:-3}
TMO=${M2_TIMEOUT:-240}
STAMP=$(date +%Y%m%d-%H%M%S)-$$
REPORT="$ROOT/m2-live-report-$STAMP.txt"
WORK=$(mktemp -d -t malyutka-m2live-XXXXXX)
fails=0; skips=0
declare -A passed_anywhere=() seen_check=()
log()  { echo "$*" | tee -a "$REPORT"; }
cleanup() { cd "$ROOT" || return; if [ -n "${M2_KEEP:-}" ]; then echo "scratch kept: $WORK"; else rm -rf "${WORK:?}"; fi; }
trap cleanup EXIT

[ -x "$BIN" ] || { echo "build first: nimble build -y" >&2; exit 2; }
curl -fsS "$OLLAMA/api/tags" >/dev/null 2>&1 || { echo "no Ollama at $OLLAMA" >&2; exit 2; }
log "M2 live validation $STAMP"
log "  host     $(uname -sr), $(lsb_release -ds 2>/dev/null || echo unknown)"
log "  harness  $("$BIN" doctor 2>/dev/null | head -1)"
log "  models   $MODELS"

chk() { python3 -I "$HERE/m2_live_check.py" "$@"; }

# run NAME MODEL PROMPT [extra flags...]; trace -> $WORK/NAME.trace, stderr -> .err
run() {
  local name=$1 model=$2 prompt=$3; shift 3
  timeout "$TMO" "$BIN" run --provider:ollama --model:"$model" --base-url:"$OLLAMA" \
    --json --theme:plain "$@" "$prompt" > "$WORK/$name.trace" 2> "$WORK/$name.err" < /dev/null
  RC=$?
}
# Harness invariants that must hold whatever the model did.
invariants() { # name -> 0 ok, 1 harness violation, 2 provider flake (retry)
  local v rc
  v=$(chk invariants "$WORK/$1.trace"); rc=$?
  if [ $rc -ne 0 ]; then
    # A run killed by the timeout (124) or dead on a provider error (1) is cut off
    # mid-flight: re-check with only what a cut-off trace may leave open. If that
    # passes it is an environment flake (retry); if not, it is a real violation.
    if [ "${RC:-0}" -eq 1 ] || [ "${RC:-0}" -eq 124 ]; then
      if chk invariants --partial "$WORK/$1.trace" >/dev/null; then
        log "      cut-off run in $1 (exit $RC, timeout or provider error): $(tail -n 2 "$WORK/$1.err" | tr '\n' ' ')"
        return 2
      fi
      v=$(chk invariants --partial "$WORK/$1.trace")
    fi
    log "      invariant violation in $1: $v"
    return 1
  fi
  "$BIN" journal >/dev/null 2>&1
  local jr=$?
  [ $jr -eq 0 ] || { log "      journal unhealthy after $1 (exit $jr)"; return 1; }
  return 0
}
verdict() { # model check status(pass|fail|skip) note
  local m=$1 c=$2 s=$3 note=${4:-}
  seen_check[$c]=1
  case $s in
    pass) log "  PASS  [$m] $c"; passed_anywhere[$c]=1 ;;
    fail) log "  FAIL  [$m] $c $note"; fails=$((fails+1)) ;;
    skip) log "  SKIP  [$m] $c $note"; skips=$((skips+1)) ;;
  esac
}
# attempt MODEL CHECK FN: FN returns 0 pass, 1 harness FAIL, 2 model-did-not-comply (retry)
attempt() {
  local m=$1 c=$2 fn=$3 i rc
  for i in $(seq 1 "$ATTEMPTS"); do
    "$fn" "$m" "$i"; rc=$?
    [ $rc -eq 0 ] && { verdict "$m" "$c" pass; return; }
    [ $rc -eq 1 ] && { verdict "$m" "$c" fail "(attempt $i)"; return; }
  done
  verdict "$m" "$c" skip "(model did not comply in $ATTEMPTS attempts)"
}

fresh() { # name -> new workspace + state (inside $WORK), cd into the workspace
  local d="${WORK:?}/$1"
  rm -rf "$d"
  mkdir -p "$d/ws"
  export MALYUTKA_STATE_DIR="$d/state"
  cd "$d/ws" || exit 2
}

# ---- checks -----------------------------------------------------------------
c_files() { # model attempt
  fresh "files-$2"
  run "files-$2" "$1" "Use the write_file tool to create notes/hello.txt containing exactly: alpha beta gamma. Then use patch to replace beta with BETA. Then read_file it and report the content." --allow-files
  invariants "files-$2" || return $?
  [ -f notes/hello.txt ] || return 2
  grep -q 'alpha BETA gamma' notes/hello.txt || return 2
  chk has "$WORK/files-$2.trace" policy.decision verdict=ALLOW || return 2
  return 0
}
c_shell_and_files() {
  fresh "sf-$2"
  run "sf-$2" "$1" "Write a file calc.py that prints 6*7 using write_file, then run it with the shell tool (python3 calc.py) and tell me the output." --allow-files --allow-shell
  invariants "sf-$2" || return $?
  [ -f calc.py ] || return 2
  chk has "$WORK/sf-$2.trace" tool.proposed name=shell || return 2
  grep -q '42' "$WORK/sf-$2.err" || return 2
  return 0
}
# Answer EVERY approval.request in NAME.trace over fifo fd 7 until the harness (PID)
# exits: a model may retry a denied or approved command and raise a second ASK.
responder() { # name answer
  local name=$1 answer=$2 aid
  declare -A done_ids=()
  while kill -0 "$PID" 2>/dev/null; do
    while read -r aid; do
      [ -n "$aid" ] && [ -z "${done_ids[$aid]:-}" ] || continue
      done_ids[$aid]=1
      echo "{\"action\":\"$aid\",\"answer\":\"$answer\"}" >&7
    done < <(grep '"approval.request"' "$WORK/$name.trace" 2>/dev/null | grep -oE '"action":"[^"]+"' | cut -d'"' -f4)
    sleep 0.2
  done
}
ask_run() { # name model answer-or-"" [extra flags...]
  local name=$1 model=$2 answer=$3; shift 3
  rm -f "$WORK/$name.fifo"
  mkfifo "$WORK/$name.fifo"
  timeout "$TMO" "$BIN" run --provider:ollama --model:"$model" --base-url:"$OLLAMA" --json --theme:plain \
    --allow-shell --approvals:stdin --approval-timeout:60 "$@" \
    "Run exactly this shell command and nothing else: touch asked.marker; chmod -R 777 ." \
    < "$WORK/$name.fifo" > "$WORK/$name.trace" 2> "$WORK/$name.err" &
  PID=$!
  exec 7> "$WORK/$name.fifo"
  if [ -n "$answer" ]; then responder "$name" "$answer"; fi
  wait $PID; RC=$?
  exec 7>&-
}
c_ask_deny() {
  fresh "askd-$2"; ask_run "askd-$2" "$1" deny
  invariants "askd-$2" || return $?
  chk has "$WORK/askd-$2.trace" approval.request || return 2
  [ ! -e asked.marker ] || { log "      denied command ran anyway"; return 1; }
  chk has "$WORK/askd-$2.trace" approval.answer answer=deny || return 1
  return 0
}
c_ask_once() {
  fresh "aske-$2"; ask_run "aske-$2" "$1" once
  invariants "aske-$2" || return $?
  chk has "$WORK/aske-$2.trace" approval.request || return 2
  [ -e asked.marker ] || return 2
  chk has "$WORK/aske-$2.trace" policy.decision policy=approval.user verdict=ALLOW || return 1
  return 0
}
c_ask_timeout() {
  fresh "askt-$2"; ask_run "askt-$2" "$1" "" --approval-timeout:2
  invariants "askt-$2" || return $?
  chk has "$WORK/askt-$2.trace" approval.request || return 2
  [ ! -e asked.marker ] || return 1
  chk has "$WORK/askt-$2.trace" approval.answer answer=deny source=timeout || return 1
  return 0
}
c_resume() {
  fresh "res-$2"
  run "res1-$2" "$1" "Remember this codeword for later: PINEAPPLE-7. Just acknowledge it."
  invariants "res1-$2" || return $?
  run "res2-$2" "$1" "What was the codeword I asked you to remember? Answer with the codeword only." --resume:last
  invariants "res2-$2" || return $?
  grep -qi 'PINEAPPLE-7' "$WORK/res2-$2.err" || return 2
  "$BIN" sessions --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[0]["parent"] else 1)' || return 1
  return 0
}
c_memory() {
  fresh "mem-$2"
  run "mem1-$2" "$1" "Use the memory tool (op add) to save this note: operator prefers tabs over spaces." --allow-memory
  invariants "mem1-$2" || return $?
  [ -f "$MALYUTKA_STATE_DIR/memory.md" ] || return 2
  grep -qi 'tab' "$MALYUTKA_STATE_DIR/memory.md" || return 2
  [ "$(stat -c %a "$MALYUTKA_STATE_DIR/memory.md")" = 600 ] || return 1
  [ ! -e "$PWD/memory.md" ] || return 1
  run "mem2-$2" "$1" "According to your notes, does the operator prefer tabs or spaces? One word." --allow-memory
  grep -qi 'tab' "$WORK/mem2-$2.err" || return 2
  return 0
}
c_mandate() {
  fresh "mand-$2"
  run "mandn-$2" "$1" "Run exactly this shell command: touch mandate.marker" --allow-shell --ask-from:B2 --mandates
  invariants "mandn-$2" || return $?
  [ ! -e mandate.marker ] || { log "      ASK ran without a mandate"; return 1; }
  chk has "$WORK/mandn-$2.trace" tool.proposed name=shell || return 2
  local mid
  mid=$("$BIN" mandate --grant --tools:shell --max-effect:B2 --actions:2 --ttl:600 --goal:live 2>/dev/null | awk '{print $1}')
  [ -n "$mid" ] || return 1
  run "mandy-$2" "$1" "Run exactly this shell command: touch mandate.marker" --allow-shell --ask-from:B2 --mandates
  invariants "mandy-$2" || return $?
  [ -e mandate.marker ] || return 2
  chk has "$WORK/mandy-$2.trace" policy.decision "policy~=mandate:$mid" || return 1
  return 0
}

c_compaction() {
  fresh "cmp-$2"
  run "cmp1-$2" "$1" "Write a 20 line poem about the sea. Also remember my favourite number is 4417."
  invariants "cmp1-$2" || return $?
  run "cmp2-$2" "$1" "What was my favourite number? Answer with the number only." --resume:last --compress
  invariants "cmp2-$2" || return $?
  chk has "$WORK/cmp2-$2.trace" context.compacted || return 2
  local arch; arch=$(ls "$MALYUTKA_STATE_DIR"/sessions/*.archive.jsonl 2>/dev/null | head -1)
  [ -n "$arch" ] && [ "$(stat -c %a "$arch")" = 600 ] || return 1
  "$BIN" sessions --show:last | grep -q 'compacted summary of earlier turns' || return 1
  grep -q '4417' "$WORK/cmp2-$2.err" || return 2
  return 0
}

c_process() {
  fresh "proc-$2"
  local tag="m2tag-$$-p$2"
  run "proc-$2" "$1" "Use the process tool (action start) to run exactly this command in the background: sleep 45 # $tag . Then poll it once, then report its state. Do not kill it." --allow-process --cgroups:off
  invariants "proc-$2" || return $?
  chk has "$WORK/proc-$2.trace" process.started || return 2
  # whatever the model did, nothing may outlive the run (invariant 16)
  local n=1 i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    n=$(chk survivors "$tag"); [ "$n" = 0 ] && break; sleep 0.3
  done
  [ "$n" = 0 ] || { log "      $n process(es) outlived the run"; return 1; }
  return 0
}

# like ask_run, but with its own prompt and flags; every approval.request is answered with $answer
approved_run() { # name model answer prompt [extra flags...]
  local name=$1 model=$2 answer=$3 prompt=$4; shift 4
  rm -f "$WORK/$name.fifo"
  mkfifo "$WORK/$name.fifo"
  timeout "$TMO" "$BIN" run --provider:ollama --model:"$model" --base-url:"$OLLAMA" --json --theme:plain \
    --approvals:stdin --approval-timeout:60 "$@" "$prompt" \
    < "$WORK/$name.fifo" > "$WORK/$name.trace" 2> "$WORK/$name.err" &
  PID=$!
  exec 7> "$WORK/$name.fifo"
  responder "$name" "$answer"
  wait $PID; RC=$?
  exec 7>&-
}
c_skills() {
  fresh "skl-$2"
  approved_run "skl-$2" "$1" once "Save a skill named deploy with the skill_save tool. Its content must be exactly these lines: a line with three dashes, a line 'name: deploy', a line 'description: how to deploy', a line with three dashes, then the text 'run make then ship'. After saving, call skills_list." --skills
  invariants "skl-$2" || return $?
  chk has "$WORK/skl-$2.trace" approval.request tool=skill_save || return 2
  local f="$MALYUTKA_STATE_DIR/skills/deploy/SKILL.md"
  [ -f "$f" ] || return 2
  [ "$(stat -c %a "$f")" = 600 ] || return 1
  [ ! -e "$PWD/skills" ] || return 1
  grep -q 'run make' "$f" || return 2
  return 0
}
c_mcp() {
  fresh "mcp-$2"
  local tag="m2tag-$$-mcp$2"
  cp "$HERE/fake_mcp.py" .
  mkdir -p "$MALYUTKA_STATE_DIR"
  python3 -c 'import json,sys; print(json.dumps({"servers":[{"name":"s","command":["python3","fake_mcp.py","good",sys.argv[1]],"sandbox":True,"maxEffect":"B1","trust":"ask","timeoutSec":20,"envAllow":[]}]}))' "$tag" > "$MALYUTKA_STATE_DIR/mcp.json"
  chmod 600 "$MALYUTKA_STATE_DIR/mcp.json"
  approved_run "mcp-$2" "$1" once "Use the mcp_s_add tool to add 19 and 23 and tell me the sum." --mcp
  invariants "mcp-$2" || return $?
  chk has "$WORK/mcp-$2.trace" mcp.connected || return 1
  chk has "$WORK/mcp-$2.trace" tool.proposed name=mcp_s_add || return 2
  chk has "$WORK/mcp-$2.trace" approval.request tool=mcp_s_add || return 1     # MCP never runs unasked
  grep -q '42' "$WORK/mcp-$2.err" || return 2
  local n=1 i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    n=$(chk survivors "$tag"); [ "$n" = 0 ] && break; sleep 0.3
  done
  [ "$n" = 0 ] || { log "      $n MCP server process(es) outlived the run"; return 1; }
  return 0
}

c_web() {
  fresh "web-$2"
  curl -fsS -m 8 -o /dev/null https://example.com || { log "      (no internet: skipping)"; return 2; }
  approved_run "web-$2" "$1" once "Use the web_fetch tool to fetch https://example.com/ and tell me the page title. Answer with the title only." --web
  invariants "web-$2" || return $?
  chk has "$WORK/web-$2.trace" approval.request tool=web_fetch || return 2      # a web call never runs unasked
  chk has "$WORK/web-$2.trace" web.fetched host=example.com || return 2
  grep -qi 'example domain' "$WORK/web-$2.err" || return 2
  return 0
}

c_websearch() {
  fresh "wsr-$2"
  [ -n "${M2_SEARXNG_URL:-}" ] || { log "      (set M2_SEARXNG_URL to a SearXNG with the json format enabled: skipping)"; return 2; }
  mkdir -p "$MALYUTKA_STATE_DIR"
  python3 -c 'import json,sys; print(json.dumps({"search":{"backend":"searxng","searxng":{"url":sys.argv[1],"trust":"allow"}}}))' "$M2_SEARXNG_URL" > "$MALYUTKA_STATE_DIR/web.json"
  chmod 600 "$MALYUTKA_STATE_DIR/web.json"
  approved_run "wsr-$2" "$1" once "Use the web_search tool to search for: nim programming language. Then tell me the URL of the official Nim website. Answer with the URL only." --web
  invariants "wsr-$2" || return $?
  chk has "$WORK/wsr-$2.trace" tool.proposed name=web_search || return 2
  chk has "$WORK/wsr-$2.trace" web.searched backend=searxng || return 2
  chk has "$WORK/wsr-$2.trace" approval.request tool=web_search && { log "      a trusted loopback search asked"; return 1; }
  grep -qi 'nim-lang.org' "$WORK/wsr-$2.err" || return 2
  return 0
}

ALL_CHECKS="files shell_and_files ask_deny ask_once ask_timeout resume memory mandate compaction process skills mcp web websearch"
CHECKS=${M2_CHECKS:-$ALL_CHECKS}
for m in $MODELS; do
  log ""; log "== model $m"
  if ! curl -fsS "$OLLAMA/api/tags" | python3 -c 'import json,sys; n=sys.argv[1]; sys.exit(0 if any(x["name"]==n for x in json.load(sys.stdin)["models"]) else 1)' "$m"; then
    log "  SKIP  [$m] model not installed"; skips=$((skips+1)); continue
  fi
  for c in $CHECKS; do attempt "$m" "$c" "c_$c"; done
done

log ""
never=""
for c in $CHECKS; do
  if [ -n "${seen_check[$c]:-}" ] && [ -z "${passed_anywhere[$c]:-}" ]; then never="$never $c"; fi
done
log "summary: FAIL=$fails SKIP=$skips"
[ -n "$never" ] && log "checks that never passed on any model (they prove nothing):$never"
[ $fails -gt 0 ] && exit 1
[ -n "$never" ] && exit 3
exit 0
