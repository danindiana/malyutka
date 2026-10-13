# Skills (agentskills.io SKILL.md)

**Priority:** P2 · **Size:** M · **Depends on:** SPEC-001, SPEC-004

## What
Folders of `SKILL.md` the agent can list/load; optional agent-authored skills.

## Why / Hermes reference
Hermes skills system and Skills Hub.

## Invariant and design notes
Skills are data (I1) and cannot add capabilities (I4). Agent-created skills go to a state-dir path via a dedicated, journaled tool.
