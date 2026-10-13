# Background process tool

**Priority:** P2 · **Size:** M · **Depends on:** M3 (cgroups)

## What
Start/poll/log/kill long-running commands.

## Why / Hermes reference
Hermes: `process` tool.

## Invariant and design notes
Needs cgroup-based cleanup first, otherwise children survive harness death (documented limit).
