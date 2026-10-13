# SPEC-005 — Event schema `events/2`

**Status:** planned

`run.start.payload.schema = "events/2"` (absent ⇒ `events/1`). Controllers must ignore unknown kinds.
New kinds are additive; no existing field changes meaning.

| Kind | Payload | Emitted when |
|---|---|---|
| `approval.request` | `id, action, tool, args, reason, expiresAt` | an ASK needs an operator (stdin approver) |
| `approval.answer` | `id, answer, source: operator\|timeout\|eof\|allowlist\|session` | an ASK resolved |
| `todo.update` | `items[{id,text,status}]` | `todo` tool ran |
| `session.saved` | `path, step` | after each atomic session write |
| `memory.updated` | `op, bytes` | `memory` tool wrote |
| `tool.result` (extended) | adds optional `preview` (≤40-line diff or excerpt) | file tools |

Unchanged: `run.start step.start tool.proposed policy.decision tool.result tool.cancelled journal.* confinement.* agent.final agent.halt`.
The TUI (`tui/src/events.rs`) already tolerates unknown kinds and malformed lines.
