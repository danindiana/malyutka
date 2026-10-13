# SPEC-001 — File tools and `todo`

**Status:** planned · **Invariant:** I13 (new) · **Roadmap:** M2

## Goals
Let the model read, search, create and edit files in the workspace without going through
`sh -c`, so edits are exact (no quoting accidents), cheap, and individually journaled.

## Non-goals
Anything outside the workspace; binary editing; recursive delete/move (use `shell`);
file watching; git integration.

## Interface
Enabled with `--allow-files` (config `allowFiles`). Not implied by `--allow-shell`.
Realm `erInProcess`. All paths are relative to the workspace.

| Tool | Args | Effect | Notes |
|---|---|---|---|
| `read_file` | `path`, `offset?`, `limit?` | B1 | line-numbered output, 256 KiB cap, refuses binary (NUL in first 8 KiB) |
| `search_files` | `pattern`, `path?`, `glob?` | B1 | substring walk (no regex v1), result count and byte caps, skips `.git/` |
| `write_file` | `path`, `content` | B2 | creates parents inside the workspace, 1 MiB cap, atomic (tmp + rename) |
| `patch` | `path`, `old`, `new`, `replace_all?` | B2 | fails when `old` is absent, or ambiguous without `replace_all`; returns a ≤40-line diff preview |
| `todo` | `items: [{id, text, status}]` | B0 | in-process list, replaces the whole list, emits `todo.update` |

`effectOf` returns the real effect of each call. B1+ requires a journal (existing rule in `core.nim`).

## Invariant I13 — file tools cannot reach outside the workspace
`resolveInWorkspace(ws, rel)`: reject absolute paths and any `..` component; open each
component with `O_NOFOLLOW`; re-validate the final fd via `/proc/self/fd` against the
workspace realpath (same technique as `openWorkspace` in `sandbox.nim`).
Residual risks, documented in `SECURITY.md`: an operator-placed hard link is writable
through; a concurrent sandboxed process can race the check (TOCTOU) inside the workspace
but still cannot leave it, because every component is opened with `O_NOFOLLOW`.

## Failure modes
Oversize → tool error (not a crash); non-UTF-8 → error; disk full → `ok:false` with errno text;
partial write is impossible (tmp + rename).

## Tests and mutants
Traversal, absolute path, symlink out, symlink in the middle, workspace given as symlink,
oversize read/write, binary read, ambiguous patch, atomicity (kill during write).
**Mutants:** drop the `..` check; follow symlinks; skip the fd re-validation — each must fail a named test.

## Rollout
Off by default. TUI shows `read_file 📖`, `write_file ✍️`, `patch 🔧`, `search_files 🔎`, `todo 📋`.
