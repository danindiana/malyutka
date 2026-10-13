# Context compression

**Priority:** P2 · **Size:** M · **Depends on:** SPEC-003

## What
Summarise older turns when the context nears the model window; manual `/compress`.

## Why / Hermes reference
Hermes: `/compress` and automatic compression.

## Invariant and design notes
Closes invariant I10 (context loss is observable): emit `context.compacted` with what was dropped, keep originals in the session file, never drop unanswered tool calls.
