# SPEC-008 — Background processes and resource limits

**Status:** implemented in 0.7.0 · **Invariant:** I16 (new) · **Roadmap:** M3-lite

## Goals
1. A `process` tool: start a long-running command in the sandbox, poll its output, kill it.
2. Resource limits (memory, task count) on sandboxed commands, so a runaway or fork bomb cannot take the host.

## Non-goals
Processes that outlive the run (cron/daemons stay in `todo/`); limits for the unconfined host realm; IO/CPU
quotas; raw cgroup-file management (see below).

## Design facts that shaped this (checked on the maintainer host, Ubuntu 22.04, cgroup v2)
- `user@UID.service` is delegated to the user, **but a login session lives outside it** (`session-cN.scope`),
  and an unprivileged process cannot be moved across that boundary (EACCES writing `cgroup.procs`).
  So the harness cannot put its children into cgroups it creates by hand.
- `systemd-run --user --scope -p MemoryMax=… -p TasksMax=…` works: systemd's user manager creates a transient
  scope under `user@UID.service/app.slice` and the command is exec'd inside it. That is the limits backend.
- Containment (nothing outliving the run) does **not** need cgroups for sandboxed commands: bwrap runs them in
  a PID namespace with `--die-with-parent`, so the whole tree dies when bwrap dies, even on SIGKILL of the harness.

## `process` tool (`--allow-process`, sandbox realm, ceiling B2, journaled)
One tool, `action` argument:

| action | args | effect | result |
|---|---|---|---|
| `start` | `command` | B2 | id `p1`… (max `--max-processes`, default 4 running) |
| `poll` | `id` | B0 | new output since the last poll + `running` / `exited <code>` |
| `log` | `id`, `tail?` | B0 | last `tail` bytes (default 2000) of the kept output |
| `kill` | `id` | B1 | SIGKILL of the sandbox, final output and exit code |
| `list` | — | B0 | ids, state, command, age |

- Same broker as `shell`: `bwrap` + fd-pinned workspace, scrubbed environment, no network. The command string is
  subject to the same denylist and dangerous-command layers as `shell`.
- Output is kept in a ring of the last 64 KiB per process; dropped bytes are reported, never hidden.
- Events: `process.started {id, command, pid}`, `process.exited {id, exitCode}` (when first observed),
  `process.reaped {killed}` when a run ends with processes still running.

## Resource limits
- `--limit-memory:MB` (default 2048, `0` = none) → `MemoryMax` + `MemorySwapMax=0`;
  `--limit-pids:N` (default 512, `0` = none) → `TasksMax`. Applied to `shell` and `process` (sandbox realm only).
- `--cgroups:auto|require|off` (default `auto`). A functional probe (`systemd-run --user --scope … true`) runs
  at start. Available: `confinement.limits {backend, memoryMb, pids, applied:true}`. Unavailable: `auto` emits
  `confinement.degraded {reason}` (limits NOT applied, visible); `require` refuses the run (exit 3, like a
  missing sandbox); `off` skips it.
- `bwrap` now starts with `--clearenv` and re-sets the same five variables, so the extra variables
  `systemd-run` needs (`XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`) can never reach the sandboxed command (I9).
- `malyutka doctor` reports the limits backend.

## Invariant I16 — no background process outlives its run
Every process started by the tool is killed when the run ends (normal, halt, error); if the harness itself is
SIGKILLed the PID-namespace teardown does it. Enforced for the sandbox realm.

## How the kill actually works (found by testing)
Killing only the outer `bwrap` is not enough: for a short window after start the namespace init has not yet armed
its parent-death signal, so an immediate kill orphans it and the command keeps running. The harness therefore
stops the outer bwrap with `SIGSTOP` (it can no longer fork), enumerates its descendants from
`/proc/<pid>/task/<pid>/children`, and `SIGKILL`s them all before the outer one. `runBounded` (shell timeouts)
uses the same routine.

## Failure modes
Start beyond the limit → tool error. Unknown id → tool error. A process that exits is still pollable until the
run ends. Output of an exited process remains readable. `kill` of an exited process reports its exit code.

## Tests and mutants
Start/poll/log/kill/list semantics, concurrency cap, output ring, shutdown kills everything (checked by
`kill(pid, 0)` → ESRCH, never by process-name patterns), SIGKILL of the harness leaves no process (integration),
the environment inside the sandbox is unchanged, limits: a fork loop is capped and a memory hog is killed
(integration, gated on the probe).
**Mutants:** no shutdown kill; no concurrency cap; `--clearenv` removed; limits prefix not applied;
`require` falls through when unavailable; denylist not applied to `process start`.
