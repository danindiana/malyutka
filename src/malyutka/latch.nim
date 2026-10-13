## Commitment latch: scoped, durable operator mandates.
##
## Per-call ASK approvals do not scale to unattended work: operators either
## sit at the terminal or switch approvals off. A mandate is one operator
## approval that resolves a bounded class of future ASKs:
##
##   scope  = {tool names} x {effect <= maxEffect}
##   budget = maxActions uses, within ttlSec of approval
##
## Design rationale (not a claim of biological fidelity): Lanz et al., Nature
## 2026, "A split attractor design for rapidly writing a navigational goal".
## Their circuit separates *content* (PFG neurons track heading) from *timing*
## (inhibition of hΔK gates when the heading is latched as a goal), keeps the
## latched state dominant over ongoing input, and closes the latch fast when
## the animal turns away. Mapped onto the harness:
##
## * Content vs timing. Anyone may PROPOSE a mandate, including the model
##   (the `propose_mandate` tool). Only the operator path can APPROVE one.
## * Protected state. The mandate log lives in the state directory, disjoint
##   from the workspace (same placement rule as the journal), so nothing the
##   sandboxed model does can edit scope or budget.
## * Asymmetry. Latching needs an operator approval bound to a digest of the
##   exact scope. Suspending and revoking need nothing and take effect before
##   the next policy decision.
## * Deviation drops the latch. A streak of ASKs no mandate covers, while a
##   mandate is latched, suspends it (see core.nim). The M7 metacritic is the
##   intended successor of this rule.
## * Graded expiry. TTL and action budget run down; they are never refreshed.
##
## The hard boundary: a mandate can only turn ASK into ALLOW. It never sees a
## DENY, and an ASK only exists below the capability's effect ceiling
## (policy.compose denies above it first).
##
## Log format: append-only JSONL, one record per line, framed "\n"&json&"\n"
## like the journal. Every record carries `n` (1, 2, 3, ... in file order),
## `prev` (CRC of the previous valid record; "" for the first), `t` (epoch
## seconds) and `crc` (CRC-32 of the record without `crc`). Every write is a
## read-validate-append transaction under one exclusive flock, so the state a
## decision sees is the state its record applies to. A line that does not
## parse is TORN (benign: the write never completed). Anything parseable that
## fails schema, checksum, sequence, chain or transition checks is CORRUPT,
## and corruption fails closed: no mandate is honoured and runs that ask for
## mandates are refused. As with the journal, CRC detects accidents and
## casual tampering, not an adversary with the operator's uid.

import std/[json, os, posix, strutils, sysrand, times]
import ./[types, journal]   # journal: crc32, shared with the action journal

proc c_flock(fd: cint; op: cint): cint {.importc: "flock", header: "<sys/file.h>".}
var lO_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
const LOCK_EX = 2.cint
const LOCK_UN = 8.cint

const
  MaxMandateActions* = 10_000
  MaxMandateTtlSec* = 7 * 24 * 3600

type
  LatchError* = object of CatchableError

  MandateState* = enum
    msProposed = "PROPOSED"      ## drafted; authorizes nothing
    msLatched = "LATCHED"        ## approved, in TTL, budget left
    msSuspended = "SUSPENDED"    ## deviation detected; authorizes nothing
    msRevoked = "REVOKED"        ## terminal
    msExpired = "EXPIRED"        ## derived: TTL ran out (terminal)
    msExhausted = "EXHAUSTED"    ## derived: action budget used up (terminal)

  Mandate* = object
    id*: string
    goal*: string
    tools*: seq[string]
    maxEffect*: EffectClass
    maxActions*: int
    ttlSec*: int
    proposedBy*: string
    approvedBy*: string
    digest*: string            ## CRC over scope+budget, fixed at proposal
    approvedAt*: float         ## epoch seconds; 0 until approved
    expiresAt*: float
    used*: int
    recorded*: MandateState    ## state from records alone (no clock)
    reason*: string            ## last suspend/revoke reason

  LatchHealth* = enum lhOk = "OK", lhTorn = "TORN_TAIL", lhCorrupt = "CORRUPT"

  LatchScan* = object
    mandates*: seq[Mandate]
    health*: LatchHealth
    problems*: seq[string]
    tornLines*: seq[int]
    count: int                 ## valid records
    lastCrc: string

  Clock* = proc(): float {.closure.}

  LatchStore* = ref object
    path*: string
    clock*: Clock
    failAppend*: bool          ## test hook: refuse every append

  UseResult* = object
    mandate*: string           ## "" if no mandate covered the call
    anyLatched*: bool          ## a mandate was latched (for deviation detection)
    goal*: string
    used*, maxActions*: int
    error*: string             ## covered, but the use record was not durable

proc systemClock(): float = epochTime()

proc defaultLatchPath*(stateDir: string): string = stateDir / "mandates.jsonl"

proc newLatchStore*(path: string; clock: Clock = systemClock): LatchStore =
  LatchStore(path: path, clock: clock)

proc newMandateId*(): string =
  var hex = ""
  for b in urandom(4): hex.add toHex(BiggestInt(b), 2).toLowerAscii
  "M-" & hex

# ---- scope ---------------------------------------------------------------------

proc scopeJson*(goal: string; tools: seq[string]; maxEffect: EffectClass;
                maxActions, ttlSec: int): JsonNode =
  var ts = newJArray()
  for t in tools: ts.add %t
  %*{"goal": goal, "tools": ts, "maxEffect": $maxEffect,
     "maxActions": maxActions, "ttlSec": ttlSec}

proc digestOf*(scope: JsonNode): string = crc32($scope)

proc parseEffect*(s: string): EffectClass =
  for e in EffectClass:
    if $e == s.toUpperAscii: return e
  raise newException(ValueError, "unknown effect class: " & s & " (expected B0..B4)")

proc scopeProblem*(scope: JsonNode): string =
  ## "" if `scope` is a well-formed mandate scope.
  if scope.kind != JObject: return "scope is not an object"
  for k in ["goal", "tools", "maxEffect", "maxActions", "ttlSec"]:
    if not scope.hasKey(k): return "scope." & k & " missing"
  if scope["goal"].kind != JString or scope["goal"].getStr.strip.len == 0:
    return "scope.goal must be a non-empty string"
  if scope["tools"].kind != JArray or scope["tools"].len == 0:
    return "scope.tools must be a non-empty array"
  for t in scope["tools"]:
    if t.kind != JString or t.getStr.len == 0: return "scope.tools entries must be names"
    if t.getStr in ["*", "propose_mandate"]:
      return "scope.tools may not contain '" & t.getStr & "'"
  if scope["maxEffect"].kind != JString: return "scope.maxEffect mistyped"
  try: discard parseEffect(scope["maxEffect"].getStr)
  except ValueError as e: return e.msg
  if scope["maxActions"].kind != JInt or scope["maxActions"].getInt notin 1 .. MaxMandateActions:
    return "scope.maxActions must be 1.." & $MaxMandateActions
  if scope["ttlSec"].kind != JInt or scope["ttlSec"].getInt notin 1 .. MaxMandateTtlSec:
    return "scope.ttlSec must be 1.." & $MaxMandateTtlSec
  ""

proc effectiveState*(m: Mandate; now: float): MandateState =
  ## The state at time `now`. Expiry and exhaustion are derived, never
  ## recorded, so they cannot be undone by editing anything.
  if m.recorded in {msLatched, msSuspended}:
    if m.used >= m.maxActions: return msExhausted
    if now > m.expiresAt: return msExpired
  m.recorded

proc covers*(m: Mandate; tool: string; effect: EffectClass): bool =
  tool in m.tools and effect <= m.maxEffect

# ---- strict decoding -------------------------------------------------------------

const KnownRecs = ["propose", "approve", "use", "suspend", "resume", "revoke"]

proc recordProblem(r: JsonNode): string =
  template need(k: string; kinds: set[JsonNodeKind]) =
    if not r.hasKey(k) or r[k].kind notin kinds: return "field '" & k & "' missing or mistyped"
  need("rec", {JString}); need("mandate", {JString}); need("n", {JInt})
  need("prev", {JString}); need("t", {JFloat, JInt}); need("crc", {JString})
  need("by", {JString})
  let rec = r["rec"].getStr
  if rec notin KnownRecs: return "unknown record type '" & rec & "'"
  if r["mandate"].getStr.len == 0: return "empty mandate id"
  if r["by"].getStr.len == 0: return "empty 'by'"
  case rec
  of "propose":
    need("scope", {JObject}); need("digest", {JString})
    let sp = scopeProblem(r["scope"])
    if sp.len > 0: return sp
  of "approve": need("digest", {JString})
  of "use": need("run", {JString}); need("action", {JString})
  of "suspend", "revoke": need("reason", {JString})
  else: discard
  ""

proc scanLatchContent*(content: string): LatchScan =
  var byId: seq[Mandate]
  proc find(ms: seq[Mandate]; id: string): int =
    for i, m in ms:
      if m.id == id: return i
    -1
  var lineNo = 0
  for line in content.splitLines:
    inc lineNo
    if line.strip.len == 0: continue
    var r: JsonNode
    try: r = parseJson(line)
    except JsonParsingError, ValueError:
      result.tornLines.add lineNo
      continue
    template bad(msg: string) =
      result.problems.add "line " & $lineNo & ": " & msg
      continue
    if r.kind != JObject: bad("not a JSON object")
    let sp = recordProblem(r)
    if sp.len > 0: bad(sp)
    var body = r.copy
    body.delete("crc")
    let crc = r["crc"].getStr
    if crc32($body) != crc: bad("checksum mismatch")
    if r["n"].getInt != result.count + 1:
      bad("sequence " & $r["n"].getInt & ", expected " & $(result.count + 1) &
          " (record missing, duplicated or reordered)")
    if r["prev"].getStr != result.lastCrc:
      bad("chain broken: prev " & r["prev"].getStr & ", expected '" & result.lastCrc & "'")
    let id = r["mandate"].getStr
    let rec = r["rec"].getStr
    let t = r["t"].getFloat
    let k = byId.find(id)
    if rec == "propose":
      if k >= 0: bad("mandate " & id & ": second propose")
      let s = r["scope"]
      if digestOf(s) != r["digest"].getStr: bad("mandate " & id & ": digest does not match scope")
      var m = Mandate(id: id, goal: s["goal"].getStr, maxEffect: parseEffect(s["maxEffect"].getStr),
        maxActions: s["maxActions"].getInt, ttlSec: s["ttlSec"].getInt,
        proposedBy: r["by"].getStr, digest: r["digest"].getStr, recorded: msProposed)
      for x in s["tools"]: m.tools.add x.getStr
      byId.add m
    else:
      if k < 0: bad("mandate " & id & ": '" & rec & "' before its propose")
      var m = byId[k]
      case rec
      of "approve":
        if m.recorded != msProposed: bad("mandate " & id & ": approve from " & $m.recorded)
        if r["digest"].getStr != m.digest:
          bad("mandate " & id & ": approval digest does not match the proposal")
        if r["by"].getStr.startsWith("model:"):
          bad("mandate " & id & ": approval by the model")
        m.recorded = msLatched
        m.approvedBy = r["by"].getStr
        m.approvedAt = t
        m.expiresAt = t + float(m.ttlSec)
      of "use":
        # A use is valid only if the mandate was LATCHED at the time recorded.
        if m.effectiveState(t) != msLatched:
          bad("mandate " & id & ": use while " & $m.effectiveState(t))
        inc m.used
      of "suspend":
        if m.recorded != msLatched: bad("mandate " & id & ": suspend from " & $m.recorded)
        m.recorded = msSuspended
        m.reason = r["reason"].getStr
      of "resume":
        if m.recorded != msSuspended: bad("mandate " & id & ": resume from " & $m.recorded)
        if r["by"].getStr.startsWith("model:"): bad("mandate " & id & ": resume by the model")
        m.recorded = msLatched
      of "revoke":
        if m.recorded notin {msProposed, msLatched, msSuspended}:
          bad("mandate " & id & ": revoke from " & $m.recorded)
        m.recorded = msRevoked
        m.reason = r["reason"].getStr
      else: discard
      byId[k] = m
    inc result.count
    result.lastCrc = crc
  result.mandates = byId
  result.health =
    if result.problems.len > 0: lhCorrupt
    elif result.tornLines.len > 0: lhTorn
    else: lhOk

# ---- file access -------------------------------------------------------------------

proc checkLatchPlacement*(path, workspace: string) =
  ## Same rule as the journal: the mandate log's directory and the workspace
  ## must be disjoint after resolving symlinks (invariant L3).
  let dir = parentDir(path)
  var d: string
  try:
    createDir(dir)
    d = expandFilename(dir)
  except OSError as e:
    raise newException(LatchError, "cannot use mandate directory '" & dir & "': " & e.msg)
  var ws: string
  try: ws = expandFilename(workspace)
  except OSError: return
  if d == ws or d.isRelativeTo(ws) or ws.isRelativeTo(d):
    raise newException(LatchError, "mandate log directory '" & d &
      "' overlaps the workspace '" & ws & "': the agent could rewrite its own mandates")

proc openLog(path: string; write: bool): cint =
  let flags = (if write: O_RDWR or O_APPEND or O_CREAT else: O_RDONLY) or O_CLOEXEC or lO_NOFOLLOW
  result = posix.open(cstring(path), flags, 0o600)
  if result < 0:
    if not write and errno == ENOENT: return -1
    raise newException(LatchError, "cannot open mandate log " & path & ": " & $strerror(errno) &
      (if errno == ELOOP: " (path is a symlink)" else: ""))
  var st: Stat
  if fstat(result, st) != 0 or not S_ISREG(st.st_mode) or st.st_uid != getuid():
    discard posix.close(result)
    raise newException(LatchError, "refusing mandate log " & path &
      ": not a regular file owned by uid " & $getuid())

proc readAll(fd: cint): string =
  if lseek(fd, 0, SEEK_SET) < 0:
    raise newException(LatchError, "mandate log seek failed: " & $strerror(errno))
  var buf: array[65536, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      raise newException(LatchError, "mandate log read failed: " & $strerror(errno))
    if n == 0: break
    for i in 0 ..< n: result.add buf[i]

proc writeAll(fd: cint; data: string) =
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n < 0:
      if errno == EINTR: continue
      raise newException(LatchError, "mandate log write failed: " & $strerror(errno))
    off += n

proc scan*(s: LatchStore): LatchScan =
  let fd = openLog(s.path, write = false)
  if fd < 0: return scanLatchContent("")
  defer: discard posix.close(fd)
  if c_flock(fd, LOCK_EX) != 0:
    raise newException(LatchError, "mandate log lock failed: " & $strerror(errno))
  defer: discard c_flock(fd, LOCK_UN)
  scanLatchContent(readAll(fd))

proc transact*(s: LatchStore;
               decide: proc(scan: LatchScan; now: float): seq[JsonNode]): seq[JsonNode] =
  ## Read, validate and append under ONE exclusive lock. `decide` returns the
  ## records to append (possibly none). A corrupt log refuses every write.
  ## Returns the appended records, each durable (fdatasync) before return.
  createDir(parentDir(s.path))
  let fd = openLog(s.path, write = true)
  defer: discard posix.close(fd)
  if c_flock(fd, LOCK_EX) != 0:
    raise newException(LatchError, "mandate log lock failed: " & $strerror(errno))
  defer: discard c_flock(fd, LOCK_UN)
  var sc = scanLatchContent(readAll(fd))
  if sc.health == lhCorrupt:
    raise newException(LatchError, "mandate log is corrupt (" & sc.problems.join("; ") &
      "); inspect it with `malyutka mandate`")
  let now = s.clock()
  let recs = decide(sc, now)
  for rec in recs:
    if s.failAppend:
      raise newException(LatchError, "mandate log write refused (test hook)")
    var r = rec.copy
    r["n"] = %(sc.count + 1)
    r["prev"] = %sc.lastCrc
    r["t"] = %now
    r["crc"] = %crc32($r)
    writeAll(fd, "\n" & $r & "\n")
    if fdatasync(fd) != 0:
      raise newException(LatchError, "mandate log fdatasync failed: " & $strerror(errno))
    inc sc.count
    sc.lastCrc = r["crc"].getStr
    result.add r

proc find*(sc: LatchScan; id: string): int =
  for i, m in sc.mandates:
    if m.id == id: return i
  -1

# ---- operations --------------------------------------------------------------------

proc propose*(s: LatchStore; scope: JsonNode; by: string; id = ""): Mandate =
  ## Anyone may propose. A proposal authorizes nothing.
  let sp = scopeProblem(scope)
  if sp.len > 0: raise newException(ValueError, sp)
  let mid = if id.len > 0: id else: newMandateId()
  discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
    if sc.find(mid) >= 0: raise newException(LatchError, "mandate " & mid & " already exists")
    @[%*{"rec": "propose", "mandate": mid, "by": by, "scope": scope, "digest": digestOf(scope)}])
  let sc = s.scan()
  sc.mandates[sc.find(mid)]

proc approve*(s: LatchStore; id, operator: string; expectDigest = ""): Mandate =
  ## The only path to LATCHED. `operator` must not be a model identity; the
  ## approval records the digest of the exact proposal the operator approved.
  if operator.len == 0 or operator.startsWith("model:"):
    raise newException(LatchError, "approval requires an operator identity")
  discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
    let k = sc.find(id)
    if k < 0: raise newException(LatchError, "no such mandate: " & id)
    let m = sc.mandates[k]
    if m.recorded != msProposed:
      raise newException(LatchError, id & " is " & $m.effectiveState(now) & ", not PROPOSED")
    if expectDigest.len > 0 and expectDigest != m.digest:
      raise newException(LatchError, "digest mismatch: you reviewed " & expectDigest &
        ", the proposal is " & m.digest)
    @[%*{"rec": "approve", "mandate": id, "by": operator, "digest": m.digest}])
  let sc = s.scan()
  sc.mandates[sc.find(id)]

proc grant*(s: LatchStore; scope: JsonNode; operator: string): Mandate =
  ## Operator shortcut: propose and approve in one transaction.
  let sp = scopeProblem(scope)
  if sp.len > 0: raise newException(ValueError, sp)
  if operator.len == 0 or operator.startsWith("model:"):
    raise newException(LatchError, "approval requires an operator identity")
  let mid = newMandateId()
  let dg = digestOf(scope)
  discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
    @[%*{"rec": "propose", "mandate": mid, "by": operator, "scope": scope, "digest": dg},
      %*{"rec": "approve", "mandate": mid, "by": operator, "digest": dg}])
  let sc = s.scan()
  sc.mandates[sc.find(mid)]

proc revoke*(s: LatchStore; id, reason, by: string) =
  ## Anyone may revoke; it never needs approval (invariant L4).
  discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
    let k = sc.find(id)
    if k < 0: raise newException(LatchError, "no such mandate: " & id)
    if sc.mandates[k].recorded notin {msProposed, msLatched, msSuspended}:
      return @[]   # already terminal: revoking is idempotent
    @[%*{"rec": "revoke", "mandate": id, "by": by, "reason": reason}])

proc resume*(s: LatchStore; id, operator: string) =
  if operator.len == 0 or operator.startsWith("model:"):
    raise newException(LatchError, "resume requires an operator identity")
  discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
    let k = sc.find(id)
    if k < 0: raise newException(LatchError, "no such mandate: " & id)
    let st = sc.mandates[k].effectiveState(now)
    if st != msSuspended: raise newException(LatchError, id & " is " & $st & ", not SUSPENDED")
    @[%*{"rec": "resume", "mandate": id, "by": operator}])

proc suspendLatched*(s: LatchStore; reason, by: string): seq[string] =
  ## Suspend every mandate currently LATCHED. Returns their ids.
  var ids: seq[string]
  let pids = addr ids
  discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
    for m in sc.mandates:
      if m.effectiveState(now) == msLatched:
        pids[].add m.id
        result.add %*{"rec": "suspend", "mandate": m.id, "by": by, "reason": reason}
  )
  ids

proc tryUse*(s: LatchStore; tool: string; effect: EffectClass;
             run, action: string): UseResult =
  ## Resolve an ASK. Picks the first LATCHED mandate covering (tool, effect)
  ## and records one use durably BEFORE returning it (write-ahead). If the
  ## record cannot be made durable, nothing is authorized.
  var res: UseResult
  let pres = addr res
  try:
    discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
      for m in sc.mandates:
        if m.effectiveState(now) != msLatched: continue
        pres[].anyLatched = true
        if pres[].mandate.len == 0 and m.covers(tool, effect):
          pres[].mandate = m.id
          pres[].goal = m.goal
          pres[].used = m.used + 1
          pres[].maxActions = m.maxActions
      if pres[].mandate.len > 0:
        @[%*{"rec": "use", "mandate": pres[].mandate, "by": "run:" & run,
             "run": run, "action": action}]
      else: @[])
  except LatchError as e:
    res.error = e.msg
    res.mandate = ""
  res

# ---- model-facing proposal tool --------------------------------------------------------

proc proposalSchema*(): JsonNode =
  %*{"type": "object", "properties": {
      "goal": {"type": "string", "description": "What the mandate is for, in one sentence."},
      "tools": {"type": "array", "items": {"type": "string"},
                "description": "Tool names the mandate would cover."},
      "max_effect": {"type": "string", "enum": ["B0", "B1", "B2", "B3", "B4"]},
      "max_actions": {"type": "integer"},
      "ttl_sec": {"type": "integer"}},
    "required": ["goal", "tools", "max_effect", "max_actions", "ttl_sec"]}

proc scopeFromToolArgs*(args: JsonNode): JsonNode =
  ## Translate the model's snake_case arguments; raises ValueError if malformed.
  if args.kind != JObject: raise newException(ValueError, "arguments must be an object")
  for k in ["goal", "tools", "max_effect", "max_actions", "ttl_sec"]:
    if not args.hasKey(k): raise newException(ValueError, "missing argument: " & k)
  if args["tools"].kind != JArray: raise newException(ValueError, "tools must be an array")
  var tools: seq[string]
  for t in args["tools"]: tools.add t.getStr
  result = scopeJson(args["goal"].getStr, tools, parseEffect(args["max_effect"].getStr),
                     args["max_actions"].getInt, args["ttl_sec"].getInt)
  let sp = scopeProblem(result)
  if sp.len > 0: raise newException(ValueError, sp)
