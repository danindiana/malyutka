# SPEC-010 — MCP client (stdio)

**Status:** implemented in 0.8.0 · **Invariant:** I17 (new) · **Roadmap:** M2 tail / M6 groundwork

## Goals
Use tools from [Model Context Protocol](https://modelcontextprotocol.io) servers without giving up the gates: every
MCP tool is a capability with an operator-chosen ceiling, asks before it runs, and its output is data.

## Non-goals
HTTP/SSE transports, MCP resources/prompts/sampling, servers that need the network while sandboxed, auto-discovery.

## Operator config `<state>/mcp.json` (`--mcp`)
Strict file (real file, operator-owned, not group/world-writable; never in the workspace):

    {"servers": [{"name": "notes", "command": ["python3", "/opt/notes/server.py"],
                  "envAllow": ["LANG"], "sandbox": true, "maxEffect": "B1",
                  "trust": "ask", "timeoutSec": 30}]}

`name` `[a-z0-9]{1,16}`; `maxEffect` B0, B1 or B2 (B3+ rejected); `trust` `ask` (default) or `allow`, and `allow`
is accepted only when `maxEffect` is `B0`. `sandbox:false` runs the server on the host and **requires the
`--unconfined-host` waiver** (no silent fallback; I6) and emits `confinement.waived`.

## Process and protocol
- One server process per run. `sandbox:true`: the same bwrap broker as `shell` (read-only system dirs, workspace
  rw, no network, scrubbed environment plus `envAllow` names), so only programs visible inside the sandbox can run.
  Killed when the run ends (also on exception), never outliving it.
- JSON-RPC 2.0, one JSON message per line. `initialize` → `notifications/initialized` → `tools/list` (≤ 100 tools,
  paginated) → `tools/call`. Server requests we do not support get `-32601`. Line cap 1 MiB; result text cap 64 KiB
  (truncation flagged); per-call timeout (`timeoutSec`, default 30; init 15 s). A timeout or protocol error kills the
  server and every later call to it fails cleanly (no desynchronised stream).

## Tools
- Registered as `mcp_<server>_<tool>` with the tool part sanitised to `[a-z0-9_]`; names ≤ 64 characters.
  A name that collides with a built-in or an earlier MCP tool is **refused** (`mcp.refused` event).
- Description = `[MCP <server>] ` + the server's text capped at 500 characters; parameters = the server's
  `inputSchema` if it is a JSON object schema ≤ 16 KiB, else `{"type":"object"}`.
- Capability: realm `external`, ceiling = the server's `maxEffect`; `effectOf` returns the ceiling (we cannot know a
  call's real effect). B1+ is journaled.
- Policy layer `mcp.ask`: every MCP call is **ASK** unless the server is `trust:allow` (B0 only). ASK resolves through
  the usual chain: latched mandate, then the approver, else deny.

## Notes from the implementation
- Tools the server lists that cannot be used (empty or over-long names, malformed entries) are dropped with an
  `mcp.refused` event rather than silently.
- A sandboxed server only sees what the sandbox shows: system directories read-only and the workspace. A program
  in `$HOME` is not visible; use an absolute path under `/usr` or `/opt`, a copy in the workspace, or `sandbox:false`
  with the waiver.
- The `mcp.*` events are queued while the registry is built (`toolsFor` cannot emit) and emitted right after
  `run.start`.

## Invariant I17
An MCP tool never runs above its configured ceiling, cannot shadow a built-in tool, cannot run unasked (unless the
operator marked a B0 server `allow`), and its output and descriptions are data (I1).

## Events
`mcp.connected {server, tools}`, `mcp.failed {server, reason}`, `mcp.refused {server, tool, reason}`.

## Tests and mutants (`tests/fake_mcp.py`)
Well-behaved server; hangs; floods; bad JSON; wrong ids; oversize lines; lies about names (collision, invalid
characters); server requests; exits mid-call; env scrubbing; sandbox escape attempts from the server; config strictness.
**Mutants:** ceiling ignored; ASK layer skipped; collision allowed; no timeout; unconfined without waiver;
`trust:allow` accepted above B0; server not killed at run end.
