# Provider retry on transient errors

**Priority:** P2 · **Size:** S · **Depends on:** —

## What
Retry a model request a bounded number of times (with backoff) on HTTP 5xx and timeouts before the run
fails with exit 1.

## Why / evidence
Live validation hit `provider HTTP 500: XML syntax error ... element <function> closed by </parameter>`
from Ollama's tool-call parser with qwen3.5:9b (docs/certification/M2-live-calisota-20261013.md). A single
retry usually gets a different sample. Without it, one parser hiccup ends a long agent run.

## Invariant and design notes
A model request has no side effects, so retrying it is safe; tool calls are never retried. Each retry must
be visible (`provider.retry` event with the error), bounded (default 2), and must not repeat after a
`context.compaction` or journal state change. Never retry 4xx (bad request / auth).
