# SPEC-012 — Experiment layer (Malyutka-RC-02, part 1)

**Status:** part 1 implemented, pilot design frozen (recorder, randomizer, eligibility, trial coordinator); not yet wired into
the guidance loop. Parts 2–3 (intervention delivery, evaluator, pilot runner) are specified below as
interfaces only.

## Goals

A reproducible causal-experimentation layer for the agent: at well-defined decision points the harness
may randomize a versioned intervention (initially `REDIRECT` versus `CONTINUE`), and every randomized
decision is auditable, every intervention reproducible, and every outcome attributable to a defined
observation window. The first study is a micro-randomized pilot (30–50 episodes) that measures
feasibility and variance, not a controller comparison.

- Assignment probabilities are known and logged at every decision, so effects can be estimated with
  propensity-aware methods (WCLS for causal excursion effects).
- The pre-treatment history of every decision is recorded by reference before the draw.
- The log replays: eligibility and assignment are re-derived from the log alone, and any disagreement
  is corruption.

## Non-goals

- No learned controller, reservoir, or accelerator code. Nothing here depends on Metalium or Blackhole.
- No authority. The layer returns an arm; it never executes a tool, never changes a policy verdict, and
  cannot end a task. The state machine and policy kernel remain authoritative.
- No analysis code in the harness. Estimation happens offline from the log.

## Interface (part 1)

`src/malyutka/experiment/`

| Module | Responsibility |
|---|---|
| `randomizer.nim` | Counter-based draw `u = mix(seed, episode, k)`, `REDIRECT iff u < q`; seeds as 16 hex digits |
| `eligibility.nim` | Pure state: warm-up `k0` turns, symmetric outcome window of `windowLen` tool actions, censoring at episode end |
| `event_recorder.nim` | `exp/1` log writer (journal framing, CRC, per-writer sequence, fdatasync, liveness lock) and strict replay scanner |
| `trial.nim` | One episode, write-ahead order: check → draw → durable point record → open window → return arm |

Design (fixed per study, recorded in every `episode.start`):

| Field | Pilot value (frozen) | Meaning |
|---|---|---|
| `q` | 0.5 | P(REDIRECT) at an eligible point; must satisfy 0 < q < 1 |
| `k0` | 3 | completed agent turns before the first eligible point |
| `windowLen` | 5 | tool attempts per outcome window (matches the "next five tool actions" proximal outcome) |
| `intervention` | `REDIRECT-v1` | versioned intervention id; its text is frozen for the study |

**Frozen for the RC-02 pilot (approved 2026-11-20), before any experimental data is collected.** Also
frozen: denied and cancelled tool attempts count toward the window; the lockout is identical after both
arms; a point whose record is not durable delivers no intervention. These are pilot choices, not
established optima. Changing any of them after data collection starts needs a new design version, and
episodes under different designs are analysed separately.

### Decision points and windows

A decision opportunity is the start of an agent step (before the provider is called). It is eligible iff
at least `k0` turns have completed, the episode is active, and **no outcome window is open**. Every
eligible point is randomized and opens a window, **whatever the arm**; while a window is open no point is
eligible. So a CONTINUE point can never receive a REDIRECT inside its own outcome window. Windows close
after `windowLen` completed tool actions, or censored at episode end.

Recommended wiring (part 2): `turnCompleted` after each provider turn's tool results are in;
`toolAction` once per tool call that reached a terminal result (executed, denied or cancelled), so
the window measures attempts, not just successes; `decide` at `step.start`.

### Log `exp/1`

Default location `<state>/experiment/experiment.jsonl`, outside the workspace (placement checked as for
the journal). One JSON record per line, framed `"\n" & json & "\n"`, each with `w`, `n`, `ts`, `crc`.

| `rec` | Fields | Writer |
|---|---|---|
| `episode.start` | `schema, task, family, seed, design{q,k0,windowLen,intervention}, conditions{}` | episode owner |
| `obs` | `t, kind: turn\|action, data, h` | owner |
| `point` | `eligible, histT, histHead` and either `reason` or `k, arm, q, p, u, x, intervention [, features]` | owner |
| `window.close` | `k, reason: length\|episode-end, actions` | owner |
| `delivery` | `k, delivered, detail` (REDIRECT points only) | owner |
| `outcome` | `name, value [, k]` | any writer (the evaluator) |
| `episode.end` | `reason` | owner |

`h` chains observations, `h_t = crc32(h_{t-1} | kind | data)`, `h_0 = "00000000"`. A point's
`(histT, histHead)` names the pre-treatment prefix, from which any feature can be recomputed offline.
`conditions` carries what the preregistration freezes: model identifier as returned by the provider,
sampling parameters, harness version, tool schemas digest, task-suite version.

The mixer (SplitMix64 over FNV-1a of the episode id) is simple to reimplement; an independent Python
implementation reproduces the golden vectors in the tests, so the analysis side can re-derive every
assignment without the harness.

## Invariants

| # | Invariant |
|---|---|
| E1 | An assignment is a pure function of (seed, episode, k, q); every logged assignment re-derives from the logged seed |
| E2 | No decision point is eligible while any outcome window is open, whatever arm opened it; windows close after exactly `windowLen` tool actions or, censored, at episode end |
| E3 | No arm is returned for delivery unless its point record, with the pre-treatment history reference, is durable; a non-durable log disables the trial for the rest of the episode and never blocks the agent |
| E4 | The experiment log is outside the workspace and strictly decoded: schema, CRC, per-writer sequence and ownership; a parseable record that disagrees with replay (eligibility, history reference, assignment, window boundaries) is corruption |
| E5 | Reference patches are visible only to the evaluator (part 3; vacuous until `evaluator.nim` exists) |

## Failure modes

| Failure | Behaviour |
|---|---|
| Point record not durable | No arm delivered; trial disabled; nothing more written; episode replays as RUNNING then INTERRUPTED |
| Harness crash mid-episode | Episode replays INTERRUPTED (liveness lock); an open window is visibly unclosed, i.e. censored by the crash |
| Torn final line | TORN, prefix intact; the next writer's leading newline terminates the fragment |
| Edited arm, seed, observation, eligibility mark or window boundary (CRC re-sealed) | CORRUPT via replay |
| Edit replay cannot check (e.g. `features`) without re-sealing | CORRUPT via CRC |
| Episode records by a foreign writer | CORRUPT (ownership) |
| `q` outside (0, 1), `windowLen < 1`, `k0 < 0`, empty intervention id | Refused before anything is written |

## Tests and mutants

`tests/test_experiment.nim`: 33 tests, no model or agent loop. 21 mutants were run; 20 are caught.
One survives as equivalent: opening the window before writing the point record. When the write fails
the trial is disabled and never reads its eligibility state again, so the order is unobservable; the
write-ahead order is kept so the state is never ahead of the log.

## Rollout

1. **Part 1 (this change):** the four modules and their tests.
2. **Part 2:** wire `trial.nim` into `core.nim` behind an opt-in flag; `redirect.nim` injects the frozen
   `REDIRECT-v1` text as a harness-labelled message at `step.start` and records `delivery`; neutral
   placebo support with matched delivery mechanics and token burden. The experiment hooks must not
   touch the policy kernel, the journal or the approval path. Requirements carried from review:
   - *Assignment is not delivery.* A crash after the point record is durable but before injection leaves an
     assigned, undelivered point. Record a delivery intent and its result separately, keyed by an
     idempotency key (episode, k); an intent without a result is AMBIGUOUS and is never silently retried.
   - *Early termination is explicit.* A window cut short by success, failure or exit is closed
     `episode-end` with the episode's end reason and the attempts actually seen (part 1 already records
     this); analysis must not pad the window or score missing attempts as failures.
   - *Replay is anchored to the run.* Each `obs` and `point` carries the `events/2` run id and event id it
     came from, so the experiment log can be cross-checked against the run's actual decision opportunities;
     a syntactically valid but incomplete experimental history must be detectable as incomplete.
3. **Part 3:** `evaluator.nim` (reference-diff proximity within the window, independent test outcome; the
   reference patch lives outside the workspace and the agent's tools), task admission checks (environment
   builds, bug reproduces, reference fix passes), pilot runner and summary report (task attrition, eligible
   points per episode, delivery reliability, proximal-outcome prevalence, cost, preliminary estimates).
