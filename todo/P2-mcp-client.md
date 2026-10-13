# MCP client (stdio)

**Priority:** P2 · **Size:** M · **Depends on:** SPEC-002

## What
Spawn MCP servers over stdio and expose their tools through the registry.

## Why / Hermes reference
Hermes: `mcp-<server>` toolsets.

## Invariant and design notes
Each MCP server is its own realm with a low capability ceiling; tool calls default to ASK; server process runs inside the sandbox broker.
