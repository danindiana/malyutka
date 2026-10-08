# MALYUTKA // 9M14

**Malyutka** is a small, Linux-native, model-neutral agent harness written in Nim.
The 9M14 name is visual identity and mascot only: the engineering goals it evokes
are simplicity, robustness, low deployment cost, portability, and easy adaptation.

> Small kernel. Replaceable edges. Model proposes; policy disposes.

## M1.1 — Guidance, confined

The kernel executes:

`Provider -> Agent Loop -> Typed Tool Proposal -> Policy -> Tool Registry -> Observation`

Current features:

- native Nim CLI (`malyutka`)
- deterministic mock provider for offline tests
- OpenAI-compatible `/v1/chat/completions` provider
- Ollama and vLLM presets through the same provider
- structured function/tool-call parsing
- capability registry: disabled tools are never advertised to the model
- policy kernel: monotonic layers (DENY < ASK < ALLOW), effect ceilings,
  every decision names the responsible policy
- `echo` and opt-in `shell`; the shell runs under bubblewrap: allowlisted
  read-only system dirs, writable workspace, no `/home` `/run` `/var`, no
  network or host sockets, no inherited fds, scrubbed env, timeout, output
  cap, and it dies with the harness. The run is refused if the sandbox is
  unavailable
- write-ahead journal: side-effecting actions are durably recorded before
  they run; interrupted ones are reported as UNKNOWN_OUTCOME, never re-run
- repetition halt: identical consecutive tool calls stop the run
- persistent last-session transcript
- canonical JSONL event mode with run-scoped event IDs and `causedBy` links
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

**Compile status:** 0.3.1 builds warning-free on **Nim 1.6.14** with
bubblewrap 0.9.0 and passes 59 tests (48 unit/adversarial + 11 CLI
integration) both as root and as an **unprivileged user**. It has **not yet
been run on Nim 2.x**, nor on a host with Ubuntu 24.04's AppArmor
user-namespace restriction (the test VM lacks it). Do not use `apt install nim` on Ubuntu 24.04 (it is
1.6.14); use choosenim:

```sh
curl https://nim-lang.org/choosenim/init.sh -sSf | sh
sudo apt install bubblewrap
./malyutka doctor        # must report "sandbox: bwrap OK" for --allow-shell
nimble test && tests/integration.sh ./malyutka
```

See `ARCHITECTURE.md` for the authority pipeline and invariant status.

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

`--allow-shell` enables a *sandboxed* shell: the current directory is the only
writable path, there is no network, and the child environment carries no
credentials. If bubblewrap is missing or unusable, the run is refused (exit 3);
it never falls back to the host.

Running on the host requires an explicit, logged waiver:

```sh
./malyutka run --allow-shell --unconfined-host 'task'   # emits confinement.waived
```

Exit codes: 0 answered, 1 failure, 2 usage, 3 confinement unavailable,
4 halted (maxSteps or repetition), 5 journal unavailable / unknown outcomes
pending.

## Journal

Every side-effecting action is journaled (fdatasync'd) as intent → decision →
started → outcome in `~/.local/state/malyutka/journal.jsonl`, outside any
workspace and invisible to the sandbox. If Malyutka dies mid-action:

```sh
./malyutka journal                 # lists UNKNOWN_OUTCOME actions (exit 5)
./malyutka journal --ack:9M14-…    # after inspecting the workspace
```

Interrupted actions are surfaced on every run until acknowledged. They are
never re-executed.

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
- `src/malyutka/tools.nim` — capability registry (realm, effect ceiling, schema)
- `src/malyutka/policy.nim` — policy kernel (monotonic layer composition)
- `src/malyutka/sandbox.nim` — bubblewrap broker, probe, fd-clean bounded execution
- `src/malyutka/journal.nim` — write-ahead action journal
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

### M1.2 — Adversarial certification

Acceptance: every suite passes, with no unexpected host writes, no
credential exposure, and no silently unconfined execution.

- Nim 2.x compile + full suite.
- Live Ollama and vLLM round trips.
- Non-root on stock Ubuntu 24.04 with the AppArmor userns restriction.
- Already done in 0.3.1: protocol fuzzing, containment and escape
  regression tests, forced termination during tool execution, journal crash
  consistency.
- Remaining: an interactive ASK approver with approval crash consistency,
  and SSE streaming.

### M2 — Linux capability layer

Native read/write/patch/find/grep/process tools; bounded output; path scopes;
capability descriptors; ASK approvals.

### M3 — Isolation, deepened

The bubblewrap backend and capability/authorization/isolation split landed in
M1.1. M3 adds per-capability filesystem/network scopes, cgroup or rlimit
process limits, seccomp, an interactive ASK approver, and a credential broker.

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
