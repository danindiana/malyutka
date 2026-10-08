# Changelog

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
