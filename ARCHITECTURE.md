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
| 1 | Model output is data, never authority | enforced; memory notes and SOUL.md are data in the system prompt, fenced and unable to change the tool list or policy | I1, memory/soul tests |
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
| 13 | File tools cannot read or write outside the workspace | enforced: every path is walked component by component with `openat(2)` + `O_NOFOLLOW` from the workspace's own fd (no string path is re-resolved); absolute paths and `..` are refused lexically; writes are temp file + `renameat`. Residual: an operator-placed hard link is writable through | I13 (traversal, absolute, final/intermediate symlink, size/binary), mutants in `tests/test_m2.nim` header |
| 14 | An approver can only upgrade ASK to ALLOW | enforced: ASK is resolved in order: a latched mandate (L1-L5), then the approver, else fail closed. The approver is consulted only on the ASK branch, so a DENY from any layer (including the hardline denylist) is final; unanswered, timed-out, EOF, malformed, wrong-action and raising approvers all deny; allowlist defects (mode, owner, symlink, checksum, schema) make the whole file untrusted | I14, approver mechanics, integration 9 |
| 15 | Resume never re-executes: a resumed session only rebuilds the message list | enforced: history is validated (`validateTranscript`) and loaded as inert messages; no journal record is written for it and no file is touched; the system prompt is rebuilt, never inherited; resume is refused while the session's lineage has an unresolved (UNKNOWN_OUTCOME / OWNER_STATUS_UNKNOWN / IN_PROGRESS) action unless `--resume-despite-unknown`. Sessions are decoded strictly (schema, roles, ids, no symlinks) | I15, session strictness, integration 10 |
| P | Every proposed tool call receives exactly one terminal result | enforced | completeness tests, protocol fuzz (2000 scripts) |
| L1 | No mandate reaches LATCHED without an operator approval, journaled durably, whose digest matches the proposed scope; the model can propose but never approve or resume | enforced | L1 (6 tests), integration 8 |
| L2 | A mandate only turns ASK into ALLOW: it never changes a DENY, never covers a tool or effect outside its scope, and never lifts an action above the capability ceiling | enforced | L2 (3 tests) |
| L3 | Nothing reachable from the sandbox or the transcript can change a latched mandate: the log is disjoint from the workspace, and edits, deletions and rewrites are corruption that refuses runs | enforced against the sandbox; tampering by the operator's uid is *detected*, not prevented (CRC, not a keyed chain) | L3 (4 tests), integration 8 |
| L4 | Revoke and suspend need no approval and take effect before the next policy decision; a use after revocation, expiry or exhaustion is corruption | enforced | L4 (3 tests), budget, TTL |
| L5 | Every action a mandate allowed names that mandate in the journal decision record and in a durable `use` record written before the action is authorized | enforced | L5, write-ahead, integration 8 |

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

**Strict decoding (0.3.3).** A record counts only if

```
ValidRecord = SchemaValid ∧ ChecksumValid ∧ SequenceValid ∧ TransitionValid
```

- **Schema:** known `rec` type; `action`, `w`, `n`, `ts`, `crc` mandatory;
  per-type fields with the right JSON kinds and values (`verdict` ∈
  ALLOW|DENY, etc.).
  - 0.3.2 skipped checksum verification for records *without* `crc`, so a
    forged record lacking it was accepted. This was demonstrated: it flipped
    UNKNOWN_OUTCOME to COMPLETED.
- **Checksum:** CRC-32 over the record without `crc`.
- **Sequence:** per writer, `n` must be exactly 1, 2, 3, … *in file order*.
  - 0.3.2 sorted the numbers before checking, so duplicates and reorderings
    passed. A reordering made an executed action read as AUTHORIZED, i.e.
    never run.
  - Writer IDs are unique per journal handle (a 48-bit random suffix). 0.3.2
    reused `operator-$USER` with `n` restarting at 1 for every `journal`
    command.
- **Transitions:** per action, `intent → decision → [ALLOW] started →
  outcome`, each exactly once, all by the writer that wrote the intent.
  Operator `ack` is only allowed from UNKNOWN_OUTCOME; `reconcile` from
  UNKNOWN_OUTCOME or ACKNOWLEDGED_UNRESOLVED.

**Classification.** A line that does not parse at all is *torn*: a write
that never completed, so the step it guarded never proceeded. Anything
parseable that fails a predicate is *corrupt*.

**Liveness (0.3.3, three-state since 0.3.4).** Every journal handle holds an
exclusive flock on `<state>/runs/<writer>.lock` while open. The kernel
releases it when the process dies, including under SIGKILL. A writer is
classified as:
- **ALIVE:** the lock is held.
- **DEAD:** *only* if we can take the lock ourselves.
- **UNKNOWN:** anything else. That covers a missing, symlinked, foreign or
  unreadable lock file, or an unexpected flock error. 0.3.3 read all of these
  as dead.

Lock files are never deleted (one empty file per run), so absence cannot
mean "cleanly closed"; garbage collection is deferred.
**What liveness does and does not prove.** A held lock proves that a Malyutka
process holding that journal handle is alive. A released lock proves only
that this process ended. It does not prove that every descendant process
stopped, or that an action's external effects (a remote job, a pushed
commit, an email) have ceased or never began. The bwrap PID namespace covers
sandboxed descendants; nothing local covers external effects. That is why an
interrupted action is UNKNOWN_OUTCOME and never NOT_EXECUTED, and why
`--reconcile` records the operator's established outcome rather than
inferring one.

- "Started, no outcome" is therefore IN_PROGRESS while its run is alive,
  OWNER_STATUS_UNKNOWN when liveness cannot be established, and
  UNKNOWN_OUTCOME only once the run is proven dead.
- Operators cannot ack or reconcile a running action, nor one whose owner's
  status is unknown. Without this, a
  reconcile of a live action followed by its real `outcome` would be an
  invalid transition, and the journal would falsely read CORRUPT.

**Operator transactions (0.3.3).** `journal --ack/--reconcile` scan and
append under one exclusive lock (`Journal.transact`).
- 0.3.2 scanned, released, then appended: eight concurrent reconciles of one
  action wrote eight records, with both COMPLETED and FAILED.

**Framing and locking.**
- Every record is written as `"\n" & json & "\n"`, so a fragment torn by any
  crashed writer is terminated by the next writer's leading newline. 0.3.1's
  open-time tail repair missed writers that already had the file open.
- flock `LOCK_EX` around appends and `LOCK_SH` around scans. On a local
  Linux filesystem `O_APPEND` writes are already atomic, so the append-lock
  mutant survives; the lock matters for NFS-like filesystems, for scan
  consistency, and for `transact`.

**Threat model.** CRC-32 detects accidental corruption and casual tampering.
It is *not* a defense against an adversary running as the operator's uid,
who can recompute it. Remote agents, plugins or multi-user operation would
need a keyed hash chain or an external append-only service.

**Migration.** There is no legacy path. Two kinds of existing journal read
as CORRUPT under the strict decoder:
- a 0.3.1 journal (records have no `crc`);
- a 0.3.2 journal in which two operator commands shared a writer ID.

Both versions existed only on test machines; move such a journal aside
(`mv journal.jsonl journal.jsonl.old`).

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
| IN_PROGRESS | started, no outcome, owning run still alive: not reconcilable |
| OWNER_STATUS_UNKNOWN | started, no outcome, cannot establish whether the owning run is alive: not reconcilable; reported (exit 5) |
| UNKNOWN_OUTCOME | started, no outcome, owning run dead: may or may not have happened; surfaced every run; never re-executed |
| COMPLETED / FAILED | ran; outcome recorded |
| NOT_EXECUTED | started, but confinement refused execution |
| RECONCILED | operator established the real outcome: `journal --reconcile:ID --as:completed\|failed\|not-executed` |
| ACKNOWLEDGED_UNRESOLVED | operator saw it, outcome still unknown: `journal --ack:ID`. This does **not** imply reconciliation. |

Operator records are appended; history is never rewritten.

## Commitment latch

`latch.nim`. Opt-in: `--ask-from:Bn` adds an approval layer that turns ALLOW
into ASK for effects at or above `Bn`; `--mandates` attaches the mandate log
so that a latched mandate can resolve those ASKs. Without both, behaviour is
unchanged, and an ASK with no mandate still fails closed (I2c).

**Where it sits.** After `policy.compose`, before the fail-closed ASK rule:

```
intent (journal) -> compose -> [ASK and latch] tryUse -> decision (journal) -> started -> run
```

`tryUse` finds the first LATCHED mandate covering `(tool, effect)` and appends
its `use` record, fdatasync'd, inside the same locked transaction that checked
the state. Only then is the decision ALLOW, with `policy = mandate:<id>`. If
the record is not durable, the ASK stands and fails closed.

**States.** PROPOSED -> (operator approve) LATCHED -> SUSPENDED / REVOKED;
EXPIRED and EXHAUSTED are *derived* from the approval time, TTL and count of
`use` records, so they cannot be undone by any record. SUSPENDED -> LATCHED
needs the operator (`--resume`).

**Deviation.** While any mandate is latched, `--scope-miss-limit` (default 3)
consecutive ASKs that no mandate covers suspend every latched mandate. This is
deliberately crude; the M7 metacritic is its intended successor.

**Log.** `<state>/mandates.jsonl`, one record per line, framed like the
journal. Records: `propose`, `approve`, `use`, `suspend`, `resume`, `revoke`.
Each carries `n` (1, 2, 3 ... in file order), `prev` (CRC of the previous
record), `t` (epoch seconds) and `crc`. Every write is read-validate-append
under one exclusive flock, so concurrent runs and operator commands serialize.
Decoding is strict like the journal's: unparseable lines are TORN (benign),
anything else that fails schema, CRC, sequence, chain, digest or transition
checks is CORRUPT and fails closed (`run` and `mandate` exit 7). The log is a
separate file because the journal's decoder rightly treats unknown record
types as corruption.

**Design rationale.** Lanz et al., *Nature* 2026 (doi:10.1038/s41586-026-11144-9):
in the fly fan-shaped body, PFG neurons track heading while hΔK neurons are
held off by inhibition (FB5V); disinhibition switches on recurrence and locks
the current heading in as a goal, recurrent weights outweigh compass input
several-fold so the goal does not drift, and inhibition rises again on turns
and deviation from the goal. The harness copies the structure only: content
(proposal) separate from timing (approval), latched state dominant over
ongoing input, fast close, slow open.

**Limits.** `--unconfined-host` gives the model the operator's authority, so
it could run `malyutka mandate --approve` itself; that is the waiver's
existing meaning, not a latch defect. The operator identity is `$USER`, not a
signature. Mandates survive across runs by design (they are meant to cover
hours of work); a run that dies mid-action leaves its `use` record and the
journal's UNKNOWN_OUTCOME, as for any action.

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
`journal.unknown_outcome` (dead-owner actions only), `journal.degraded`, `journal.torn`, `journal.corrupt`, `step.start`, `tool.proposed`,
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
- Two mutants survive, reported rather than papered over with contrived
  tests:
  - **Append flock:** see the journal section.
  - **Strict `n == last+1` relaxed to gap-only:** under the current
    transition rules every exact replay is also an illegal transition, and
    every reordering starts with an upward jump that gap detection reports.
    The strict rule is kept for when transitions are relaxed (e.g.
    idempotent records).

**Latch mutants.** 19 mutants of `latch.nim` and its hooks in `core.nim`
were run against `tests/test_latch.nim`. 18 are caught; the first pass left
three survivors, two of which were real gaps (proposal digest, model resume)
and now have tests. One survives by design:
- **Sequence check (`n == count+1`) removed:** the hash chain (`prev`) already
  catches every deletion, duplication and reordering. The sequence check is
  kept as defense in depth and for clearer error messages.

**Self-matching process checks.** Process checks must not match their own
command line. `pgrep -f`/`pkill -f`/awk patterns matched the shell running
them, or the fake server's argv, four times in development (once killing the
test shell).

**Releases.** `tools/release.sh OUTDIR` builds from the committed tree and
refuses to package any ELF file or unexpected executable. 0.3.1–0.3.3 shipped
a compiled `tests/test_adversarial`, because `.gitignore` named test
binaries individually; it now ignores `tests/test_*` except `*.nim`.

**M1.2 certification.** `tests/m12-certify.sh` runs on the target host as an
ordinary user. It covers:
- native build and offline suites;
- the sandbox `doctor` probe;
- live Ollama, and optionally vLLM: plain, tool, multi-call, sandboxed shell,
  a model-issued escape attempt, and SIGKILL plus restart of a live run;
- transcript validation of every live session.

It writes a dated report with an environment fingerprint, and marks each
check PASS, FAIL, INFO (model behaviour, not a harness defect) or NOT RUN.
Here it was exercised only against a stand-in "cooperative model" server, as
a test of the script itself; its escape gate was mutation-checked. Real
models are worlock's job.

**Testing the certifier.** `tests/m12-selftest.sh` runs `m12-certify.sh`
through eight scenarios with known verdicts against `tests/fake_model.py`:
cooperative, refusing, escape-mutant, non-starting kill, skip-offline, vLLM
required, vLLM unreachable and vLLM reachable. Mutants of the four reviewed
certifier bugs all fail it.
- The first version of the non-starting-kill scenario did *not* catch its
  mutant: the run ended before any kill was possible. The stand-in now
  stalls after the proposal, so the harness stays alive and a premature kill
  is visible.
- Certifier runs must not overlap for the same user.

**Suites.**
- `tests/test_core.nim`
- `tests/test_invariants.nim`
- `tests/test_adversarial.nim`
- `tests/test_latch.nim`
- `tests/integration.sh BIN` (CLI, strict provider, SIGKILL crash,
  journal placement and tampering)

**Compiler matrix.**

| Nim | How | Result |
|---|---|---|
| 1.6.14 (native, Ubuntu apt) | full build + all suites, root and unprivileged | 80 unit + 17 integration pass |
| 2.2.4 (official compiler built to wasm, `@live-codes/nim-wasm` 0.4.0) | `nim check --os:linux --cpu:amd64` on the CLI and all three test files, run offline in bwrap | 0 diagnostics in Malyutka sources |
| 2.2.x (native, GitHub Actions ubuntu-24.04) | full build, `doctor` sandbox probe, all suites, CLI integration | pass ([run 37721788882](https://github.com/danindiana/malyutka/actions/runs/37721788882)) |

The wasm 2.2.4 check stops at semantic analysis; native 2.x code generation,
linking and test execution are covered by CI. Its only errors come from that wasm build's inability
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
