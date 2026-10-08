# Changelog

## 0.3.3 — Journal integrity

Response to the 0.3.2 audit. All four findings were reproduced against 0.3.2
before being fixed.

| Finding | Reproduced on 0.3.2 | Resolution | Mutation |
|---|---|---|---|
| Records without `crc` accepted | yes: a forged outcome flipped UNKNOWN_OUTCOME → COMPLETED, health OK | `crc`, `w`, `n`, `ts` mandatory; full schema | caught (S1b) |
| Duplicates/reorderings pass (sorted gap check) | yes: a replay passed; a reordering made an executed action read AUTHORIZED | `n` exactly last+1 in file order | survives: transitions catch every exact replay, gaps catch every reordering; kept for future relaxed transitions |
| No transition validation | yes: outcome for a DENIED action; another run writing this run's outcome | per-action state machine; owner-only records | caught (S4–S6) |
| `journal --reconcile` race | yes: 8 concurrent reconciles → 8 records, COMPLETED and FAILED | `Journal.transact`: scan + append under one exclusive lock | caught (S11; CLI: 1 of 6 wins) |

Found while fixing:
- **Operator writer IDs collided.** Every `journal` command wrote as
  `operator-$USER` with `n` restarting at 1, so strict sequencing would have
  reported CORRUPT after the second ack. Writer IDs are now unique per
  handle.
- **Strictness needed liveness.** Reconciling a still-running action, and
  then receiving its real outcome, would have made the journal falsely
  CORRUPT. Each run now holds a flock that the kernel releases on death.
  "Started, no outcome" is IN_PROGRESS while the run lives, and acks or
  reconciles of it are refused.

Migration: none. 0.3.1 journals, and 0.3.2 journals with two operator
commands, read as CORRUPT and must be moved aside. Both versions existed
only on test machines.


## 0.3.2 — "Authority Boundary Hardening"

Response to the independent audit of 0.3.1. Each finding was reproduced
before it was fixed, and each fix was mutation-checked.

| Audit finding | Reproduced? | Resolution |
|---|---|---|
| P0 state dir can sit inside the workspace | yes, by construction | kernel and CLI refuse overlapping canonical paths (incl. symlink aliases); journal opened `O_NOFOLLOW`, must be a regular file owned by the operator |
| P0 concurrent writers uncoordinated | **partly**: concurrent appends never interleaved (8 writers x 500 records, 0 damaged; `O_APPEND` is atomic on Linux), but a torn fragment from one crashed writer **swallowed the next record of a writer that already had the file open** | framing (`\n` + record + `\n`); per-writer sequence numbers + CRC-32; corrupt-vs-torn classification, corrupt fails closed; flock as defense in depth (its mutant survives, documented) |
| P1 lexical workspace validation | **latent**: CLI safe (getcwd returns physical paths), library API accepted a symlink to `$HOME` | realpath + validate the opened fd; bind with `--bind-fd`, so no second resolution (swap-after-check test) |
| P1 unchecked journal repair writes | yes | repair removed entirely; framing makes it unnecessary |
| P1 host-realm process tree | yes | host child leads its own process group with PDEATHSIG; whole group killed on exit/timeout. Deliberate re-parenting (`setsid`) still escapes: cgroup in M3; documented as high risk |
| P2 `requires nim >= 2.0` vs tests on 1.6.14 | yes | `requires nim >= 1.6.14`; compiler matrix documented; Nim 2.2.4 semantic check: 0 diagnostics in Malyutka sources |
| State machine: ack is not reconciliation | — | PREPARED / DENIED / AUTHORIZED / UNKNOWN_OUTCOME / COMPLETED / FAILED / NOT_EXECUTED / RECONCILED / ACKNOWLEDGED_UNRESOLVED; `journal --reconcile:ID --as:…` |

Also found while testing: my own invariant tests had placed the journal
inside the workspace. The new placement check caught it.


## 0.3.1 — M1.1.1 "Confined, honestly"

Response to the M1.1 review. Every fix below came with a test, and each test
was mutation-checked: removing the fix makes it fail.

### Fixed (protocol)
- A repetition halt in the middle of a multi-call turn left tool calls
  unanswered, the same defect class as M1's wire bug. Every proposed call now
  gets exactly one terminal result (`CANCELLED` on halt).
- Missing or duplicated provider call IDs are normalized in the kernel.
- New `validateTranscript` state machine plus a 2000-script protocol fuzzer.

### Security
- **Confidentiality hole.** The sandbox bind-mounted `/` read-only, so it
  could read `~/.ssh` and hand it to the model, and from there to the
  provider. It now starts from an empty root with an allowlist of system dirs;
  `/home`, `/root`, `/run`, `/var` and others are absent.
- **Host socket hole.** `--unshare-net` does not isolate path-based Unix
  sockets, so `docker.sock` and the D-Bus session bus were reachable. They no
  longer are, because `/run` and `/home` are not mounted.
- **Inherited file descriptors.** Harness fds crossed into the sandbox,
  bypassing the mount namespace. The child now runs `close_range(3, ~0)`
  after fork, and stdin is `/dev/null` (commands reading stdin used to hang
  until the timeout).
- **Orphaned sandboxes.** With coreutils `timeout` interposed, a SIGKILLed
  harness left the sandboxed command running and writing to the workspace.
  bwrap is now a direct child, and the timeout is enforced in-process.
- **Workspace guard.** The workspace may not be `/`, `$HOME`, an ancestor of
  `$HOME`, or a system directory.

### Added
- Write-ahead journal: intent → decision → started → outcome, each
  fdatasync'd before proceeding. If a record cannot be made durable, the
  action does not run. UNKNOWN_OUTCOME actions are reported on every run and
  by `malyutka journal` (exit 5), never re-executed, and cleared with `--ack`.
  A torn final line is repaired on open.
- The journal and session files moved out of the workspace into
  `~/.local/state/malyutka/`, where the agent cannot see them.
- `tests/test_adversarial.nim` (14 escape attempts) and
  `tests/integration.sh` (11 CLI checks, including SIGKILL mid-command).

### Verified
- 59/59 tests pass as root and as an unprivileged user.
- The same integration script against the 0.3.0 binary fails 8 of 11 checks.


## 0.3.0 — M1.1 "Guidance, confined"

First version actually compiled and tested (Nim 1.6.14; Nim 2.x pending).

### Fixed
- Compile error: `policy.nim` used `hasKey` on JSON without importing `std/json`.
- **Tool-call wire protocol.** M1 sent tool results as `tool` messages without
  `tool_call_id` and never sent the assistant `tool_calls` message, so strict
  OpenAI-compatible servers (vLLM, OpenAI) returned HTTP 400 on the first tool
  round-trip. Reproduced against `tests/fake_openai.py`.
- Only the first of several tool calls in a turn was handled; the rest were
  silently dropped. All calls are now handled in order.
- Object-valued tool arguments (some Ollama versions) were replaced by `{}`.
- The HTTP client leaked one connection per step; no request timeout;
  non-JSON error bodies produced a parse error instead of the HTTP status.
- The shell was advertised to the model even when disabled.
- A missing `--config` file was silently ignored; unknown flags only warned.

### Security
- `--allow-shell` ran commands **unconfined on the host** behind a substring
  denylist. Verified: given the same model output, M1 wrote into `/etc` when
  run as root. The shell now runs under bubblewrap, and the run is refused if
  the sandbox is unavailable. Host execution needs `--unconfined-host`.
- Shell children inherited the harness environment, including
  `MALYUTKA_API_KEY`; a model-issued `env` would have exposed it. Children
  now get a scrubbed environment.
- Shell commands had no timeout or output limit.

### Added
- Authority kernel types: `Capability`, `ExecutionRealm`, `EffectClass` (B0–B4),
  `Verdict`, `Decision{policyId}`; monotonic `compose` with effect ceilings.
- Run-scoped event IDs with `causedBy` links; stable string enum values.
- Repetition halt (`--repeat-limit`), exit codes, `doctor` sandbox probe.
- `ARCHITECTURE.md` with invariant status; `tests/test_invariants.nim` with one
  test per enforced invariant.
