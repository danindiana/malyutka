# Changelog

## 0.3.0 — M1.1 "Guidance, confined"

First version actually compiled and tested (Nim 1.6.14; Nim 2.x pending).

### Fixed
- Compile error: `policy.nim` used `hasKey` on JSON without importing `std/json`.
- **Tool-call wire protocol.** M1 sent tool results as `tool` messages without
  `tool_call_id` and never sent the assistant `tool_calls` message, so strict
  OpenAI-compatible servers (vLLM, OpenAI) returned HTTP 400 on the first tool
  round-trip. Reproduced against `tests/fake_openai.py`.
- Only the first of several tool calls in a turn was handled; the rest were
  silently dropped. All calls are now handled in order.
- Object-valued tool arguments (some Ollama versions) were replaced by `{}`.
- The HTTP client leaked one connection per step; no request timeout;
  non-JSON error bodies produced a parse error instead of the HTTP status.
- The shell was advertised to the model even when disabled.
- A missing `--config` file was silently ignored; unknown flags only warned.

### Security
- `--allow-shell` ran commands **unconfined on the host** behind a substring
  denylist. Verified: given the same model output, M1 wrote into `/etc` when
  run as root. The shell now runs under bubblewrap, and the run is refused if
  the sandbox is unavailable. Host execution needs `--unconfined-host`.
- Shell children inherited the harness environment, including
  `MALYUTKA_API_KEY`; a model-issued `env` would have exposed it. Children
  now get a scrubbed environment.
- Shell commands had no timeout or output limit.

### Added
- Authority kernel types: `Capability`, `ExecutionRealm`, `EffectClass` (B0–B4),
  `Verdict`, `Decision{policyId}`; monotonic `compose` with effect ceilings.
- Run-scoped event IDs with `causedBy` links; stable string enum values.
- Repetition halt (`--repeat-limit`), exit codes, `doctor` sandbox probe.
- `ARCHITECTURE.md` with invariant status; `tests/test_invariants.nim` with one
  test per enforced invariant.
