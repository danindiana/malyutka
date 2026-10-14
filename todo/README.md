# Backlog

Prioritised future work, ordered by what unlocks useful agent behaviour without breaking an
invariant. Work currently in flight is specified in [`../spec/`](../spec/README.md).
Rationale and Hermes references: [`../docs/hermes-gap-analysis.md`](../docs/hermes-gap-analysis.md).

| Pri | Item | Depends on |
|---|---|---|
| P2 | [Provider retry on transient errors](P2-provider-retry.md) | — |
| P2 | [Cron](P2-cron.md) | SPEC-002, SPEC-008 (process tool) |
| P2 | [Delegation](P2-delegation.md) | M6 (I3), compression |
| P2 | [Docker / SSH backends](P2-exec-backends.md) | realm `erRemote` |
| P2 | [Checkpoints / rollback](P2-checkpoints.md) | SPEC-001 |
| P2 | [Trajectory export](P2-trajectories.md) | SPEC-003 |
| P3 | [Non-goals](NON-GOALS.md) | — |

Delivered in 0.8.0 and removed from this list: skills ([SPEC-009](../spec/SPEC-009-skills.md)) and the MCP stdio client ([SPEC-010](../spec/SPEC-010-mcp-client.md)). Delivered in 0.7.0: the background `process` tool and resource limits ([SPEC-008](../spec/SPEC-008-processes-and-limits.md)). Delivered in 0.6.0: context compaction ([SPEC-006](../spec/SPEC-006-context-compaction.md)) and ranked session search ([SPEC-007](../spec/SPEC-007-session-search.md)).

Housekeeping: lock-file GC, journal migration tool, AppArmor profile for bwrap on 24.04,
vLLM live certification, regex in `search_files`, TUI: work monitor, diff view, user skin files.
