# SPEC-004 — Memory, SOUL.md, personalities

**Status:** implemented in 0.5.0 · **Invariant:** I1 (model output is data) reused · **Roadmap:** M5-lite

## Goals
Durable notes across sessions, and an operator-controlled voice for the agent.

## Non-goals
Vector memory, user modelling services, automatic memory nudges.

## Memory (`memory` tool, B2, journaled)
File `$STATE/memory.md`, ≤ 8 KiB. Ops: `add{text}`, `replace{old,new}`, `remove{text}`.
It is the **only** state-dir file a tool may write, and only through this tool. At run start the
file is snapshotted into the system prompt inside a fenced block labelled *untrusted notes*;
mid-run edits take effect next run. Over the cap ⇒ tool error.

## SOUL.md and personalities
`$STATE/SOUL.md` (or `--soul:path`) is prepended to the system prompt; it is operator text, trusted
like the system prompt but still cannot grant capabilities. `--personality:<preset>` selects a built-in
snippet: `concise`, `teacher`, `kawaii`, `terse-ops`. Neither affects tool availability or policy.

## Failure modes
Missing file ⇒ empty. Symlink or wrong mode on `memory.md`/`SOUL.md` ⇒ refused. Memory containing
instructions is still data: it cannot change policy (tested).

## Tests and mutants
Cap enforcement, symlink refusal, injection text in memory does not alter tool list/policy, journaling of
each write. **Mutants:** let memory text appear outside the fenced block; follow symlinks.
