# SPEC-009 — Skills (reusable notes, never code)

**Status:** implemented in 0.8.0 · **Invariant:** I1, I4 reused · **Roadmap:** M5-lite

## Goals
Let the agent (and the operator) keep reusable how-to notes in the agentskills.io `SKILL.md` shape, find them by
name and description, and load one when it is relevant.

## Non-goals
Executing anything a skill contains; skills that add tools, change policy or edit the system prompt; a skill hub;
auto-loading skills into the prompt.

## Layout and format
`<state>/skills/<name>/SKILL.md` (state dir, never the workspace). `<name>` matches `[a-z0-9][a-z0-9-]{0,47}`.
The file starts with a frontmatter block:

    ---
    name: <same as the directory>
    description: <one line, 1-300 characters>
    ---
    free-form markdown

Other files in the skill directory (scripts, references) are listed by `skill_view` but never read or run by it.

## Tools (`--skills`)
| Tool | Args | Effect | Notes |
|---|---|---|---|
| `skills_list` | — | B0 | name + description of up to 100 valid skills |
| `skill_view` | `name` | B0 | SKILL.md (≤ 16 KiB) and the names of up to 50 other files |
| `skill_save` | `name`, `content` | B2 (journaled) | **always ASK** (`approval.dangerous`); atomic, 0600 file in a 0700 directory |

The system prompt gains one fixed sentence saying skills exist and are notes, not permissions; no skill text is
ever placed in the prompt. A skill's text reaches the model only as a tool result.

## Strictness
Skill directories and `SKILL.md` must be real (no symlinks), owned by the operator, and not group/world-writable;
anything else is skipped and reported by `skills_list` as `skipped: <name> (<reason>)`. Frontmatter `name` must equal
the directory name. `skill_save` refuses invalid names/content and never writes outside `<state>/skills/<name>/`.

## Invariants
Skills are data (I1): a skill that says "enable the shell" changes neither the tool list nor any verdict. Because
nothing a skill contains is executed or loaded as configuration, plugins-cannot-modify-the-kernel (I4) stays
vacuous.

## Tests and mutants
Name validation, frontmatter parsing (valid, missing, mismatched), listing skips symlinks/unsafe modes, view caps,
save is ASK in the default layers and refuses bad input, injection text changes nothing.
**Mutants:** follow symlinks; skip name validation (traversal); skill_save not ASK; accept mismatched frontmatter name.
