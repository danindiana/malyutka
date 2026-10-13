# Changelog

## 0.5.0 sessions, resume, memory, personalities (M4-lite)

- **Incremental sessions**: `sessions/<run>.json` is written atomically (temp +
  fsync + rename, 0600) after every step, with meta (parent, title, provider,
  model, status). A crash keeps the last good transcript. Strict decoder:
  schema, roles, run ids (no path traversal) and symlinks are checked; pre-0.5
  files load as legacy.
- **Resume**: `run --resume:<id|prefix|last>`; `sessions [--json]`, `--show`,
  `--search`. New invariant **I15**: resume rebuilds the message list only,
  nothing journaled is replayed, the system prompt is rebuilt, and it is refused
  while the lineage has an unresolved action unless `--resume-despite-unknown`.
- **Memory** (`--allow-memory`): journaled `memory` tool (add/replace/remove,
  8 KiB cap, 0600, symlinks refused), injected fenced and labelled untrusted.
  **SOUL.md** (`--soul`, `<state>/SOUL.md`; refused if group/world-writable) and
  `--personality` presets.
- Events: `session.saved`, `session.failed`, `memory.updated`.
- `write_file` previews show additions only (no blank `-`/`+` lines); found while wiring the TUI diff view.
- Tests: `tests/test_sessions.nim` (19 tests; 13 mutants verified to fail them);
  integration checks 10-11. Not mutant-tested: the atomicity of the session
  rename (the tests check there is no temp residue and the mode, not a torn write).

## 0.4.0 M2: file tools and ASK approvals

- **File tools** (`--allow-files`): `read_file`, `search_files`, `write_file`,
  `patch`, `todo`. Paths are resolved with `openat` + `O_NOFOLLOW` from the
  workspace fd; writes are atomic. New invariant **I13**.
- **ASK approvals**: `--approvals:deny|stdin|tty|off`, once/session/always/deny,
  300 s default timeout, `<state>/allowlist.json` (0600, checksummed, strict
  decode). The approver is consulted only for ASK, so DENY is final (**I14**).
  New policy layer `approval.dangerous` (pipe-to-shell, force push, recursive
  chmod 777, destructive SQL, writes to `/etc`, `.env`, `.ssh`, `.git/`); the
  denylist gains `dd of=/dev/...`.
- Events: `run.start.schema = "events/2"`, `approval.request`, `approval.answer`,
  `approval.ignored`, `todo.update`, optional `tool.result.preview`.
- Found by the new tests: capturing the loop variable in the tool registry made
  every file tool report effect B0 and skip the journal. Fixed and pinned by a test.
- Tests: `tests/test_m2.nim` (28 tests; 12 mutants verified to fail them) and
  integration checks 8-9 using the new scripted `tests/fake_script.py`.

## 0.3.4 certification tooling, revision 2 (kernel unchanged)

Response to the review of the first certification tooling revision. Each fix
is tested by `tests/m12-selftest.sh` against `tests/fake_model.py`. Every
original bug, reintroduced as a mutant, fails the self-test.

| Finding | Was | Now | Mutant |
|---|---|---|---|
| vLLM accidentally mandatory | an unconfigured vLLM gave NOT RUN, so an Ollama-only run could never certify (my own stand-in runs showed it; I misread it as correct) | optional (INFO) unless `M12_REQUIRE_VLLM=1`; configured but unreachable → NOT RUN | caught (A) |
| SIGKILL keyed on `tool.proposed` | could kill before execution began | kill only after this run's durable `started` record **and** an observed sandboxed process (matched by a unique token in bwrap/sh argv, not the harness's own argv) | caught (D) |
| Automatic reconcile as not-executed | contradicted the uncertainty model | no reconciliation; verifies the action is still UNKNOWN_OUTCOME after restart | caught (A) |
| `M12_SKIP_OFFLINE` still ran the suites | only the build was skipped | one conditional for build + suites | caught (E) |
| Truncated hashes | 16 hex chars | full SHA-256 of `src/` and of the script | — |
| Redaction overstated | "redacted" | documented as best-effort in the header and the report | — |

### Also

- **Isolated kill-gate journal.** Each provider suite has its own journal;
  the restart check matches the specific interrupted action, never a
  leftover.
- **Concurrency.** Certification runs must not overlap for one user:
  parallel self-tests interfered via a per-user bait directory, `pgrep`
  checks and a second-resolution token. STAMP and the adversarial bait
  directory are now per-process; overlap is documented as unsupported.
- **Unexplained failure, recorded.** One `nimble test` failure was seen once
  during self-testing (no `[FAILED]` case, log not retained) and did not
  recur in 9 later runs. The self-test now keeps evidence of any unexpected
  verdict, and the certifier reports the first specific error line.


## 0.3.4 certification tooling update (kernel unchanged)

`src/` is byte-identical to the 0.3.4 release; only `tests/m12-certify.sh` and
the docs changed.
- **Coverage vs certification.** The live single tool call, sandboxed shell
  and SIGKILL paths are gates: if the model never exercises them they are NOT
  RUN, and the run is incomplete. A multi-call turn or escape attempt the
  model declines is a GAP: listed in the result, but offline tests are the
  correctness evidence.
- **Diagnostics retained** when anything FAILs or is NOT RUN, in
  `m12-diagnostics-<timestamp>/` (directory 700, files 600):
  - traces, stderr, build/test logs, journal and sessions;
  - workspace listed only, not copied;
  - redacted: API-key env values, bearer tokens, common token prefixes,
    private-key blocks, ssh public-key bodies.
- The report records SHA-256 prefixes of `src/` and of the script itself.
- `M12_SKIP_OFFLINE=1` for quick reruns; it marks those gates NOT RUN, so it
  cannot certify.
- ARCHITECTURE: what lock-based liveness does and does not prove.


## 0.3.4 — M1.2 entry

No journal format change: the format is frozen for M1.2.

- **Three-state writer liveness.** 0.3.3 read every failure to inspect a
  writer's lock as "dead". That covered a missing, symlinked, foreign or
  unreadable lock file, and unexpected flock errors, and would have let an
  operator reconcile an action that might still be running.
  - Now ALIVE / DEAD (lock acquired) / UNKNOWN; the new
    OWNER_STATUS_UNKNOWN state blocks ack and reconcile.
  - Lock files are no longer deleted, so their absence cannot pass for a
    clean exit.
  - Tests L1–L5; restoring the 0.3.3 behaviour fails L2–L4.
- **Release hygiene.** 0.3.1–0.3.3 archives contained a compiled
  `tests/test_adversarial`. It is untracked, `.gitignore` covers all test
  executables, and `tools/release.sh` refuses to package ELF files (checked
  against the 0.3.3 archive).
- **`tests/m12-certify.sh`.** Your M1.2 checklist as an executable,
  report-producing gate. Exercised here only against a stand-in model
  server; its escape gate was mutation-checked.
- Shell scripts are shellcheck-clean.


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
