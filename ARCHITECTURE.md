# Malyutka architecture

> Simple guidance. Bounded authority. Observable trajectory. Fail safe.

## The authority pipeline

```
model ──proposes──► ToolCall (data, never authority)
                       │  ids normalized: unique per turn
              ┌────────▼────────┐  no such capability → DENY (policy "registry")
              │    REGISTRY     │  disabled tools do not exist and are never
              └────────┬────────┘  advertised to the model
                       │ Capability{realm, maxEffect}, effectOf(call)
              ┌────────▼────────┐  effect > B0: intent fdatasync'd first,
              │     JOURNAL     │  or DENY (policy "journal")
              └────────┬────────┘
              ┌────────▼────────┐  effect > ceiling → DENY ("capability.ceiling")
              │  POLICY KERNEL  │  layers composed monotonically:
              └────────┬────────┘  verdict = min(DENY < ASK < ALLOW)
                       │           unanswered ASK → DENY
              ┌────────▼────────┐  decision + "started" durable, or DENY
              │     JOURNAL     │
              └────────┬────────┘
              ┌────────▼────────┐  realm sandbox → bwrap, or refuse
              │ SANDBOX BROKER  │  realm host    → only with explicit waiver
              └────────┬────────┘  clean fds, /dev/null stdin, scrubbed env,
                       │           timeout, output cap, dies with harness
                  Observation ──► outcome journaled ──► tool message
                       │                                (answers its call id)
              every step emits an event: run-scoped ID, causedBy links
```

| Question | Answered by | Type |
|---|---|---|
| Does this capability exist? | registry, built from config | `ToolSpec` |
| How bad could this call be? | the capability's realm + `effectOf` | `EffectClass` B0–B4 |
| Is the intent on durable storage? | write-ahead journal | `intent` record |
| May it run? | policy kernel | `Decision{verdict, policyId}` |
| Where does it run? | sandbox broker | `ExecutionRealm` |

No single gate confers authority.

### Effect classes are bounded by confinement, not by parsing

| Class | Meaning | Example |
|---|---|---|
| B0 | read-only / pure | `echo` |
| B1 | local, reversible mutation | (reserved for M2 file tools) |
| B2 | broad workspace mutation | sandboxed `shell` |
| B3 | external side effect | (network-enabled tools, later) |
| B4 | privileged / unbounded | host `shell` under `--unconfined-host` |

The sandboxed shell is classified B2 because the sandbox makes B3/B4
unreachable: an empty root with only system directories mounted read-only, no
network, no host sockets, no inherited fds. Command classification may later
refine B2 down to B0/B1 to choose ALLOW vs ASK; it must never be what
prevents B3/B4.

> **Correction (0.3.1).** M1.1 (0.3.0) made this claim while bind-mounting
> `/` read-only. That was false: the sandbox could *read* `~/.ssh` (and return
> it to the model, i.e. to the provider) and could *connect* to host Unix
> sockets such as `docker.sock` or the D-Bus session bus, since `--unshare-net`
> does not isolate path-based sockets. It also inherited the harness's open
> file descriptors. All three were demonstrated and are now covered by
> `tests/test_adversarial.nim`.

## Invariants

Status: **enforced** = a test fails if the invariant breaks. **partial** = the
mechanism exists but is incomplete. **vacuous** = no component yet exists that
could violate it; the column names the milestone that must enforce it.

| # | Invariant | Status | Test(s) |
|---|---|---|---|
| 1 | Model output is data, never authority | enforced | I1 |
| 2 | Deny always dominates allow | enforced | I2, I2b, I2c |
| 3 | Children cannot acquire capabilities absent from parents | vacuous (M6) | — |
| 4 | Plugins cannot modify the policy kernel at runtime | vacuous (no plugins); layers fixed per run | — |
| 5 | Requested confinement failing means execution fails | enforced | I5, integration 6–7 |
| 6 | Sandbox failure never silently becomes host execution | enforced | I6, I6b, I6c |
| 7 | Every side effect receives an immutable event ID | enforced for side effects: write-ahead journal outside the agent's reach; append-only by construction, not cryptographically sealed | I7, J2–J6 |
| 8 | Every authorization decision records the policy responsible | enforced | I8 |
| 9 | Credentials are capabilities, not environment decoration | partial: scrubbed env, no inherited fds, operator home invisible to the sandbox; no credential broker yet | I9, adversarial |
| 10 | Context loss/degradation is observable | partial: output truncation, timeouts and unjournaled outcomes are flagged; compaction is M5 | J5, sandbox tests |
| 11 | Repeated unsuccessful cognition eventually halts | partial: identical-call halt + `maxSteps`; similarity-based R_t is M7 | I11 |
| 12 | Recovery claims never exceed what was journaled | enforced in its present form: an action with `started` and no `outcome` is reported UNKNOWN_OUTCOME and never re-executed; there is no undo | J6, integration 3–5 |
| P | Every proposed tool call receives exactly one terminal result | enforced | completeness tests, protocol fuzz (2000 scripts) |

Invariant **P** is new in 0.3.1. M1.1 violated it: a repetition halt in the
middle of a multi-call turn returned with calls unanswered. That is the same
state-machine defect class as M1's wire-protocol bug, and it would have
resurfaced on resume or replay.

When a milestone makes an invariant non-vacuous, the milestone is not done
until that row says **enforced**.

## Sandbox contract (bubblewrap)

**Mounts: an allowlist, not a denylist.** The root is an empty tmpfs.
`/usr /bin /sbin /lib /lib32 /lib64 /libx32 /etc /opt` are read-only binds
(merged-/usr symlinks recreated as symlinks). Then private `/dev`, `/proc`,
`/tmp`, and the workspace read-write. **Not mounted:** `/home`, `/root`,
`/run` (docker.sock, D-Bus, systemd and ssh-agent sockets), `/var`, `/mnt`,
`/media`, `/srv`, `/sys`.

- **Mount order matters:** `--tmpfs /tmp` precedes the workspace bind, or a
  workspace under `/tmp` is silently hidden.
- **Workspace guard:** the workspace must not be `/`, `$HOME`, an ancestor of
  `$HOME`, or overlap a system directory, `/run`, `/proc`, `/sys`, `/dev`.
- **Namespaces:** `--unshare-all` (user, net, pid, ipc, uts, cgroup),
  `--new-session` (blocks TIOCSTI injection into the operator's terminal).
- **Process hygiene:** spawned with fork/execve, not `osproc.startProcess`.
  Between fork and exec the child gets `/dev/null` stdin, one pipe for
  stdout+stderr, and `close_range(3, ~0)` (with a close-loop fallback). No
  harness fd crosses into the sandbox; an inherited fd would bypass the mount
  namespace entirely.
- **Lifetime:** bwrap is a *direct* child of the harness, so
  `--die-with-parent` ties the sandbox to Malyutka itself. M1.1 interposed
  coreutils `timeout`, which made `--die-with-parent` refer to `timeout`; a
  SIGKILLed harness left the command running and writing. The timeout is now
  enforced in-process with poll(2), and on expiry bwrap is SIGKILLed, which
  tears down the PID namespace including `setsid`-detached children.
- **Probe:** functional, using the exact production argv, before the model's
  first turn. If bwrap is missing, or present but blocked (e.g. Ubuntu 24.04's
  AppArmor userns restriction), the run is refused (exit 3).
- **Residual risks, documented not solved:**
  - A hard link the *operator* placed in the workspace to a file outside it is
    writable through. The agent cannot create such links: cross-mount `link()`
    fails with EXDEV.
  - Secrets *inside* the workspace (`.env`, tokens) are readable by the agent
    and therefore visible to the provider.
  - `/etc` is readable.
  - The host realm (`--unconfined-host`) gets fd hygiene and the scrubbed
    env, but no process-tree kill: detached host children can outlive a
    timeout. That is part of what the waiver waives.

## Write-ahead journal

`$MALYUTKA_STATE_DIR/journal.jsonl` (default `~/.local/state/malyutka/`).
Sessions go to `…/sessions/<run>.json`. Both live outside every workspace, and
the sandbox cannot see `/home` at all, so the agent cannot edit its own
record.

For each action with effect > B0:

```
intent ─fdatasync─► decision ─fdatasync─► started ─fdatasync─► EXECUTE ─► outcome ─fdatasync─►
```

| Crash or failure point | Journal state | Meaning | Action taken |
|---|---|---|---|
| intent not durable | none | — | DENY, never runs |
| decision/started not durable | NOT_STARTED | never executed | DENY, never runs |
| after `started`, before `outcome` | UNKNOWN_OUTCOME | may or may not have happened | reported on every run and by `malyutka journal` (exit 5); never re-executed |
| outcome not durable | UNKNOWN_OUTCOME | ran; result unrecorded | `journal.degraded` event + note to the model |
| torn final line | ignored; repaired on next open | that step never became durable | — |

The operator inspects the workspace and clears an entry with
`malyutka journal --ack:<ACTION_ID>`, which appends an `ack` record (it never
rewrites history).

B0 actions are not journaled; they have nothing to recover.

## Wire protocol (OpenAI-compatible)

An assistant turn that requests tools is sent back as an assistant message
with `tool_calls`. It is followed by exactly one `tool` message per call,
carrying its `tool_call_id`. This holds for denied, failed and cancelled
calls too. Strict servers (vLLM, OpenAI) reject anything else with HTTP 400.

- Call IDs are normalized in the kernel: missing or duplicated provider IDs
  are replaced.
- Arguments are accepted as a JSON string or an object.
- `validateTranscript` is the reference state machine, used by the tests and
  the fuzzer, and intended for resume (M4).
- `tests/fake_openai.py` is a strict reference server.

## Events

`run.start`, `confinement.waived`, `confinement.failed`,
`journal.unknown_outcome`, `journal.degraded`, `step.start`, `tool.proposed`,
`policy.decision`, `tool.cancelled`, `tool.result`, `agent.final`,
`agent.halt`.

Every payload carries `id` (`<run>-NNNN`, monotone) and `run`.
`policy.decision` and `tool.result` carry `causedBy`.

Enum values are stable strings (`ALLOW`, `B2`, `sandbox`): they are the
replay/metrics contract.

## Testing discipline

Each security test was mutation-checked: the protection was removed and the
test confirmed to fail. This found one vacuous test (the fd test passed
because `cat` blocked on stdin before reading the leaked fd). Process checks
must not match their own command line: `pgrep -f` matching the shell running
it, or the fake server's argv, produced three false results in development.

Suites:
- `tests/test_core.nim`
- `tests/test_invariants.nim`
- `tests/test_adversarial.nim`
- `tests/integration.sh BIN` (CLI, strict provider, SIGKILL crash, journal)

## Implementation notes

- **Nim 1.6 async:** implicitly discarding a `{.discardable.}` result inside an
  `{.async.}` proc triggers `internal error: yield in expr not lowered`. So
  `emit` is not discardable. Awaits are hoisted out of conditions as a
  precaution.
- **Tests:** they use a per-process scratch directory, never fixed names in a
  shared `/tmp`. Fixed names break when root and non-root runs share a
  machine.
