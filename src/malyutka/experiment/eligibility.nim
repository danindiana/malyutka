## Decision-point eligibility with a symmetric outcome-window lockout (SPEC-012).
##
## Pure state, no I/O. A decision point is eligible iff
##
##   completed agent turns >= k0  ∧  episode active  ∧  no outcome window open
##
## Every eligible point opens an outcome window of `windowLen` completed tool
## actions, WHATEVER arm it was assigned. The window is the proximal-outcome
## observation period; while it is open no further point is eligible, so a
## CONTINUE-assigned point can never receive a REDIRECT inside its own window
## (invariant E2). Symmetry holds by construction: `openWindow` has no arm
## parameter, so this module cannot treat the arms differently.
##
## A window closes when it has seen `windowLen` tool actions, or, censored,
## when the episode ends first.

import std/options

type
  EligibilityCfg* = object
    k0*: int          ## completed agent turns before the first eligible point
    windowLen*: int   ## completed tool actions per outcome window

  Ineligible* = enum
    inNone = ""                   ## eligible
    inWarmup = "warmup"           ## fewer than k0 completed turns
    inWindowOpen = "window-open"  ## a previous point's outcome window is open
    inEnded = "episode-ended"

  CloseReason* = enum
    crLength = "length"           ## the window saw windowLen tool actions
    crEpisodeEnd = "episode-end"  ## censored: the episode ended first

  WindowClose* = object
    k*: int           ## the decision point whose window closed
    actions*: int     ## tool actions the window saw
    reason*: CloseReason

  Eligibility* = object
    cfg*: EligibilityCfg
    turns*: int       ## completed agent turns
    actions*: int     ## completed tool actions
    points*: int      ## eligible points so far (= index of the next one)
    ended*: bool
    windowOpen*: bool
    windowK*: int
    windowActions*: int

  EligibilityError* = object of CatchableError

proc validCfg*(c: EligibilityCfg): string =
  ## "" when usable, else why not.
  if c.k0 < 0: return "k0 must be >= 0"
  if c.windowLen < 1: return "windowLen must be >= 1"
  ""

proc initEligibility*(cfg: EligibilityCfg): Eligibility =
  let bad = validCfg(cfg)
  if bad.len > 0: raise newException(EligibilityError, bad)
  Eligibility(cfg: cfg)

proc check*(e: Eligibility): Ineligible =
  ## Decided from state as it stands BEFORE any randomization at this point.
  if e.ended: inEnded
  elif e.turns < e.cfg.k0: inWarmup
  elif e.windowOpen: inWindowOpen
  else: inNone

proc eligible*(e: Eligibility): bool = e.check() == inNone

proc openWindow*(e: var Eligibility): int =
  ## Consumes an eligible point and opens its outcome window. Returns the
  ## point's index k. Calling it at an ineligible point is a harness bug.
  let why = e.check()
  if why != inNone:
    raise newException(EligibilityError, "openWindow at an ineligible point (" & $why & ")")
  result = e.points
  inc e.points
  e.windowOpen = true
  e.windowK = result
  e.windowActions = 0

proc onTurnCompleted*(e: var Eligibility) =
  if e.ended: raise newException(EligibilityError, "turn after the episode ended")
  inc e.turns

proc onToolAction*(e: var Eligibility): Option[WindowClose] =
  ## Counts one completed tool action. Returns the window it closed, if any.
  if e.ended: raise newException(EligibilityError, "tool action after the episode ended")
  inc e.actions
  if e.windowOpen:
    inc e.windowActions
    if e.windowActions >= e.cfg.windowLen:
      e.windowOpen = false
      return some(WindowClose(k: e.windowK, actions: e.windowActions, reason: crLength))
  none(WindowClose)

proc endEpisode*(e: var Eligibility): Option[WindowClose] =
  ## Ends the episode. A window still open is closed as censored.
  if e.ended: raise newException(EligibilityError, "episode ended twice")
  e.ended = true
  if e.windowOpen:
    e.windowOpen = false
    return some(WindowClose(k: e.windowK, actions: e.windowActions, reason: crEpisodeEnd))
  none(WindowClose)
