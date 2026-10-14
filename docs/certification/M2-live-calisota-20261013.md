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
