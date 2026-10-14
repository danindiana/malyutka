# M2 live validation record: calisota, 2026-10-13

**Result: PASS (FAIL=0, SKIP=0) on 4 local models, 8 checks each.**
Harness 0.5.0 (file tools, ASK approvals, commitment latch, sessions/resume,
memory) driven by real models through `tests/m2-live.sh`.

## What was run

| Item | Value |
|---|---|
| Host | Ubuntu 22.04.5, kernel 6.8, Nim 2.2.12, bubblewrap 0.6.1, Ollama local, 2 GPUs (RTX 4080 SUPER 16 GB, RTX 5070 12 GB), unprivileged user |
| Kernel | `sha256(sha256sum of src/malyutka.nim src/malyutka/*.nim) = c190f40beb91c212f43239f5ab9fff915b7d0d126f3f74cb0368cd188a8d020c` |
| Battery | `sha256(tests/m2-live.sh) = 398b7f5d6ad956421c69cef0c2f2ed0c8d5cb35f05c6de8f9b3e4d8fcfc5f62f` |
| Checkout | `a7734cb` (v0.5.0 plus the live-validation branch; the harness sources are unchanged by it) |
| Models | `qwen3.5:9b`, `qwen3.5:27b`, `devstral-small-2:24b`, `gpt-oss:20b` |

## Checks (every one asserts on harness behaviour, never on model prose)

| Check | What must hold |
|---|---|
| files | write_file + patch + read_file landed in the workspace; decisions ALLOW |
| shell_and_files | file tool and sandboxed shell in one run; shell output reached the model |
| ask_deny | an ASK (recursive chmod 777) produced `approval.request`; answer `deny` over the stdin channel; the command did **not** run |
| ask_once | answer `once`: the command ran; decision names `approval.user` |
| ask_timeout | no answer within `--approval-timeout:2`: DENY with source `timeout`; command did not run |
| resume | second run with `--resume:last` recalled a codeword; session records its parent |
| memory | `memory` tool wrote `memory.md` (0600) in the state dir, not the workspace; a later run used it |
| mandate | the same ASK without a mandate was denied and did not run; after `mandate --grant`, it ran and the decision named `mandate:<id>` |

Always asserted, whatever the model did (`tests/m2_live_check.py invariants`):
exactly one policy decision per proposal, exactly one terminal result per
ALLOWed call, no result for a non-ALLOW decision, the run ends in
`agent.final`/`agent.halt`, and the journal is healthy afterwards.

## Results

| Model | files | shell+files | ask_deny | ask_once | ask_timeout | resume | memory | mandate |
|---|---|---|---|---|---|---|---|---|
| qwen3.5:9b | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| qwen3.5:27b | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| devstral-small-2:24b | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| gpt-oss:20b | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |

Also exercised by hand with `qwen3.5:9b` in the TUI (tmux): write/patch diff
view, the approval modal with its countdown and deny, `/undo`, `/mandates`.

## How the battery itself was corrected during this run (kept for honesty)

- The first run SKIPped the three approval checks: the prompt asked for
  `chmod -R 755`, which the dangerous-command rule (correctly) does not match.
  The prompt now uses `chmod -R 777`.
- One run failed the mandate check with "run ended without agent.final or
  agent.halt". Re-running the same scenario by hand three times ended cleanly
  each time; the likely cause is a failed provider request (a run that dies on a
  provider error has no final event by design). The battery now classifies that
  as a provider flake (retry), prints the stderr tail when it happens, and
  still fails on any other invariant violation. The cause of the one original
  occurrence was not captured, so it is not proven to be a provider error.
- The assertion helper is self-tested with mutated traces
  (`tests/m2_live_check_selftest.py`, run in CI).

## Not established

- Ubuntu 24.04 with the AppArmor user-namespace restriction active (still open
  from M1.2), vLLM, and any model not listed above.
- Behaviour under long contexts (no compaction yet) and background processes
  (not implemented yet): Rounds 2 and 3.
- Model-prose quality: not asserted anywhere in this battery.

## Addendum (Round 2, v0.6.0): compaction check

A ninth check, `compaction`, was added: run 1 asks for a 20-line poem plus a number to remember;
run 2 resumes with `--compress`. The harness must emit `context.compacted`, write the archive
(0600), leave the labelled summary (not the dropped turns) in the session, and the model's later
answer must still contain the number.

| Model | compaction |
|---|---|
| qwen3.5:9b | PASS on its first run (summary kept the number; archive 2 messages); **SKIP** on two later runs, see below |
| qwen3.5:27b | PASS |
| devstral-small-2:24b | PASS |
| gpt-oss:20b | PASS |

- **qwen3.5:9b SKIPs are an Ollama-side failure, not a harness failure.** The log shows
  `provider HTTP 500: {"error":{"message":"XML syntax error on line 22: element <function> closed by </parameter>"}}`:
  Ollama's tool-call parser rejected the model's output. The harness reported it correctly
  (`guidance failure`, exit 1) and the battery classified the run as cut off. This also explains the
  one unreproduced failure recorded above: it is very likely the same error. The harness has no
  retry for transient provider errors (a `todo/` item).
- **gpt-oss:20b `ask_once` was skipped twice in one full run** (exit 124, killed by the 300 s limit) and
  failed once in an earlier run with a truncated trace. Cause: my responder answered only the *first*
  approval request, so when the model retried the command the second ASK waited out the
  approval timeout (300 s = the run limit). The responder now answers every request, the battery uses
  `--approval-timeout:60`, and the checker has a `--partial` mode so a killed run is only excused for what
  a kill can leave open (the last proposal / result). Afterwards `ask_deny`, `ask_once`, `ask_timeout`
  passed on gpt-oss:20b in two consecutive runs.
- Final state of the full 4-model run before those two battery fixes: FAIL=0, SKIP=2 (the two cases
  above); after them, the affected checks pass on rerun except the Ollama-side qwen3.5:9b compaction case.

## Addendum (Round 3, v0.7.0): process check

A tenth check, `process`, asks the model to start `sleep 45 # <unique tag>` with the `process` tool, poll it, and
report; whatever it did, the harness must have emitted `process.started` and **no process carrying the tag may
survive the run** (read from `/proc/*/cmdline`, excluding the checker itself).

| Model | process |
|---|---|
| qwen3.5:9b | PASS |
| gpt-oss:20b | PASS |

Only these two models were run for this check. The same work found and fixed a real bug that the first version
of the unit tests did not catch: killing the outer `bwrap` immediately after start could orphan the sandbox (see
CHANGELOG 0.7.0 and invariant 16); the live check and the integration test (`SIGKILL` of the harness while a
process runs) would have flagged it.

Host facts recorded for the limits backend: cgroup v2; `user@1000.service` delegated, but the login session
(`session-c1.scope`) is outside it and a process cannot be migrated across (EACCES), so limits use
`systemd-run --user --scope`, which works here (verified: fork loop capped with `Cannot fork`, a 900 MB
allocation killed under a 200 MB limit and succeeding with no limit). Not verified: CI runners and containers
(the code degrades visibly; CI exercises the degraded path and skips the real-scope tests if they cannot run).
