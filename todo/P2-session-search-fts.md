# Session search (SQLite FTS5)

**Priority:** P2 · **Size:** M · **Depends on:** SPEC-003

## What
Full-text search over past sessions (`malyutka sessions --search` v1 is substring only). Optionally an LLM summary for recall.

## Why / Hermes reference
Hermes: `session_search` tool over SQLite+FTS5.

## Invariant and design notes
Needs a SQLite binding that builds on Nim 1.6.14 and 2.2.x; the DB is a derived index, rebuildable from `sessions/*.json`, never the source of truth.
