## One episode of a randomized experiment (SPEC-012). Ties eligibility, the
## randomizer and the recorder together in write-ahead order:
##
##   check eligibility (pre-treatment state) -> draw -> durable point record
##   -> open the outcome window -> return the arm to the caller
##
## so nothing can be delivered for a point whose record is not durable (E3).
##
## Fail-safe for the agent: if the log stops being durable the trial disables
## itself for the rest of the episode and every later decision returns "not
## randomized" (CONTINUE). An experiment failure never blocks, halts or alters
## the agent loop, and nothing more is written to a log that may be torn, so
## the episode replays as RUNNING/INTERRUPTED, never as a complete episode.
##
## This module holds no authority: it returns an arm. Whether and how an arm
## is delivered is decided by the harness, under its existing policy kernel.

import std/[json, options]
import ./[randomizer, eligibility, event_recorder]

type
  TrialDecision* = object
    randomized*: bool     ## true iff a durable point record assigned an arm
    k*: int               ## point index, when randomized
    arm*: Arm             ## armContinue whenever not randomized
    reason*: Ineligible   ## why not randomized (inNone if randomized or disabled)

  Trial* = ref object
    rec*: Recorder
    episode*: string
    seed*: uint64
    design*: Design
    elig: Eligibility
    failure*: string      ## non-empty once the trial has disabled itself

proc startTrial*(rec: Recorder; episode, task, family: string; seed: uint64;
                 design: Design; conditions: JsonNode = nil): Trial =
  ## Raises ExperimentError if the episode cannot be durably started; the
  ## caller then runs the task without an experiment.
  rec.episodeStart(episode, task, family, seed, design, conditions)
  Trial(rec: rec, episode: episode, seed: seed, design: design,
        elig: initEligibility(design.eligibilityCfg))

proc disabled*(t: Trial): bool = t.failure.len > 0

proc state*(t: Trial): Eligibility = t.elig

proc turnCompleted*(t: Trial; data: JsonNode = nil) =
  if t.disabled: return
  try:
    discard t.rec.observe(t.episode, "turn", data)
    t.elig.onTurnCompleted()
  except ExperimentError as e:
    t.failure = e.msg

proc toolAction*(t: Trial; data: JsonNode = nil) =
  if t.disabled: return
  try:
    discard t.rec.observe(t.episode, "action", data)
    let c = t.elig.onToolAction()
    if c.isSome: t.rec.windowClose(t.episode, c.get)
  except ExperimentError as e:
    t.failure = e.msg

proc decide*(t: Trial; features: JsonNode = nil): TrialDecision =
  ## Call once per decision opportunity (between agent turns). Eligibility is
  ## read before anything is drawn; the point record is durable before the
  ## window opens and before the arm is returned.
  if t.disabled: return TrialDecision(randomized: false, arm: armContinue)
  let why = t.elig.check()
  try:
    if why != inNone:
      t.rec.pointIneligible(t.episode, why)
      return TrialDecision(randomized: false, arm: armContinue, reason: why)
    let a = assign(t.seed, t.episode, t.elig.points, t.design.q)
    t.rec.pointAssigned(t.episode, a, t.design.intervention, features)
    let k = t.elig.openWindow()
    TrialDecision(randomized: true, k: k, arm: a.arm)
  except ExperimentError as e:
    t.failure = e.msg
    TrialDecision(randomized: false, arm: armContinue)

proc recordDelivery*(t: Trial; k: int; delivered: bool; detail = "") =
  if t.disabled: return
  try: t.rec.delivery(t.episode, k, delivered, detail)
  except ExperimentError as e: t.failure = e.msg

proc finish*(t: Trial; reason: string) =
  ## Ends the episode: a still-open window is closed as censored first.
  if t.disabled: return
  try:
    let c = t.elig.endEpisode()
    if c.isSome: t.rec.windowClose(t.episode, c.get)
    t.rec.episodeEnd(t.episode, reason)
  except ExperimentError as e:
    t.failure = e.msg
