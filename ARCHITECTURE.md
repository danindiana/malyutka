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
              ┌────────▼────────┐  realm sandbox → bwrap (workspace bound by fd),
              │ SANDBOX BROKER  │                 or refuse
              └────────┬────────┘  realm host → only with explicit waiver
                       │           clean fds, /dev/null stdin, scrubbed env,
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
| 7 | Every side effect receives an immutable event ID | enforced for side effects: write-ahead journal outside the agent's reach (placement checked on canonical paths). Tampering is *detected* (CRC, sequence gaps) and fails closed; this is not cryptographic sealing against an attacker with the operator's uid | I7, J2–J17, integration 5c–5d |
| 8 | Every authorization decision records the policy responsible | enforced | I8 |
| 9 | Credentials are capabilities, not environment decoration | partial: scrubbed env, no inherited fds, operator home invisible to the sandbox; no credential broker yet | I9, adversarial |
| 10 | Context loss/degradation is observable | partial: output truncation, timeouts and unjournaled outcomes are flagged; compaction is M5 | J5, sandbox tests |
| 11 | Repeated unsuccessful cognition eventually halts | partial: identical-call halt + `maxSteps`; similarity-based R_t is M7 | I11 |
| 12 | Recovery claims never exceed what was journaled | enforced in its present form: an action with `started` and no `outcome` is UNKNOWN_OUTCOME and never re-executed. Acknowledging it does not mark it resolved; only an explicit `reconcile` does. There is no undo | J6, J15, J16, integration 3–5b |
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

- **The workspace is bound from a file descriptor, not a path (0.3.2).**
  `openWorkspace` resolves the path with realpath(3), opens it
  `O_PATH|O_DIRECTORY|O_NOFOLLOW`, then validates what the fd actually refers
  to (via `/proc/self/fd`). That fd becomes fd 3 in the child, and bwrap binds
  it with `--bind-fd 3`. No path is resolved twice, so a symlink swapped in
  after the check cannot redirect the mount.
  - 0.3.1 checked the path lexically: a symlink to `$HOME` passed the check.
    The CLI was not exposed, because getcwd(3) returns physical paths, but
    the library API was.
- **Mount order matters:** `--tmpfs /tmp` precedes the workspace bind, or a
  workspace under `/tmp` is silently hidden.
- **Workspace guard (on canonical paths):** the workspace must not be `/`,
  `$HOME`, an ancestor of `$HOME`, or overlap a system directory, `/run`,
  `/proc`, `/sys`, `/dev`.
- **Namespaces:** `--unshare-all` (user, net, pid, ipc, uts, cgroup), plus
  `--new-session`, which blocks TIOCSTI injection into the operator's
  terminal.
- **Process hygiene:** spawned with fork/execve, not `osproc.startProcess`.
  Between fork and exec the child gets `/dev/null` stdin and one pipe for
  stdout+stderr. Every other fd is closed with `close_range` (with a
  close-loop fallback), except the workspace fd, which bwrap consumes. An
  inherited fd would bypass the mount namespace entirely.
- **Lifetime:** bwrap is a *direct* child of the harness, so
  `--die-with-parent` ties the sandbox to Malyutka itself. The timeout is
  enforced in-process with poll(2). On expiry bwrap is SIGKILLed, which tears
  down the PID namespace, including `setsid`-detached children.
- **Probe:** functional, using the exact production argv including
  `--bind-fd`, run before the model's first turn. A missing bwrap, or one
  present but blocked (e.g. Ubuntu 24.04's AppArmor userns restriction),
  refuses the run (exit 3).

### Host realm (`--unconfined-host`): explicitly high risk

The waiver runs commands with the operator's full authority. Since 0.3.2 the
host child leads its own session and process group and has
`PR_SET_PDEATHSIG=SIGKILL`. When the command exits or times out, the whole
group is SIGKILLed, so ordinary background jobs (`cmd &`) cannot outlive it.
What still escapes:
- a process that deliberately leaves the group (`setsid`, double fork,
  `nohup … &` under `setsid`);
- children of the group when the harness itself is SIGKILLed (only the
  direct child receives PDEATHSIG).

Closing those needs a cgroup (M3). Until then the waiver means what it says.

### Residual risks, documented not solved

- A hard link the *operator* placed in the workspace to a file outside it is
  writable through. The agent cannot create one: cross-mount `link()` fails
  with EXDEV.
- Secrets *inside* the workspace (`.env`, tokens) are readable by the agent
  and therefore visible to the provider.
- `/etc` is readable.

## Write-ahead journal

**Location.** `$MALYUTKA_STATE_DIR/journal.jsonl` (default
`~/.local/state/malyutka/`); sessions go to `…/sessions/<run>.json`.

**Containment (0.3.2).** The state directory's *canonical* path must be
disjoint from the workspace. A journal inside the workspace, or reachable
through a symlink alias, refuses the run (exit 5). This is checked in the
kernel, not just the CLI.
- The journal file is opened `O_NOFOLLOW` and must be a regular file owned
  by the operator.
- 0.3.1 accepted `MALYUTKA_STATE_DIR` inside the workspace, letting the
  sandboxed agent rewrite its own record.

**Protocol.** For each action with effect > B0:

```
intent ─fdatasync─► decision ─fdatasync─► started ─fdatasync─► EXECUTE ─► outcome ─fdatasync─►
```

**Integrity (0.3.2).**
- **Framing.** Every record is written as `"\n" & json & "\n"`, so a
  fragment torn by any crashed writer is terminated by the next writer's
  leading newline.
  - 0.3.1 instead repaired a torn tail at open time. That missed writers
    that already had the file open: demonstrated, and the record appended
    after the fragment was lost. If that record had been a `started`, an
    action that ran would have read as never started.
  - The repair code, with its unchecked writes, is gone.
- **Writer identity.** Each record carries its writer `w` (the run ID), a
  per-writer sequence number `n`, and a CRC-32 over the rest of the record.
- **Locking.** flock `LOCK_EX` around appends and `LOCK_SH` around scans.
  This is defense in depth: on a local Linux filesystem `O_APPEND` writes are
  already atomic, which is why the flock mutant survives the 8-writer stress
  test. It matters where append atomicity does not hold (e.g. NFS) and for
  scan consistency.

**Health of a scan.**

| Health | Meaning | Effect |
|---|---|---|
| OK | — | — |
| TORN_TAIL | unparseable line(s): writes interrupted by a crash; the step each guarded never proceeded | `journal.torn` event; run proceeds |
| CORRUPT | a parseable record with a bad CRC, or a gap in a writer's sequence: durable history altered or lost | run refused (exit 5); `malyutka journal` exits 6 |

**Action states.**

| State | Meaning |
|---|---|
| PREPARED | intent only; never authorized |
| DENIED | authorization refused |
| AUTHORIZED | allowed, but `started` never became durable: never ran |
| UNKNOWN_OUTCOME | started, no outcome: may or may not have happened; surfaced every run; never re-executed |
| COMPLETED / FAILED | ran; outcome recorded |
| NOT_EXECUTED | started, but confinement refused execution |
| RECONCILED | operator established the real outcome: `journal --reconcile:ID --as:completed\|failed\|not-executed` |
| ACKNOWLEDGED_UNRESOLVED | operator saw it, outcome still unknown: `journal --ack:ID`. This does **not** imply reconciliation. |

Operator records are appended; history is never rewritten.

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
`journal.unknown_outcome`, `journal.degraded`, `journal.torn`, `journal.corrupt`, `step.start`, `tool.proposed`,
`policy.decision`, `tool.cancelled`, `tool.result`, `agent.final`,
`agent.halt`.

Every payload carries `id` (`<run>-NNNN`, monotone) and `run`.
`policy.decision` and `tool.result` carry `causedBy`.

Enum values are stable strings (`ALLOW`, `B2`, `sandbox`): they are the
replay/metrics contract.

## Testing discipline

**Mutation checks.** Each security test was checked by removing the
protection and confirming the test fails.
- This found a vacuous test in 0.3.1: the fd test passed because `cat`
  blocked on stdin before it reached the leaked fd.
- In 0.3.2 every new defense is caught by its mutant: realpath, `--bind-fd`,
  host process group, framing, CRC, sequence gaps, kernel placement check,
  `O_NOFOLLOW`.
- The flock mutant survives (see above). That is reported, not hidden.

**Self-matching process checks.** Process checks must not match their own
command line: `pgrep -f` matching the shell running it, or the fake server's
argv, produced three false results in development.

**Suites.**
- `tests/test_core.nim`
- `tests/test_invariants.nim`
- `tests/test_adversarial.nim`
- `tests/integration.sh BIN` (CLI, strict provider, SIGKILL crash,
  journal placement and tampering)

**Compiler matrix.**

| Nim | How | Result |
|---|---|---|
| 1.6.14 (native, Ubuntu apt) | full build + all suites, root and unprivileged | 62 unit + 15 integration pass |
| 2.2.4 (official compiler built to wasm, `@live-codes/nim-wasm` 0.4.0) | `nim check --os:linux --cpu:amd64` on the CLI and all three test files, run offline in bwrap | 0 diagnostics in Malyutka sources |

The 2.2.4 check stops at semantic analysis: no 2.x code generation, linking
or test execution yet. Its only errors come from that wasm build's inability
to evaluate `random.nim`'s compile-time `sqrt`, which is reached via
`std/httpclient`. A two-line program importing just `std/httpclient`
reproduces them exactly.

## Implementation notes

- **Nim 1.6 async:** implicitly discarding a `{.discardable.}` result inside an
  `{.async.}` proc triggers `internal error: yield in expr not lowered`. So
  `emit` is not discardable. Awaits are hoisted out of conditions as a
  precaution.
- **Tests:** they use a per-process scratch directory, never fixed names in a
  shared `/tmp`. Fixed names break when root and non-root runs share a
  machine.
- **No `std/oids` or `std/random`:** both pull in compile-time evaluation the
  2.2.4 wasm checker cannot do. Run IDs come from `std/sysrand`; the fuzzer
  uses a 6-line xorshift.
- **Open flags from C headers:** `O_PATH`, `O_DIRECTORY` and `O_NOFOLLOW` are
  imported from `<fcntl.h>`. Their values differ between x86_64 and aarch64,
  and Nim 1.6's `posix` lacks them.
