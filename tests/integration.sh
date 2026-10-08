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
cleanup() { kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$WORK/ws" && cd "$WORK/ws"
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

# 6. Fail closed: no usable sandbox -> refuse to run.
PATH=/nonexistent "$BIN" run --allow-shell 'x' >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && ok "no bwrap -> refuses to run (exit 3)" || bad "no bwrap exit $rc"

# 7. Workspace guard: refuse $HOME as workspace.
(cd "$HOME" && "$BIN" run --allow-shell 'x' >/dev/null 2>&1); rc=$?
[ $rc -eq 3 ] && ok "\$HOME as workspace -> refused (exit 3)" || bad "\$HOME workspace exit $rc"

echo "integration: $pass passed, $fail failed"
[ $fail -eq 0 ]
