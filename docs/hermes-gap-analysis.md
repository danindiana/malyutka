# Hermes-agent gap analysis

Source: the [Hermes Agent](https://github.com/NousResearch/hermes-agent) README and
[docs](https://hermes-agent.nousresearch.com/docs) (tools, security pages) read on 2026-10-13.
Some Hermes details (checkpoints, plugin loading) were not read in depth and are marked *(?)*.
Sizes: S < 1 day, M = a few days, L = a week or more, for a small Nim harness.

Malyutka's stance (see diagram 08): **depth before breadth**. A feature is added only
behind a gate and with an invariant row. That is why the list below is ordered by
"what unlocks useful work while staying inside the invariants", not by Hermes' feature count.

| Pri | Hermes feature | Malyutka today | Size | Plan |
|---|---|---|---|---|
| P0 | File tools: `read_file`, `write_file`, `patch`, `search_files` | none (shell only) | M | [SPEC-001](../spec/SPEC-001-file-tools.md) |
| P0 | Approvals: dangerous-command patterns, once/session/always/deny, allowlist, hardline blocklist, 300 s timeout | ASK is denied (fail closed) | M | [SPEC-002](../spec/SPEC-002-approvals.md) |
| P0 | Session persistence, resume, `/retry`, `/undo` | transcript written once at run end; no resume | M | [SPEC-003](../spec/SPEC-003-sessions-resume.md) |
| P1 | `todo` planning tool | none | S | SPEC-001 |
| P1 | Persistent memory file, `SOUL.md`, personalities | none | S | [SPEC-004](../spec/SPEC-004-memory-personality.md) |
| P1 | Slash-command parity in the TUI | partial | S | SPEC-003/004 |
| P2 | Session search (SQLite FTS5) | **ranked search with a derived index (0.6.0)**; SQLite deliberately not used | M | [SPEC-007](../spec/SPEC-007-session-search.md) |
| P2 | Context compression (`/compress`, auto) | **done (0.6.0), I10 enforced** | M | [SPEC-006](../spec/SPEC-006-context-compaction.md) |
| P2 | Skills (agentskills.io `SKILL.md`) | none | M | [todo](../todo/P2-skills.md) |
| P2 | MCP client (stdio) | none | M | [todo](../todo/P2-mcp-client.md) |
| P2 | Background `process` tool | none | M | [todo](../todo/P2-background-process.md) |
| P2 | Cron / scheduler | none | M | [todo](../todo/P2-cron.md) |
| P2 | Subagent delegation | none (M6) | M–L | [todo](../todo/P2-delegation.md) |
| P2 | Docker / SSH terminal backends | bwrap only | M | [todo](../todo/P2-exec-backends.md) |
| P2 | Checkpoints and rollback *(?)* | none | M | [todo](../todo/P2-checkpoints.md) |
| P2 | Trajectory JSONL export | journal + sessions exist | S–M | [todo](../todo/P2-trajectories.md) |
| P3 | Messaging gateway (Telegram, Discord, …) | none | L | [non-goals](../todo/NON-GOALS.md) |
| P3 | Browser, vision, TTS, image generation | none | L | non-goals |
| P3 | Honcho user modelling, cloud sandboxes, RL tooling | none | L | non-goals |
| P3 | Plugin loader | none (I4 is vacuous) | M–L | non-goals until a kernel-safe design exists |

Already at parity or ahead: OpenAI-compatible provider switching (Ollama/vLLM/OpenAI),
sandboxed terminal, TUI (banner, tool feed, skins, model picker), and — beyond Hermes —
the write-ahead journal, crash-uncertainty model and invariant-tested policy kernel.
