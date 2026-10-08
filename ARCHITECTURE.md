# Malyutka architecture

> Simple guidance. Bounded authority. Observable trajectory. Fail safe.

## The authority pipeline

```
model ──proposes──► ToolCall (data, never authority)
                       │
              ┌────────▼────────┐  no such capability → DENY (policy "registry")
              │    REGISTRY     │  disabled tools do not exist and are never
              └────────┬────────┘  advertised to the model
                       │ Capability{realm, maxEffect}, effectOf(call)
              ┌────────▼────────┐  effect > ceiling → DENY ("capability.ceiling")
              │  POLICY KERNEL  │  layers composed monotonically:
              └────────┬────────┘  verdict = min(DENY < ASK < ALLOW)
                       │           unanswered ASK → DENY
              ┌────────▼────────┐  realm sandbox → bwrap, or refuse
              │ SANDBOX BROKER  │  realm host    → only with explicit waiver
              └────────┬────────┘  scrubbed env, timeout, output cap
                       │
                  Observation ──► tool message (answers its tool_call_id)
                       │
              every step emits an event: run-scoped ID, causedBy links
```

Four separate questions, answered by four separate components:

| Question | Answered by | Type |
|---|---|---|
| Does this capability exist? | registry, built from config | `ToolSpec` |
| How bad could this call be? | the capability's realm + `effectOf` | `EffectClass` B0–B4 |
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

The sandboxed shell is classified B2 because the mount table makes B3/B4
*impossible* (read-only root, no network), not because a parser inspected the
command. Command classification can later refine B2 down to B0/B1 to choose
ALLOW vs ASK; it must never be what prevents B3/B4.

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
| 5 | Requested confinement failing means execution fails | enforced | I5 |
| 6 | Sandbox failure never silently becomes host execution | enforced | I6, I6b, I6c |
| 7 | Every side effect receives an immutable event ID | partial: IDs + `causedBy` links; immutability needs the M4 ledger | I7 |
| 8 | Every authorization decision records the policy responsible | enforced | I8 |
| 9 | Credentials are capabilities, not environment decoration | partial: children get a scrubbed env; no credential broker yet | I9 |
| 10 | Context loss/degradation is observable | partial: output truncation and timeouts are flagged to the model and in events; compaction is M5 | sandbox tests |
| 11 | Repeated unsuccessful cognition eventually halts | partial: identical-call halt + `maxSteps`; similarity-based R_t is M7 | I11 |
| 12 | Recovery claims never exceed what was journaled | vacuous: Malyutka makes no undo/recovery claims yet (M4) | — |

When a milestone makes an invariant non-vacuous, the milestone is not done
until that row says **enforced**.

## Sandbox contract (bubblewrap)

- `--ro-bind / /`, `--bind <workspace>`, `--tmpfs /tmp`, `--dev`, `--proc`,
  `--unshare-all` (includes network), `--die-with-parent`, `--new-session`.
- **Mount order matters:** `--tmpfs /tmp` precedes the workspace bind, or a
  workspace under `/tmp` is silently hidden. Covered by a test.
- Availability is a *functional* probe (`bwrap ... /bin/true`), not `which`.
  Ubuntu 24.04 can restrict unprivileged user namespaces via AppArmor, so a
  present-but-unusable bwrap must count as unavailable.
- The probe runs before the model's first turn: a sandboxed capability with no
  working sandbox refuses the run (exit 3). If bwrap disappears mid-run, the
  call fails with `confinement.failed`; it is never retried on the host.
- Children get a scrubbed environment (`PATH`, `HOME`, `LANG`, `TERM` only).

## Wire protocol (OpenAI-compatible)

An assistant turn that requests tools is sent back as an assistant message with
`tool_calls`, followed by exactly one `tool` message per call carrying its
`tool_call_id` — including denied and failed calls. Strict servers (vLLM,
OpenAI) reject anything else with HTTP 400. All calls in a turn are handled in
order. Arguments are accepted as a JSON string or an object; missing call IDs
are synthesized. `tests/fake_openai.py` is a strict reference server.

## Events

`run.start`, `confinement.waived`, `confinement.failed`, `step.start`,
`tool.proposed`, `policy.decision`, `tool.result`, `agent.final`, `agent.halt`.
Every payload carries `id` (`<run>-NNNN`, monotone) and `run`;
`policy.decision` and `tool.result` carry `causedBy`. Enum values are stable
strings (`ALLOW`, `B2`, `sandbox`) — they are the replay/metrics contract.

## Implementation notes

- Nim 1.6 async: implicitly discarding a `{.discardable.}` result inside an
  `{.async.}` proc triggers `internal error: yield in expr not lowered`
  (bisected during M1.1). `emit` is therefore not discardable; write
  `discard em.emit(...)`. Awaits are also hoisted out of conditions as a
  precaution.
