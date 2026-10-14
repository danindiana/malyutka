# SPEC-007 — Ranked session search

**Status:** implemented in 0.6.0 · **Roadmap:** M5-lite

## Goals
`malyutka sessions --search` returns the most relevant sessions first, quickly, across hundreds of sessions.

## Non-goals
SQLite/FTS5 (rejected: a native dependency, Nim 1.6 `db_sqlite` quirks, and no need below ~10k sessions —
revisit then); fuzzy or semantic matching.

## Design
- Query = lowercase words of ≥ 2 characters. Score per session = Σ over query words of
  `min(count, 20)` in non-system messages, plus a small recency tiebreak (newer first).
- Derived cache `sessions/.index.json` (0600, atomic write): per session `{mtime, size, words: {word: count}}`
  (≤ 500 distinct words). It is **only a cache**: an entry is used only if the file's mtime (with nanoseconds)
  and size match; otherwise the file is re-read and the entry replaced. An index that fails the strict decode
  is ignored and rebuilt. Deleting it loses nothing.
- Output: top `--limit` sessions (default 10) with the best snippet and score; `--json` supported.
- TUI: `/search <text>`.

## Tests and mutants
Ranking order, recency tiebreak, stale entry replaced, poisoned/garbled index rebuilt (never trusted over the
files), symlinked index refused, undecodable sessions skipped.
**Equivalent mutants (documented):** dropping the explicit symlink check in `loadIndex` (the O_NOFOLLOW reader already refuses it) and dropping the word-count type check (a mistyped count reads as 0 and a stale stamp is re-read anyway).
**Mutants:** trust an entry without checking mtime/size; read a symlinked index; rank by recency only.
