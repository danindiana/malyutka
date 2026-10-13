# SPEC-003 — Incremental sessions and resume

**Status:** implemented in 0.5.0 · **Invariant:** I15 (new) · **Roadmap:** M4-lite

## Goals
A crash keeps the transcript; a follow-up prompt continues the conversation; the TUI becomes multi-turn.

## Non-goals
Replay of tool effects; compaction (M5); full-text search index (see `todo/P2-session-search-fts.md`).

## Format (`sessions/<run>.json`)
Existing `{run, messages[]}` plus meta:
`{schema: 2, run, meta: {parent, title, provider, model, startedAt, updatedAt, status: running|answered|halted}, messages}`.
Written atomically (tmp + fsync + rename) **after every step**, not just at the end.
Strict decoder; unknown schema ⇒ refuse (no silent best-effort).

## CLI
- `malyutka run --resume:<runId|last> [opts] "<follow-up>"` — load, `validateTranscript`, append the
  user message, start a **new** run id whose `parent` is the old one.
- `malyutka sessions [--json]` list; `--show:ID`; `--search:TEXT` (case-insensitive substring).
- Resume is refused when validation fails, or when the parent's journal still has unresolved
  `UNKNOWN_OUTCOME`/`OWNER_STATUS_UNKNOWN` actions, unless `--resume-despite-unknown` (the catch-22 is surfaced, not hidden).

## Invariant I15 — resume never re-executes
Resume rebuilds the *message list* only. No journaled action is replayed, re-proposed, or re-run;
tool messages in the loaded transcript are inert history.

## TUI
Keeps `last_run_id`, passes `--resume`. `/new` forgets it. `/retry` = rerun last prompt from the parent
of the last run; `/undo` = discard the last turn and resume from its parent. The TUI never writes session files.

## Tests and mutants
Round trip; crash mid-run leaves a valid file; truncated/garbled file refused; schema mismatch refused;
transcript with dangling tool call refused; resume with unknown outcomes refused/overridden; resume does not
touch the journal's action count. **Mutants:** write non-atomically; skip validation; replay tool calls on resume.
