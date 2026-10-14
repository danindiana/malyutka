# Specifications

Each spec describes work *before* it is built: goals, interface, the invariant it
adds or touches, failure modes, and the tests (with the mutant that must fail them).
A spec is done when its status is `implemented` **and** its invariant row in
[`ARCHITECTURE.md`](../ARCHITECTURE.md) says *enforced*.

| Spec | Title | Invariant | Status |
|---|---|---|---|
| [SPEC-001](SPEC-001-file-tools.md) | File tools and `todo` | I13 | implemented 0.4.0 |
| [SPEC-002](SPEC-002-approvals.md) | ASK approvals | I14 | implemented 0.4.0 |
| [SPEC-003](SPEC-003-sessions-resume.md) | Incremental sessions and resume | I15 | implemented 0.5.0 |
| [SPEC-004](SPEC-004-memory-personality.md) | Memory, SOUL.md, personalities | I1 (reused) | implemented 0.5.0 |
| [SPEC-005](SPEC-005-event-schema.md) | Event schema `events/2` | — | implemented 0.5.0 |
| [SPEC-006](SPEC-006-context-compaction.md) | Context compaction | I10 | implemented 0.6.0 |
| [SPEC-007](SPEC-007-session-search.md) | Ranked session search | — | implemented 0.6.0 |
| [SPEC-008](SPEC-008-processes-and-limits.md) | Background processes and resource limits | I16 | implemented 0.7.0 |

Template: *Status · Goals · Non-goals · Interface · Invariants · Failure modes · Tests and mutants · Rollout*.
Backlog items that are not yet specified live in [`../todo/`](../todo/README.md).
