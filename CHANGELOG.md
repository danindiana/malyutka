# Changelog

## Unreleased: web search (SPEC-011, part 2)

- **`web_search`** (`--web`, needs a backend in `<state>/web.json` or `--web-backend:NAME`): **SearXNG**, **Brave
  Search** and **Tavily**, normalised to title / URL / snippet, labelled `untrusted search results`. One backend,
  chosen explicitly; **no fallback** (a query silently going to another third party is a leak).
- Keys: read at call time from the environment variable *named* in the config, sent over the helper's stdin (never
  argv), to the configured https host only; keyed backends refuse http, follow no redirects, and the key never
  appears in events, the journal, errors or results.
- Approvals: every search asks and shows the backend and the exact query. The only unasked search is one against a
  **SearXNG on loopback** with `trust: "allow"`, re-derived from the live config at every decision; the config
  parser rejects `trust: "allow"` for any other host or backend. Credential-shaped queries are DENY (no approver).
- `malyutka doctor` shows the configured search backend; `web.searched` event.
- Tests: 33 new (request building, answer cleaning, fake backends over http and https, key handling, config
  strictness, the exemption table, the helper end to end), 26 mutants. **Brave and Tavily are verified against local
  fakes only**; SearXNG was also verified against a real instance.

## Unreleased: web fetch (SPEC-011, part 1)

- **`web_fetch`** (`--web`): fetch one http/https page and return its text (HTML to markdown-ish text, plain text,
  JSON, XML); paging with `offset`/`char_limit`; in-run memo; result labelled `untrusted page text`.
  Effect B3, realm `network`, journaled. New invariant **I18**.
- **A separate helper binary** `malyutka_web` (built by `nimble build` next to `malyutka`) holds everything that
  touches the network or untrusted markup: a hardened HTTP/1.1 client (one DNS resolution per hop, every answer
  vetted, connect to a vetted IP, TLS verification with SNI and host-name check, manual redirects re-checked,
  size/time/header caps), an HTML-to-text converter that does linear work on hostile input, and the metadata
  floor. It runs inside bwrap with the network shared and **no** filesystem access. It is a separate binary
  because Nim loads OpenSSL eagerly under `-d:ssl` (found by a spike: with libssl masked the whole harness
  refused to start), so `malyutka` itself stays libssl-free.
- Policy: `web.url` denies (never reaches an approver) credentials, userinfo, secret formats, non-http(s),
  literal private/loopback/link-local/metadata addresses, non-canonical IP spellings, denylisted domains;
  `web.ask` makes every call ask. `<state>/web.json` (strict file; any defect switches web access off).
- `malyutka doctor` reports the helper; a missing helper or libssl just means the tool is not registered
  (`web.unavailable` event).
- Tests: `tests/test_web.nim` against `tests/fake_web.py` (http and https with a generated certificate).

## 0.8.0 skills and an MCP client

- **Skills** (`--skills`): `skills_list`, `skill_view`, `skill_save` over `<state>/skills/<name>/SKILL.md`
  (agentskills.io frontmatter). Skills are data: text reaches the model only as a tool result, nothing in
  them is executed or loaded as configuration, the system prompt only gains one fixed sentence. Strict reader
  (no symlinks, operator-owned, not group/world-writable); `skill_save` always asks, is journaled, writes a
  0600 file in a 0700 directory under the state dir only.
- **MCP stdio client** (`--mcp`, `<state>/mcp.json`): servers run sandboxed by default (same bwrap broker,
  no network, scrubbed environment plus an `envAllow` list); `sandbox:false` needs `--unconfined-host`.
  JSON-RPC 2.0 with bounded lines (1 MiB), results (64 KiB), descriptions, schemas and time; timeouts and
  protocol violations kill the server and later calls fail cleanly. Tools are `mcp_<server>_<tool>` with the
  operator's ceiling (B0-B2) and realm `external`; the new `mcp.ask` layer makes every call ASK (mandate,
  approver or deny) except `trust: allow` on a B0 server. Invariant **I17**. Events `mcp.connected`,
  `mcp.failed`, `mcp.refused`. Servers die with the run, also on exceptions.
- TUI: `--skills`, `--mcp`, `/tools skills|mcp`, `/mcp`, 📚/🔌 icons, mcp events in the transcript.
- Tests: `tests/test_skills.nim` (12; 7 mutants killed, 1 equivalent documented), `tests/test_mcp.nim`
  (22; 14 mutants killed) against `tests/fake_mcp.py` (hang, flood, bad JSON, wrong ids, server requests,
  name collisions, lying schemas, exits mid-call); integration 15; live battery gains `skills` and `mcp`.

## 0.7.0 background processes and resource limits (M3-lite)

- **`process` tool** (`--allow-process`, `--max-processes:N`): `start`/`poll`/`log`/`kill`/`list` over the
  same bwrap broker as `shell`; output kept in a 64 KiB ring (drops are reported); the denylist and
  dangerous-command layers see `process start` like `shell`. Events: `process.started`,
  `process.exited`, `process.reaped`. Invariant **I16**: nothing the tool started outlives the run
  (answer, halt, exception, or harness SIGKILL).
- **Found by testing**: killing only the outer `bwrap` right after start can orphan the namespace init and
  leave the command running. All sandbox kills (tool, run end, shell timeouts) now `SIGSTOP` the outer
  process, enumerate its descendants from `/proc` and `SIGKILL` them all. My first I16 tests passed while the
  bug was live because they only checked the outer pid; they now look for survivors by a unique tag in
  `/proc/*/cmdline`.
- **Resource limits** (`--cgroups:auto|require|off`, `--limit-memory:MB` default 2048, `--limit-pids:N`
  default 512): sandboxed commands run inside a transient `systemd-run --user --scope` with `MemoryMax`,
  `MemorySwapMax=0` and `TasksMax`. Raw cgroup files cannot be used (a login session is outside
  `user@UID.service`; migrating a process across is refused). A functional probe runs at start:
  applied (`confinement.limits`), skipped visibly (`confinement.degraded`), refused (`require`, exit 3).
  `malyutka doctor` reports it.
- `bwrap` now starts with `--clearenv` and re-sets the same five variables, so the variables `systemd-run`
  needs can never reach the sandboxed command (I9). Existing adversarial suites unchanged and passing.
- TUI: `--allow-process`, `/tools process`, `/ps`, `⚙N` in the status bar, process and limit notices.
- Tests: `tests/test_process.nim` (19 tests; 13 mutants killed incl. the start-up race, shutdown, the
  `finally`, the event, the cap, the ring, `--clearenv`, the scope prefix, `require`, the denylist, the
  classification, probe skipping). The real-scope tests (a fork loop capped, a memory hog killed while the
  same command succeeds unlimited) run only where `systemd-run --user --scope` works and skip otherwise.
  Integration 14; live battery gains a `process` check.

## 0.6.0 context compaction and ranked session search (M5-lite)

- **Compaction** (`--context-window:N`, default 32768; `--compress`): above 75 % of the
  window the oldest turns are summarised by the same provider and replaced by one
  labelled-untrusted `user` message, down to about 50 %. The transcript is split only at
  cut points that keep the tool protocol valid. Dropped messages are appended to
  `sessions/<run>.archive.jsonl` (0600) **before** they leave the prompt; no archive, no
  compaction. Failures (summariser error, empty summary, no progress, no cut point)
  are reported as `context.compaction_failed` and the run continues; if the estimate still
  exceeds the window the run halts (`reason=context`, exit 4) instead of truncating.
  Invariant **I10 is now enforced**. Events: `context.compacted`, `context.compaction_failed`.
- **Ranked search**: `sessions --search` scores sessions (capped counts, newer wins ties),
  `--limit`, `--json`, via a derived cache `sessions/.index.json` (0600) that is trusted only
  per entry while mtime (ns) and size match. No SQLite (see SPEC-007).
- TUI: `/compress`, `/ctx`, `/search`, context window from Ollama `/api/show` (`num_ctx`)
  with a warning when it is unknown, compaction events in the transcript.
- Tests: `tests/test_compact.nim` (26 tests; mutants verified: cut between a call and its reply,
  archive skipped / not required, silent loss on summariser failure, no halt at 100 %, unlabelled
  summary, no-progress guard, threshold ignored; ranking, stale-entry, symlink and poisoned-index
  mutants). Two documented equivalent mutants (SPEC-007) and one defence-in-depth guard (SPEC-006).
  Integration 13 with the scripted fake model; checked by hand with qwen3.5:9b.

## Unreleased: live validation (no kernel change)

- `tests/m2-live.sh` + `tests/m2_live_check.py`: drives the real harness with real
  Ollama models through file tools, ASK approvals (deny / once / timeout over the
  stdin channel), resume, memory and mandates; asserts on harness behaviour and
  journal health, classifies provider flakes separately. Self-tested by
  `tests/m2_live_check_selftest.py` (mutated traces; runs in CI).
- Record: `docs/certification/M2-live-calisota-20261013.md` (4 models x 8 checks, all PASS).
- TUI: `/mandates`, mandate event lines, approval modal hint about mandates.
- Diagrams 09 and 10 now show the commitment latch and the newer modules.

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
- Tests: `tests/test_m2.nim` (30 tests; 12 mutants verified to fail them) and
  integration checks 8-9 using the new scripted `tests/fake_script.py`.

## Unreleased — commitment latch (M2 groundwork)

Scoped, durable operator mandates that resolve ASK approvals, so an agent can
run unattended on one approval and the record shows it stayed inside it.
Design rationale: Lanz et al., *Nature* 2026, split attractor gating.

- **New:** `src/malyutka/latch.nim` (mandate log, strict decoder, hash chain,
  scopes, budgets, TTL), `malyutka mandate` command, `propose_mandate` tool,
  `--ask-from`, `--mandates`, `--scope-miss-limit`, exit code 7.
- **Policy:** new `approval` layer in `defaultLayers()`; it is inert unless
  `--ask-from` is given, so existing behaviour is unchanged.
- **Invariants:** L1–L5 added to ARCHITECTURE.md, all enforced. (The design
  doc's I12–I16 numbering was dropped: invariant 12 already exists.)
- **Tests:** `tests/test_latch.nim` (26), integration section 8 (4).
  106 offline + 21 integration pass on Nim 1.6.14, as root and unprivileged.
  Mutation results in ARCHITECTURE.md.
- **Not yet done:** live-model run (worlock/calisota), Nim 2.x (CI), and an
  interactive approver for ASKs a mandate does not cover.
- **Fix in passing:** `mandate` with no options no longer falls through
  `getopt(@[])` to the real command line.

## M1.2 certified — 2026-10-07 (kernel v0.3.4, unchanged)

`tests/m12-certify.sh` passed with full live coverage on `calisota`: Ubuntu
22.04.5, kernel 6.8, Nim 2.2.12, bubblewrap 0.6.1, Ollama with
`qwen3.5:27b`, unprivileged user. FAIL=0, NOT_RUN=0, GAP=0.
- The certified kernel and certifier hashes match `v0.3.4` and `main`.
- Scope, including what remains open (24.04 with the AppArmor restriction
  active; vLLM; other models), is recorded in
  `docs/certification/M1.2-calisota-20261007.md`.


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
