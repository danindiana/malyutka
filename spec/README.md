# Specifications

Each spec describes work *before* it is built: goals, interface, the invariant it
adds or touches, failure modes, and the tests (with the mutant that must fail them).
A spec is done when its status is `implemented` **and** its invariant row in
[`ARCHITECTURE.md`](../ARCHITECTURE.md) says *enforced*.

| Spec | Title | Invariant | Status |
|---|---|---|---|
| [SPEC-001](SPEC-001-file-tools.md) | File tools and `todo` | I13 | planned (PR: feat/file-tools-approvals) |
| [SPEC-002](SPEC-002-approvals.md) | ASK approvals | I14 | planned (same PR) |
| [SPEC-003](SPEC-003-sessions-resume.md) | Incremental sessions and resume | I15 | planned (PR: feat/sessions-memory) |
| [SPEC-004](SPEC-004-memory-personality.md) | Memory, SOUL.md, personalities | I1 (reused) | planned (same PR) |
| [SPEC-005](SPEC-005-event-schema.md) | Event schema `events/2` | — | planned |

Template: *Status · Goals · Non-goals · Interface · Invariants · Failure modes · Tests and mutants · Rollout*.
Backlog items that are not yet specified live in [`../todo/`](../todo/README.md).
