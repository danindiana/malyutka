# SPEC-005 — Event schema `events/2`

**Status:** implemented in 0.5.0 (approval/todo kinds in 0.4.0)

`run.start.payload.schema = "events/2"` (absent ⇒ `events/1`). Controllers must ignore unknown kinds.
New kinds are additive; no existing field changes meaning.

| Kind | Payload | Emitted when |
|---|---|---|
| `approval.request` | `action, tool, args, reason, policy, timeoutSec, expiresAt` | an ASK needs an operator (stdin approver) |
| `approval.answer` | `action, answer, source: operator\|timeout\|eof\|allowlist\|session\|off\|no-approver\|error` | an ASK resolved |
| `approval.ignored` | `action, reason` | a malformed / wrong-action / oversize answer was ignored |
| `todo.update` | `items[{id,text,status}]` | `todo` tool ran |
| `session.saved` | `status, messages` | after each atomic session write |
| `session.failed` | `reason` | a checkpoint write failed (the run continues) |
| `memory.updated` | `op, bytes` | `memory` tool wrote |
| `tool.result` (extended) | adds optional `preview` (≤40-line diff or excerpt) | file tools |

Unchanged: `run.start step.start tool.proposed policy.decision tool.result tool.cancelled journal.* confinement.* agent.final agent.halt`.
The TUI (`tui/src/events.rs`) already tolerates unknown kinds and malformed lines.
