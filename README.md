# MALYUTKA // 9M14

**Malyutka** is a small, Linux-native, model-neutral agent harness written in Nim.
The 9M14 name is visual identity and mascot only: the engineering goals it evokes
are simplicity, robustness, low deployment cost, portability, and easy adaptation.

> Small kernel. Replaceable edges. Model proposes; policy disposes.

## M1 — Guidance

The kernel executes:

`Provider -> Agent Loop -> Typed Tool Proposal -> Policy -> Tool Registry -> Observation`

Current features:

- native Nim CLI (`malyutka`)
- deterministic mock provider for offline tests
- OpenAI-compatible `/v1/chat/completions` provider
- Ollama and vLLM presets through the same provider
- structured function/tool-call parsing
- typed policy gate before tool execution
- `echo` and opt-in `shell` capabilities
- persistent last-session transcript
- canonical JSONL event mode for automation/replay
- dependency-light retro terminal event view
- `warsaw`, `nato`, and `plain` themes
- JSON config + environment overrides

The Warsaw/NATO distinction is presentation only. It never changes policy or
agent semantics.

## Build

Requires Nim >= 2.0.

```sh
nimble build
./malyutka doctor
./malyutka run 'inspect this repository'
nimble test
```

This generation environment does not contain Nim, so the source has been
statically inspected but **not claimed to compile yet**. The first action on a
Nim-equipped Linux host should be `nimble test` followed by compiler cleanup.

## Ollama

Ollama's OpenAI-compatible endpoint is the default local URL:

```sh
./malyutka run \
  --provider:ollama \
  --model:qwen3.5:latest \
  --base-url:http://127.0.0.1:11434 \
  'Summarize the repository structure.'
```

Shell execution is disabled unless explicitly enabled:

```sh
./malyutka run --provider:ollama --model:qwen3.5:latest --allow-shell \
  'Use pwd and list the current directory.'
```

`--allow-shell` is capability enablement, not blanket trust: policy still
intercepts the proposed command.

## Generic OpenAI-compatible server

```sh
export MALYUTKA_API_KEY='...'
./malyutka run \
  --provider:openai \
  --base-url:https://example.invalid/v1 \
  --model:some-model \
  'Perform the task.'
```

## Configuration

Copy `config.example.json` and invoke:

```sh
./malyutka run --config:my-config.json 'Perform the task.'
```

Environment variables:

- `MALYUTKA_PROVIDER`
- `MALYUTKA_MODEL`
- `MALYUTKA_BASE_URL`
- `MALYUTKA_API_KEY`

## Themes

```sh
./malyutka run --theme:warsaw 'task'   # green phosphor
./malyutka run --theme:nato 'task'     # amber
./malyutka run --theme:plain 'task'    # no ANSI color
```

Machine consumers should bypass presentation entirely:

```sh
./malyutka run --json 'task' > trace.jsonl
```

## Source layout

- `src/malyutka.nim` — CLI
- `src/malyutka/core.nim` — guidance/agent state machine
- `src/malyutka/provider.nim` — provider ABI, mock, OpenAI-compatible adapter
- `src/malyutka/tools.nim` — capability registry
- `src/malyutka/policy.nim` — authorization gate
- `src/malyutka/events.nim` — canonical JSONL + themed console sinks
- `src/malyutka/session.nim` — transcript persistence
- `src/malyutka/config.nim` — configuration and themes

## Architectural invariants

1. **Model proposes; policy disposes.** Providers cannot execute OS operations.
2. **Events are semantic, presentation is optional.** JSONL is suitable for replay and metrics; themes are merely views.
3. **Provider identity is not agent identity.** The model/backend can be replaced without changing the kernel.
4. **Autonomy follows isolation.** Richer tools should not precede the Linux sandbox/capability boundary.
5. **Stopping is a controller.** `maxSteps` is temporary and will be replaced by an explicit metacognitive controller.

## Roadmap

### M1.1 — Compile certification + streaming

Run against Nim 2.x, resolve compiler/API differences, add SSE incremental token
streaming while preserving structured tool-call assembly, and integration-test
against Ollama and vLLM.

### M2 — Linux capability layer

Native read/write/patch/find/grep/process tools; bounded output; path scopes;
capability descriptors; ASK approvals.

### M3 — Isolation

Bubblewrap execution backend, filesystem/network policy, process limits, and a
clear distinction among capability, authorization, and isolation.

### M4 — Ledger

SQLite sessions/events, resumable runs, content-addressed artifacts, deterministic
replay, run IDs, provider/model/config provenance.

### M5 — Context

Token accounting, compaction, evidence-preserving summaries, project instruction
files, and progressively disclosed skills.

### M6 — Delegation

Isolated child contexts/workspaces, parent-child lineage, per-child budgets,
parallel workers, synthesis.

### M7 — Metacritic

Replace fixed `maxSteps` with EVoC/hysteresis and regimes:

`PRODUCTIVE -> SUSPECT -> PLATEAU`

Controller actions:

`CONTINUE | REDIRECT | DELEGATE | COMPACT | HALT`

### M8 — Harness laboratory

Interchangeable controllers/providers/models and useful-work-per-token,
GPU-hour, wall-time, dollar, and tool-call evaluation.

## License

MIT. The Malyutka/9M14 designation is project branding; no affiliation with any
historical manufacturer, government, or military organization is implied.
