## Seeded, counter-based treatment assignment (SPEC-012).
##
## Every draw is a pure function of (study seed, episode id, decision-point
## index k):
##
##   x = mix(seed, episode, k)            64 bits, logged as hex
##   u = (x >> 11) * 2^-53                uniform on [0, 1)
##   arm = REDIRECT iff u < q             q = P(REDIRECT), 0 < q < 1
##
## Nothing is carried from one draw to the next, so a crash, a resume or an
## ineligible step cannot shift a later assignment, and any logged assignment
## can be re-derived and audited from the log alone (invariant E1).
##
## The mixer is SplitMix64 over an FNV-1a hash of the episode id. It is not
## cryptographic and does not need to be: the seed is fixed before the study
## and the agent never sees it. Changing this function makes every existing
## log fail replay, which is the point; the golden vectors in
## tests/test_experiment.nim pin it.
##
## Not std/random (see ARCHITECTURE.md, "Implementation notes").

import std/sysrand

type
  Arm* = enum
    armContinue = "CONTINUE"   ## control: the agent loop is left alone
    armRedirect = "REDIRECT"   ## treatment: the versioned intervention is delivered

  Assignment* = object
    k*: int          ## decision-point index within the episode, 0-based
    q*: float        ## P(REDIRECT) at this point
    x*: uint64       ## raw mixer output
    u*: float        ## uniform draw derived from x
    arm*: Arm
    p*: float        ## probability of the arm actually assigned (q or 1 - q)

  RandomizerError* = object of CatchableError

proc splitmix64(x: uint64): uint64 =
  var z = x + 0x9E3779B97F4A7C15'u64
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc fnv1a64(s: string): uint64 =
  result = 0xCBF29CE484222325'u64
  for ch in s:
    result = (result xor uint64(ord(ch))) * 0x00000100000001B3'u64

proc mix*(seed: uint64; episode: string; k: int): uint64 =
  if k < 0: raise newException(RandomizerError, "decision-point index must be >= 0, got " & $k)
  let key = splitmix64(seed xor splitmix64(fnv1a64(episode)))
  splitmix64(key xor splitmix64(uint64(k) + 1'u64))

proc toUnit*(x: uint64): float =
  float(x shr 11) * (1.0 / 9007199254740992.0)   # 2^53

proc validQ*(q: float): bool =
  ## Positivity: both arms must stay possible at every eligible point.
  q > 0.0 and q < 1.0   # false for NaN

proc assign*(seed: uint64; episode: string; k: int; q: float): Assignment =
  if not validQ(q):
    raise newException(RandomizerError, "q must satisfy 0 < q < 1, got " & $q)
  let x = mix(seed, episode, k)
  let u = toUnit(x)
  let arm = if u < q: armRedirect else: armContinue
  Assignment(k: k, q: q, x: x, u: u, arm: arm, p: (if arm == armRedirect: q else: 1.0 - q))

# ---- seeds: logged as 16 hex digits (JSON integers are signed 64-bit) -------

proc seedHex*(seed: uint64): string =
  const digits = "0123456789abcdef"
  result = newString(16)
  var v = seed
  for i in countdown(15, 0):
    result[i] = digits[int(v and 0xF'u64)]
    v = v shr 4

proc parseSeed*(s: string): uint64 =
  if s.len != 16:
    raise newException(RandomizerError, "seed must be 16 hex digits, got '" & s & "'")
  for ch in s:
    let d = case ch
      of '0'..'9': ord(ch) - ord('0')
      of 'a'..'f': ord(ch) - ord('a') + 10
      else: raise newException(RandomizerError, "seed must be 16 lowercase hex digits, got '" & s & "'")
    result = (result shl 4) or uint64(d)

proc newSeed*(): uint64 =
  ## Fresh study seed from the OS CSPRNG. Record it: it is the only thing
  ## needed to re-derive every assignment.
  for b in urandom(8): result = (result shl 8) or uint64(b)

proc parseArm*(s: string): Arm =
  case s
  of "CONTINUE": armContinue
  of "REDIRECT": armRedirect
  else: raise newException(RandomizerError, "unknown arm '" & s & "'")
