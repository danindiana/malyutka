# Subagent delegation

**Priority:** P2 · **Size:** M-L · **Depends on:** M6, compression

## What
Child runs with isolated context and a capability subset of the parent.

## Why / Hermes reference
Hermes: `delegate_task`.

## Invariant and design notes
Invariant I3: child ⊆ parent capabilities and budgets. Start sequential; parallel later.
