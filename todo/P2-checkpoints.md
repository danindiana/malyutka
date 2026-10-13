# Checkpoints and rollback

**Priority:** P2 · **Size:** M · **Depends on:** SPEC-001

## What
Snapshot the workspace before file edits; `/rollback`.

## Why / Hermes reference
Hermes checkpoints page (not read in depth).

## Invariant and design notes
Likely git-based or copy-on-write; must not touch the user's own repository history.
