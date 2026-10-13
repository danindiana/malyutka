# SPEC-002 — ASK approvals

**Status:** planned · **Invariant:** I14 (new) · **Roadmap:** M2

## Goals
Make `ASK` real: dangerous-but-legitimate actions pause for an operator decision instead of
being denied outright, while preserving fail-closed behaviour when nobody answers.

## Non-goals
LLM-judged "smart" approval; per-user pairing; remote approval channels.

## Policy layers (in `policy.nim`)
1. `hardline` — **always DENY**, never overridable by allowlist or `--approvals:off`:
   `rm -rf /`, `mkfs*`, fork bomb, `dd of=/dev/…`, writes to `/proc`, `/sys`.
2. `approval.dangerous` — **ASK**: `curl|sh`, `wget|sh`, `chmod -R 777`, `git push --force`,
   `DROP TABLE`, `rm -rf` of anything not workspace-relative, writes to `/etc`, to `.ssh`, to `.env`.
3. existing layers (`capability.ceiling`, `confinement`, `heuristic.denylist`) unchanged.
Lowest verdict still wins; DENY short-circuits.

## Approver
`--approvals:deny` (default, today's behaviour) · `stdin` · `tty` · `off` (requires `--i-know-approvals-off`).
Answers: `once`, `session`, `always`, `deny`.

`stdin` protocol (used by the TUI): the harness emits
`approval.request {id, action, tool, args, reason, expiresAt}`; the controller writes one JSON
line `{"id": "<same id>", "answer": "once|session|always|deny"}` to the harness's stdin.
Unknown id, malformed line, oversize line (>4 KiB) → ignored and logged; 300 s without a valid
answer → `deny` (`approval.answer {answer:"deny", reason:"timeout"}`).

## Grants
`session`: in-memory set of normalised keys. `always`: appended to `$STATE/allowlist.json`
(0600, `O_NOFOLLOW`, strict schema + checksum decode, must live outside the workspace;
corrupt allowlist ⇒ ignored and reported, never trusted partially).
Key = tool name + normalised args (whitespace-collapsed command).

## Invariant I14
Approval can only turn `ASK` into `ALLOW`. It can never change a `DENY`. Every `ASK` produces
exactly one terminal answer (extends property P). The journal decision record names policy
`approval.user` and stores the answer.

## Failure modes
Controller disappears (stdin EOF) → treated as `deny` for all pending and future ASKs.
Answer arrives after timeout → ignored.

## Tests and mutants
Allowlist poisoning (symlink, wrong mode, junk, huge), wrong-id answers, duplicate answers,
timeout, EOF, hardline-vs-allowlist, hardline-vs-`off`, fuzzed ASK/answer interleavings.
**Mutants:** allowlist checked before hardline; EOF treated as allow; accept answers for any id.

## Rollout
Default stays `deny`. TUI shows a modal with a 300 s countdown.
