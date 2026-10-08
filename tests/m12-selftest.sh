#!/usr/bin/env bash
# Tests the M1.2 certification SCRIPT against a stand-in model server: each
# scenario has a known correct verdict. Mutations are applied to COPIES of the
# script (the real script carries no test hooks). Run as an ordinary user from
# the repository root:  tests/m12-selftest.sh
# Exit 0 iff every scenario produced its expected verdict.
set -u
cd "$(dirname "$0")/.." || exit 2
REAL=${M12_SELFTEST_TARGET:-tests/m12-certify.sh}   # mutation testing of the certifier
PORT=$((21000 + $$ % 5000))
pass=0; fail=0
ok()  { echo "  [OK] $1"; pass=$((pass+1)); }
bad() { echo "  [FAILED] $1"; fail=$((fail+1)); }

# A copy with the offline block (build + suites) replaced by a stub, so live
# scenarios are fast and their exit codes stay discriminating.
stubbed() {
  local out=tests/.m12-selftest-$1.sh
  awk '/^# >>> offline/{print; print "pass \"offline suites (stubbed by m12-selftest)\""; print "[ -x \"$BIN\" ] || nimble build -y >/dev/null 2>&1"; skip=1; next}
       /^# <<< offline/{skip=0} !skip' "$REAL" > "$out"
  chmod +x "$out"; echo "$out"
}

# scenario NAME SCRIPT MODE EXPECTED_EXIT "env assignments" -> sets REPORT_TEXT
scenario() {
  local name=$1 script=$2 mode=$3 want=$4 envs=$5
  local port=$((PORT++))
  python3 -I tests/fake_model.py "$port" standin:latest "$mode" & local srv=$!
  sleep 0.6
  rm -f m12-report-*.txt; rm -rf m12-diagnostics-*
  # shellcheck disable=SC2086
  env M12_OLLAMA_URL="http://127.0.0.1:$port" M12_MODEL=standin:latest \
      ${envs//@PORT@/$port} timeout 1200 "$script" >/dev/null 2>&1
  local rc=$?
  kill $srv 2>/dev/null; wait $srv 2>/dev/null
  REPORT_TEXT=$(cat m12-report-*.txt 2>/dev/null)
  if [ $rc -eq "$want" ]; then ok "$name: exit $rc"
  else
    bad "$name: exit $rc, expected $want"
    echo "$REPORT_TEXT" | grep -E "FAIL |NOT RUN|RESULT" | sed 's/^/        /'
    # Keep the evidence of an unexpected verdict (mode 700).
    local keep="m12-selftest-failures/${name%% *}"
    (umask 077 && mkdir -p "$keep") && mv m12-report-*.txt m12-diagnostics-* "$keep"/ 2>/dev/null
    echo "        evidence kept in $keep"
  fi
  rm -f m12-report-*.txt; rm -rf m12-diagnostics-*
}
expect()   { grep -qF -- "$2" <<<"$REPORT_TEXT" && ok "$1" || bad "$1 (missing: $2)"; }
expect_no(){ grep -qF -- "$2" <<<"$REPORT_TEXT" && bad "$1 (present: $2)" || ok "$1"; }

[ "$(id -u)" -ne 0 ] || { echo "run as an ordinary user"; exit 2; }
[ -x ./malyutka ] || nimble build -y >/dev/null 2>&1
STUB=$(stubbed base)
ESC=$(stubbed escape)
sed -i 's|run_live "$L-escape" "$URL" "$M" "$P" "--allow-shell"|run_live "$L-escape" "$URL" "$M" "$P" "--allow-shell --unconfined-host"|' "$ESC"
grep -q -- '--allow-shell --unconfined-host' "$ESC" || { echo "escape mutation did not apply"; exit 2; }
trap 'rm -f tests/.m12-selftest-*.sh' EXIT

echo "[Suite] m12-certify self-test"

scenario "A cooperative, Ollama only (real script, full offline)" "$REAL" coop 0 ""
expect    "A certifies without vLLM"                 "RESULT: M1.2 CERTIFIED"
expect    "A vLLM reported optional"                 "vLLM live suite: optional"
expect    "A kill waited for durable started"        "kill precondition: durable 'started'"
expect    "A interrupted action not reconciled"      "left UNKNOWN_OUTCOME (not reconciled, not re-executed)"
expect    "A full kernel hash recorded"              "kernel    sha256("
expect    "A offline suites actually ran"            "PASS     nimble test:"

scenario "B refusing model" "$STUB" refuse 3 ""
expect    "B tool round trip is a gate NOT RUN"      "NOT RUN  live tool round trip"
expect    "B multi-call is a GAP"                    "GAP      multi-call turn not exercised live"

scenario "C escape mutant (shell unconfined)" "$ESC" coop 1 ""
expect    "C escape detected"                        "FAIL     ESCAPE"

scenario "D kill prompt yields a non-executable call" "$STUB" badtool 3 ""
expect    "D kill gate NOT RUN (never started)"      "never reached a durable 'started'"
expect_no "D no false FAIL"                          "FAIL     "

scenario "E M12_SKIP_OFFLINE (real script)" "$REAL" coop 3 "M12_SKIP_OFFLINE=1"
expect    "E offline gate NOT RUN"                   "NOT RUN  native build + offline suites"
expect_no "E nimble test not executed"               "nimble test:"
expect_no "E integration not executed"               "integration:"

scenario "F vLLM required but unset" "$STUB" coop 3 "M12_REQUIRE_VLLM=1"
expect    "F reported as a gate"                     "required (M12_REQUIRE_VLLM)"

scenario "G vLLM configured but unreachable" "$STUB" coop 3 "M12_VLLM_URL=http://127.0.0.1:1 M12_VLLM_MODEL=x"
expect    "G reported NOT RUN"                       "configured but no server"

scenario "H vLLM configured and reachable" "$STUB" coop 0 "M12_VLLM_URL=http://127.0.0.1:@PORT@ M12_VLLM_MODEL=standin:latest"
expect    "H vLLM suite ran"                         "[4] live round trips (vllm"

echo "m12-selftest: $pass passed, $fail failed"
[ $fail -eq 0 ]
