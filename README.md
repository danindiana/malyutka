# MALYUTKA // 9M14
<img width="554" height="554" alt="Retro 9M14 Malyutka HUD Emblem" src="https://github.com/user-attachments/assets/615c3425-a17c-4eac-a0bd-724805a2d6ca" />

[![CI](https://github.com/danindiana/malyutka/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/danindiana/malyutka/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Nim](https://img.shields.io/badge/nim-1.6.14%20%7C%202.2-ffe953?logo=nim&logoColor=black)](#compiler-support)
[![Platform](https://img.shields.io/badge/platform-linux-informational?logo=linux&logoColor=white)](#requirements)
[![Sandbox](https://img.shields.io/badge/sandbox-bubblewrap-3fb950)](#the-sandbox)
[![Version](https://img.shields.io/github/v/tag/danindiana/malyutka?label=version&color=d29922)](CHANGELOG.md)
[![Milestone](https://img.shields.io/badge/M1.2-certified%20(Ubuntu%2022.04)-3fb950)](docs/certification/M1.2-calisota-20261007.md)

**A small, Linux-native, model-neutral agent harness written in Nim.**

> Small kernel. Replaceable edges. **Model proposes; policy disposes.**

Malyutka runs the agent loop (model → tool call → observation → model) and
puts every step a model takes through independent gates:

1. a **capability registry**: tools that are off do not exist, even in the
   model's context;
2. a **write-ahead journal**: nothing with side effects runs before its intent
   is on disk;
3. a **policy kernel**: deny always dominates allow;
4. a **bubblewrap sandbox**: the model's shell sees an empty filesystem plus an
   allowlist, no network, no host sockets, no secrets.

It speaks the OpenAI-compatible chat API, so the same harness drives Ollama,
vLLM or any compatible server. Holding the harness constant while the model
varies is the point: it is a substrate for measuring how much of an agent's
behaviour comes from the model and how much from the control system around it.

The name and the green/amber terminal themes are visual identity only (see
[Name](#name)).

---

## Contents

- [Project status](#project-status)
- [Quick start](#quick-start)
- [Requirements](#requirements)
- [Usage](#usage)
- [Architecture](#architecture)
- [The sandbox](#the-sandbox)
- [The journal](#the-journal)
- [Security model and limits](#security-model-and-limits)
- [Testing and certification](#testing-and-certification)
- [Compiler support](#compiler-support)
- [Repository layout](#repository-layout)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Name](#name)
- [License](#license)

---

## Project status

Design docs: [`docs/`](docs/README.md) (Hermes gap analysis, diagrams) · specs: [`spec/`](spec/README.md) · future work: [`todo/`](todo/README.md).

**v0.5.0: M1 (guidance loop) complete; M2 file tools, ASK approvals and the commitment latch, and M4-lite sessions/resume/memory added; M1.2 (integration certification)
passed on a real host**, with one configuration still open: Ubuntu 24.04
with its AppArmor restriction active (see the table).

| Evidence | Status |
|---|---|
| Offline suites: 331 unit/invariant/adversarial/latch/session/compaction/process/skills/MCP/web + 80 CLI integration | pass on Nim 1.6.14 and 2.2.12 locally (web fetch and search, unreleased); the Nim 1.6.14 matrix runs in CI |
| Native Nim 2.x build and tests | pass on CI (Nim 2.2.x, ubuntu-24.04, unprivileged runner) |
| Nim 2.2.4 semantic check (`nim check`) | 0 diagnostics in Malyutka sources |
| Live Ollama tool calling on a real host (qwen3.5:27b): single + multi-call, sandboxed shell, model-issued escape attempt, live SIGKILL + restart | **certified**: [record](docs/certification/M1.2-calisota-20261007.md) (Ubuntu 22.04, Nim 2.2.12, bwrap 0.6.1) |
| M2 features (file tools, approvals, resume, memory, mandates) with real models (qwen3.5 9b/27b, devstral-small-2:24b, gpt-oss:20b) | **validated**: [record](docs/certification/M2-live-calisota-20261013.md), `tests/m2-live.sh` (8 checks x 4 models, 0 failures) |
| vLLM | optional; not yet run live |
| bubblewrap with Ubuntu 24.04's AppArmor userns restriction **active** | **untested**: the certification host and CI both run without it |

Malyutka is early-stage research software. Its *defenses* are tested
adversarially, and each test is checked by deliberately breaking the defense
it covers. Its *capabilities* are deliberately minimal: today the model has
`echo`, a sandboxed `shell`, and (opt-in with `--allow-files`) workspace-confined
file tools. ASK approvals are real since 0.4.0 but fail closed by default.

---

## Quick start

```sh
# Toolchain (Ubuntu 24.04's apt nim is 1.6.14, which is supported)
sudo apt install nim bubblewrap

git clone https://github.com/danindiana/malyutka.git
cd malyutka
nimble build -y
./malyutka doctor          # must report "sandbox: bwrap OK" before using --allow-shell

# Offline demo: scripted mock provider, no model needed
./malyutka run 'say hello'

# Against a local Ollama model
ollama pull qwen3.5:latest
./malyutka run --provider:ollama --model:qwen3.5:latest 'Summarize what a harness is.'

# Give the model a sandboxed shell in the current directory
./malyutka run --provider:ollama --model:qwen3.5:latest --allow-shell \
  'List the files here and tell me which is largest.'
```

The console view in the default `warsaw` theme (an illustrative run):

```
+--------------------------------------------------------------+
| MALYUTKA // 9M14                         GUIDANCE : READY    |
| LINUX NATIVE AGENT HARNESS               LINK     : LOCAL    |
+--------------------------------------------------------------+
  PROVIDER  ollama
  MODEL     qwen3.5:latest
  SHELL     SANDBOX (bwrap)
  MODE      WARSAW
+--------------------------------------------------------------+
  0001 RUN   9M14-6ad179ef  tools=["echo","shell"]
  0002 STEP  #0
  0003 ACT   shell {"command":"ls -la"}
  0004 POL   [ALLOW] B2  default: no layer objected
  0005 OBS   shell  exit=0
  0006 STEP  #1
  0007 DONE  The largest file is …
```

---

## Requirements

- **Linux** with unprivileged user namespaces (for bubblewrap).
- **Nim ≥ 1.6.14**. CI tests 1.6.14 and 2.2.x.
- **bubblewrap**, for `--allow-shell`. Malyutka refuses to run a sandboxed
  shell it cannot confine (exit 3); it never falls back to the host.
- **python3**, only for the test suites' fake servers.

### Ubuntu 24.04 and AppArmor

Ubuntu 24.04 can restrict unprivileged user namespaces through AppArmor,
which blocks bubblewrap. `./malyutka doctor` runs the exact sandbox used for
tools and tells you whether it works. If it reports the sandbox unavailable,
there are two options:

- **Preferred:** an AppArmor profile that grants `userns` to
  `/usr/bin/bwrap` only.
- **System-wide:** `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.
  This is simpler, but it relaxes a hardening measure for every program,
  which is fine on a disposable CI runner (as this repository's CI does) and
  a real tradeoff on a workstation.

---

## Usage

```
malyutka run [options] <task>
malyutka doctor
malyutka journal                     Journal health + actions with unknown outcome
malyutka sessions [--json]           list saved sessions; --show:ID, --search:TEXT
malyutka journal --reconcile:ID --as:completed|failed|not-executed
malyutka journal --ack:ID            Mark it seen, outcome still unknown
malyutka mandate                     Mandates and mandate-log health
malyutka mandate --grant --tools:shell --max-effect:B2 --actions:N --ttl:SEC --goal:TEXT
malyutka mandate --approve:ID [--digest:CRC] | --revoke:ID | --resume:ID
```

| Option | Meaning |
|---|---|
| `--provider:mock\|openai\|ollama\|vllm` | provider adapter; all but `mock` speak the OpenAI-compatible chat API |
| `--model:NAME` | model identifier |
| `--base-url:URL` | e.g. `http://127.0.0.1:11434` (Ollama) or `http://127.0.0.1:8000` (vLLM) |
| `--api-key:KEY` | prefer the `MALYUTKA_API_KEY` environment variable |
| `--allow-shell` | enable the **sandboxed** shell capability |
| `--web` | enable `web_fetch` (http/https page text) and, when a backend is configured, `web_search` (SearXNG, Brave or Tavily; **every call asks**, except a `trust: allow` SearXNG on loopback; URLs with credentials, private/metadata addresses and denylisted domains are denied outright). Runs through the sandboxed `malyutka_web` helper, so it needs `nimble build` to have produced both binaries and libssl installed; `<state>/web.json` holds the denylist, options and the search backend ([SPEC-011](spec/SPEC-011-web-access.md)) |
| `--web-backend:NAME` | search backend `searxng`, `brave` or `tavily`, overriding `search.backend` in `web.json` (no fallback to another) |
| `--skills` | enable `skills_list` / `skill_view` / `skill_save` over `<state>/skills/<name>/SKILL.md` (notes, never code; `skill_save` always asks; [SPEC-009](spec/SPEC-009-skills.md)) |
| `--mcp` | connect the MCP stdio servers in `<state>/mcp.json` (strict file; servers sandboxed by default, per-server ceiling B0-B2, **every call asks**; `sandbox:false` needs `--unconfined-host`; [SPEC-010](spec/SPEC-010-mcp-client.md)) |
| `--allow-process` | enable the background `process` tool (`start`/`poll`/`log`/`kill`/`list`, sandboxed, max `--max-processes:N` = 4; everything is killed when the run ends; [SPEC-008](spec/SPEC-008-processes-and-limits.md)) |
| `--cgroups:auto\|require\|off` | memory/task limits for sandboxed commands via a transient `systemd-run --user --scope` (default `auto`: applied if the probe passes, otherwise visibly skipped; `require` refuses the run; `--limit-memory:MB` default 2048, `--limit-pids:N` default 512, `0` = none) |
| `--context-window:N` | model context size in tokens (default 32768, 0 = off); above 75 % the oldest turns are summarised and archived ([SPEC-006](spec/SPEC-006-context-compaction.md)). `--compress` compacts the resumed history once before the first call |
| `--resume:ID\|last` | continue a saved session: its transcript becomes the history, `--resume-despite-unknown` overrides the refusal when its lineage has unresolved actions ([SPEC-003](spec/SPEC-003-sessions-resume.md)) |
| `--allow-memory` | enable the `memory` tool and inject `<state>/memory.md` (fenced, untrusted) into the system prompt ([SPEC-004](spec/SPEC-004-memory-personality.md)) |
| `--soul:PATH` | operator persona file (default `<state>/SOUL.md`); `--personality:concise\|teacher\|kawaii\|terse-ops` selects a preset |
| `--allow-files` | enable `read_file`, `search_files`, `write_file`, `patch`, `todo` (workspace only; see [SPEC-001](spec/SPEC-001-file-tools.md)) |
| `--approvals:deny\|stdin\|tty\|off` | who answers an ASK: nobody (default, fail closed), a JSONL control channel on stdin, the terminal, or everyone (needs `--i-know-approvals-off`; hardline denials still apply). See [SPEC-002](spec/SPEC-002-approvals.md) |
| `--approval-timeout:SEC` | an unanswered ASK becomes DENY after SEC (default 300) |
| `--unconfined-host` | **waiver**: run the shell on the host, unsandboxed (logged as `confinement.waived`) |
| `--shell-timeout:SEC` | per-command wall clock (default 30) |
| `--max-steps:N` | guidance-loop budget (default 16) |
| `--repeat-limit:N` | halt after N identical consecutive tool calls (default 3; 0 = off) |
| `--request-timeout:SEC` | provider request timeout (default 300) |
| `--theme:warsaw\|nato\|plain` | console theme: green phosphor, amber, or no colour |
| `--json` | canonical JSONL events on stdout (for replay and metrics) |
| `--config:PATH` | JSON config file (see `config.example.json`) |
| `--ask-from:B0..B4` | approval layer: effects at or above this class ASK (off by default) |
| `--mandates` | latched mandates may resolve ASKs; adds the `propose_mandate` tool |
| `--scope-miss-limit:N` | uncovered ASKs in a row that suspend the latch (default 3; 0 = off) |

**Environment:** `MALYUTKA_PROVIDER`, `MALYUTKA_MODEL`, `MALYUTKA_BASE_URL`,
`MALYUTKA_API_KEY`, and `MALYUTKA_STATE_DIR` (journal and sessions; default
`~/.local/state/malyutka`, and it must not overlap the workspace).

**Exit codes:**

| Code | Meaning |
|---|---|
| 0 | answered |
| 1 | failure (e.g. provider error) |
| 2 | usage |
| 3 | confinement unavailable: sandbox missing or blocked, or an unsafe workspace such as `$HOME` |
| 4 | halted: `maxSteps` or repetition |
| 5 | journal unavailable, misplaced or corrupt (`run`); unknown outcomes pending (`journal`) |
| 6 | journal corrupt (`journal`) |
| 7 | mandate log unavailable, misplaced or corrupt |

### Examples

```sh
# vLLM or any OpenAI-compatible server
export MALYUTKA_API_KEY=...
./malyutka run --provider:vllm --base-url:http://127.0.0.1:8000 --model:my-model 'task'

# Machine-readable trace for replay and metrics
./malyutka run --json --provider:ollama --model:qwen3.5:latest 'task' > trace.jsonl

# Configuration file
cp config.example.json my.json && ./malyutka run --config:my.json 'task'
```

Every event carries a run-scoped, monotone ID (`9M14-xxxxxxxx-NNNN`).
Decisions and results carry `causedBy` links, so every side effect can be
traced to the proposal and the decision that allowed it.

---

## Architecture

![Authority pipeline](docs/diagrams/01_authority_pipeline.svg)

Four separate questions are answered by four separate components. No single
gate confers authority.

| Question | Answered by |
|---|---|
| Does this capability exist? | the **registry**, built from configuration |
| How bad could this call be? | the capability's **realm** and effect class B0–B4 |
| Is the intent durable? | the **write-ahead journal** |
| May it run? | the **policy kernel**: `DENY < ASK < ALLOW`, effect ≤ ceiling, every decision names its policy |
| Where does it run? | the **sandbox broker** |

The effect of a sandboxed shell command is classified **B2** (broad workspace
mutation) because the sandbox makes B3 and B4 *unreachable*, not because a
parser inspected the command. Command classification can refine a decision
between ALLOW and ASK. It is never what prevents escalation.

Every proposed tool call receives exactly one terminal reply: a result,
DENIED, or CANCELLED. Strict OpenAI-compatible servers reject anything else,
and a 2000-script fuzzer checks the state machine.

See **[ARCHITECTURE.md](ARCHITECTURE.md)** for the full design, the invariant
table, and each correction made along the way.

---

## The sandbox

![Sandbox view](docs/diagrams/02_sandbox_view.svg)

**Mounts.** A model-issued command runs in bubblewrap with an **empty tmpfs
root** and only these mounted:

- `/usr /etc /opt /bin /sbin /lib*`, read-only;
- private `/tmp`, `/dev`, `/proc`;
- the workspace, read-write.

**Isolation.**

- **Workspace bound by fd.** The workspace is bound from a file descriptor
  that was opened and validated, so a symlink swapped in after the check
  cannot redirect the mount.
- **No network:** all namespaces are unshared.
- **No host sockets:** `/run` and `/home` are absent, so `docker.sock`, D-Bus
  and agent sockets are unreachable.
- **No inherited fds:** `close_range` runs between fork and exec, and stdin
  is `/dev/null`.
- **No secrets in the environment:** only `PATH`, `HOME`, `LANG` and `TERM`
  pass through.

![Process lifetime](docs/diagrams/03_process_lifetime.svg)

**Lifetime.** bwrap is a direct child of the harness with
`--die-with-parent`, inside its own PID namespace. Nothing the model starts,
including deliberately detached processes, outlives the command, its timeout,
or the harness itself. This holds even if the harness is SIGKILLed; that case
is tested.

---

## The journal

![Journal states](docs/diagrams/04_journal_states.svg)

Every side-effecting action is journaled **before** it runs:

```
intent → decision → started → (execute) → outcome
```

Each record is `fdatasync`ed before the next step proceeds. If a record cannot
be made durable, the action does not run. If Malyutka dies mid-action, the
action is **UNKNOWN_OUTCOME**. It is surfaced on every later run and **never
re-executed**, until you establish what happened:

```sh
./malyutka journal                                  # health + pending actions
./malyutka journal --reconcile:9M14-… --as:failed   # you established the outcome
./malyutka journal --ack:9M14-…                     # seen; still unknown
```

**Liveness.** Each run holds a lock that the kernel releases when the process
dies, even on SIGKILL.
- An action whose run is still alive is IN_PROGRESS.
- If its owner's status cannot be established it is OWNER_STATUS_UNKNOWN,
  never assumed dead.
- Neither can be acknowledged or reconciled.

![Strict decoding](docs/diagrams/05_journal_integrity.svg)

**Integrity.** Reading the journal is strict: a record counts only if its
schema, CRC-32, per-writer sequence number and per-action state transition
are all valid.
- A line that does not parse is a *torn* write from a crash. That is benign:
  the step it guarded never proceeded.
- A record that parses but fails a check is **corruption**. Runs are refused
  until you inspect it.

**Location.** The journal lives outside every workspace, where the sandbox
cannot see it, so the agent cannot rewrite its own record.

---

## The commitment latch

Per-call approvals do not survive unattended work: operators either watch the
terminal or switch approvals off. A **mandate** is one operator approval that
resolves a bounded class of later ASKs: a set of tool names, an effect ceiling,
an action budget and a TTL.

```sh
# Shell commands now need approval...
./malyutka run --allow-shell --ask-from:B2 --mandates 'task'     # each shell call: DENIED (ASK unanswered)

# ...granted once, for 20 actions over the next hour:
./malyutka mandate --grant --tools:shell --max-effect:B2 --actions:20 --ttl:3600 \
  --goal:'tidy the build directory'
./malyutka run --allow-shell --ask-from:B2 --mandates 'task'     # POL [ALLOW] mandate:M-…
```

- **Content vs timing.** The model may draft a mandate (`propose_mandate`);
  only the operator can latch it (`--approve`, bound to the digest of the
  exact scope reviewed).
- **Only ASK.** A mandate turns ASK into ALLOW and nothing else. It never
  sees a DENY, and never lifts an action above its capability's ceiling.
- **Protected.** The mandate log lives in the state directory, outside every
  workspace. It is append-only, CRC-checked and hash-chained; a corrupt log
  refuses runs (exit 7).
- **Fast close.** Revoking never needs approval and takes effect before the
  next decision. A streak of calls outside every latched mandate suspends
  it; only the operator can resume. TTL and budget only run down.
- **Attributed.** Every action a mandate allowed names it in the journal's
  decision record and in the mandate log.

The design borrows its structure from a fly navigation circuit (Lanz et al.,
*Nature* 2026, [doi:10.1038/s41586-026-11144-9](https://doi.org/10.1038/s41586-026-11144-9)),
in which inhibition gates when a tracked heading is latched into a recurrent
goal memory. That is design rationale, not a claim of biological fidelity.
See [ARCHITECTURE.md](ARCHITECTURE.md#commitment-latch).

---

## Security model and limits

The claims, and what falsifies them, are in **[SECURITY.md](SECURITY.md)**.
In short, Malyutka limits what an instruction the model was tricked into
following *can do*; it does not try to detect prompt injection. Known limits,
stated rather than hidden:

- **`--unconfined-host` is a waiver**, not a mode: full user authority.
  Processes that deliberately leave the process group can outlive their
  command (cgroups: M3).
- **CRC-32 detects accident and casual tampering**, not an adversary running
  as your uid.
- **Workspace contents are visible to the model**, and so to the provider.
  `/etc` is readable.
- **A released lock proves the Malyutka process ended**, not that an action's
  external effects stopped. This is exactly why interrupted actions are
  UNKNOWN_OUTCOME.

---

## Testing and certification

![Verification stack](docs/diagrams/06_verification.svg)

```sh
nimble test                          # unit, invariant and adversarial suites
tests/integration.sh ./malyutka      # CLI: strict provider, SIGKILL, journal tamper, races
```

- **`tests/test_invariants.nim`** names its tests after the architectural
  invariants they pin (I1–I11), plus the journal suites (J, S, L).
- **`tests/test_adversarial.nim`** is a set of escape attempts: reading
  `~/.ssh`, connecting to host sockets, symlink and hard-link tricks,
  inherited fds, swapping the workspace path after the check, and surviving
  timeouts or the harness's death.
- **`tests/integration.sh`** drives the real CLI. A strict fake provider
  rejects protocol violations the way vLLM does, the harness is SIGKILLed
  mid-command, the journal is tampered with, and six operators race to
  reconcile one action.

**Mutation testing.** Each defense was removed in turn to confirm that its
test fails. The few mutants that survive are documented in `ARCHITECTURE.md`
with the reason.

**M1.2 certification** runs on the target host, as an ordinary user:

```sh
M12_MODEL=qwen3.5:27b tests/m12-certify.sh
```

It checks the native build and suites, the sandbox under the host's real
AppArmor configuration, live tool-call round trips, a model-issued escape
attempt, and SIGKILL plus restart of a live run. The result is a dated report
in which each check is **PASS**, **FAIL**, **NOT RUN** (a gate that wasn't
exercised) or **GAP** (live coverage missing, with offline evidence applying).

`tests/m12-selftest.sh` tests the certifier itself against a stand-in model
across eight scenarios with known verdicts.

---

## Compiler support

| Nim | How tested |
|---|---|
| 1.6.14 | full build and all suites, locally (root and unprivileged) and in CI |
| 2.2.x | CI: native build, sandbox probe, all suites and CLI integration pass; also a semantic `nim check` with zero diagnostics |

Malyutka deliberately avoids `std/random` and `std/oids` in its own code.
Nim-version notes are in `ARCHITECTURE.md`.

---

## Repository layout

```
src/malyutka.nim            CLI
src/malyutka/
  core.nim                  guidance loop, transcript validator
  provider.nim              provider ABI, scripted mock, OpenAI-compatible adapter
  tools.nim                 capability registry (realm, effect ceiling, schema)
  policy.nim                policy kernel (monotonic layer composition)
  sandbox.nim               bubblewrap broker, fd-pinned workspace, bounded spawn
  journal.nim               write-ahead journal, strict decoder, liveness
  latch.nim                 commitment latch: mandate log, scopes, budgets
  events.nim                canonical JSONL events + themed console view
  session.nim, config.nim, types.nim
tests/                      suites, fake providers, certification scripts
tools/release.sh            source release builder (refuses binaries)
docs/diagrams/              .dot sources + rendered .svg/.png (render.sh)
ARCHITECTURE.md             design, invariants, corrections
SECURITY.md                 claims, limits, reporting
CHANGELOG.md                every release, every audit finding
```

---

## Roadmap

![Roadmap](docs/diagrams/07_roadmap.svg)

| Milestone | Scope |
|---|---|
| **M1 / M1.1** ✓ | guidance loop, OpenAI-compatible providers, confined shell, journal |
| **M1.2** ✓ | integration certification on a real host ([record](docs/certification/M1.2-calisota-20261007.md)); open: 24.04 + AppArmor restriction |
| **M2** ✓ | Linux capability layer: files, search, patch, `todo`, ASK approvals (0.4.0), commitment latch, background processes (0.7.0), **MCP client (0.8.0)** |
| M3 (partial) | isolation, deepened: **memory/task limits via a systemd user scope, background processes ✓ (0.7.0)**; per-capability scopes, seccomp, credential broker still open |
| M4 (partial) | ledger: **resumable runs ✓ (0.5.0, transcript-level, never replays effects)**; content-addressed artifacts and replay still open |
| **M5** ✓ | context: token estimate, compaction, ranked session search (0.6.0); **skills (0.8.0)** |
| M6 | delegation: isolated children with `capabilities(child) ⊆ capabilities(parent)` and budgets |
| M7 | metacritic: replace `maxSteps` with an EVoC/hysteresis controller (PRODUCTIVE → SUSPECT → PLATEAU; CONTINUE / REDIRECT / DELEGATE / COMPACT / HALT) |
| M8 | harness laboratory: interchangeable controllers and models, useful work per token and per GPU-hour |

The guiding rule: **autonomy follows isolation**. No milestone may make an
invariant non-vacuous without making it *enforced*.

---

## Contributing

Issues and pull requests are welcome. The most valuable contribution is a
**failing test**: a scenario in which a documented claim does not hold.

- Security-relevant findings go through private vulnerability reporting
  (see [SECURITY.md](SECURITY.md)).
- New defenses need a test, and the test needs a mutant that fails it.
- Keep the kernel small; add capabilities only behind the existing gates.
- Run `nimble test`, `tests/integration.sh ./malyutka` and
  `shellcheck -S warning tests/*.sh tools/*.sh` before submitting.

---

## Name

*Malyutka* ("little one") and the 9M14 designation are project branding and
visual identity: the green-phosphor and amber terminal themes, and an
engineering ethos of simplicity, robustness and low deployment cost. They
carry no other meaning. No affiliation with any manufacturer, government or
military organization is implied.

## License

[MIT](LICENSE) © 2026 Malyutka contributors
