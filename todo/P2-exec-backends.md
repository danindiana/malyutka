# Docker / SSH execution backends

**Priority:** P2 · **Size:** M · **Depends on:** realm erRemote

## What
Alternate execution realms for the shell tool.

## Why / Hermes reference
Hermes: seven terminal backends.

## Invariant and design notes
Reserved realm `erRemote` already exists in types. Each backend needs its own confinement proof and probe (I5/I6).
