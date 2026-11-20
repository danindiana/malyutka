## Experiment log `exp/1` (SPEC-012): append-only, crash-safe, replayable.
##
## Durability and framing are the write-ahead journal's, reused unchanged:
## each record is "\n" & json & "\n", carries a writer id `w`, a per-writer
## sequence number `n`, a timestamp and a CRC-32, and is fdatasync'd before
## `append` returns. A record that cannot be made durable raises, and the
## caller must then not act on it (invariant E3). The log lives in its own
## file, outside the workspace (placement is checked like the journal's), so
## the agent can neither read the design nor write its own outcomes.
##
## Records, per episode (all but `outcome` by the writer that started it):
##
##   episode.start  task, family, seed, design{q,k0,windowLen,intervention}, conditions
##   obs            t, kind (turn|action), data, h      one per completed turn / tool action
##   point          eligible, reason | k,arm,q,p,u,x,intervention, histT, histHead [, features]
##   window.close   k, reason (length|episode-end), actions
##   delivery       k, delivered, detail                treatment delivery, REDIRECT points only
##   outcome        name, value [, k]                   any writer (the evaluator), any time after start
##   episode.end    reason
##
## `h` chains the episode's observations: h_t = crc32(h_{t-1} | kind | data),
## h_0 = "00000000". A point records the history it was decided on as
## (histT, histHead), so the pre-treatment snapshot is the obs prefix 1..histT
## and any feature can be recomputed from it. CRC-32 identifies that prefix;
## like the journal's CRC it does not seal it against the operator's uid.
##
## Strict replay. `scanExperimentContent` re-runs eligibility and the
## randomizer from the log itself. A record is valid iff its schema, CRC and
## per-writer sequence are valid AND it agrees with replay: every point's
## eligibility verdict, history reference and assignment (re-derived from the
## seed) must match, every window must close exactly when replay closes it,
## and no point may be eligible while any window is open (E2). Anything
## parseable that disagrees is CORRUPT and fails closed; an unparseable line
## is TORN (its write never completed, so nothing acted on it).

import std/[json, options, os, posix, strutils, tables]
import ../journal
import ./[randomizer, eligibility]

proc c_flock(fd: cint; op: cint): cint {.importc: "flock", header: "<sys/file.h>".}
var lO_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
const LOCK_SH = 1.cint
const LOCK_UN = 8.cint

const
  ExpSchema* = "exp/1"
  GenesisHead* = "00000000"
  FloatTol = 1e-12

type
  ExperimentError* = object of CatchableError

  Design* = object
    q*: float               ## P(REDIRECT) at every eligible point
    k0*: int                ## completed turns before the first eligible point
    windowLen*: int         ## tool actions per outcome window
    intervention*: string   ## versioned intervention id, e.g. "REDIRECT-v1"

  Recorder* = ref object
    j: Journal
    path*: string
    heads: Table[string, string]   ## per episode: head of its obs chain
    counts: Table[string, int]     ## per episode: obs records written

proc eligibilityCfg*(d: Design): EligibilityCfg =
  EligibilityCfg(k0: d.k0, windowLen: d.windowLen)

proc validDesign*(d: Design): string =
  if not validQ(d.q): return "q must satisfy 0 < q < 1"
  let c = validCfg(d.eligibilityCfg)
  if c.len > 0: return c
  if d.intervention.strip.len == 0: return "intervention id is empty"
  ""

proc designJson*(d: Design): JsonNode =
  %*{"q": d.q, "k0": d.k0, "windowLen": d.windowLen, "intervention": d.intervention}

proc chainNext*(head, kind: string; data: JsonNode): string =
  crc32(head & "\x1f" & kind & "\x1f" & $data)

proc defaultExperimentPath*(stateDir: string): string =
  stateDir / "experiment" / "experiment.jsonl"

# ---- writing -------------------------------------------------------------------

proc openRecorder*(path: string; workspace = ""; writer = "exp"): Recorder =
  ## Opens (creating if needed) the experiment log. With a workspace, refuses a
  ## log directory that overlaps it, as the journal does.
  try:
    if workspace.len > 0: checkJournalPlacement(parentDir(path), workspace)
    let j = openJournal(path, writer)
    Recorder(j: j, path: j.path)
  except JournalError as e:
    raise newException(ExperimentError, e.msg)

proc close*(r: Recorder) =
  if r != nil and r.j != nil:
    r.j.close()
    r.j = nil

proc writer*(r: Recorder): string = r.j.writer

proc failAfter*(r: Recorder; n: int) =
  ## Test hook: appends after the n-th (counted per handle) raise.
  r.j.failAfter = n

proc write(r: Recorder; rec: JsonNode) =
  if r.j == nil: raise newException(ExperimentError, "recorder is closed")
  try: r.j.append(rec)
  except JournalError as e: raise newException(ExperimentError, "experiment record not durable: " & e.msg)

proc requireEpisode(r: Recorder; episode: string) =
  if not r.heads.hasKey(episode):
    raise newException(ExperimentError, "episode '" & episode & "' was not started by this recorder")

proc episodeStart*(r: Recorder; episode, task, family: string; seed: uint64;
                   design: Design; conditions: JsonNode) =
  if episode.len == 0: raise newException(ExperimentError, "empty episode id")
  if r.heads.hasKey(episode): raise newException(ExperimentError, "episode '" & episode & "' already started")
  let bad = validDesign(design)
  if bad.len > 0: raise newException(ExperimentError, "invalid design: " & bad)
  let cond = if conditions.isNil: newJObject() else: conditions
  if cond.kind != JObject: raise newException(ExperimentError, "conditions must be a JSON object")
  r.write(%*{"rec": "episode.start", "schema": ExpSchema, "episode": episode, "task": task,
             "family": family, "seed": seedHex(seed), "design": designJson(design),
             "conditions": cond})
  r.heads[episode] = GenesisHead
  r.counts[episode] = 0

proc observe*(r: Recorder; episode, kind: string; data: JsonNode): tuple[t: int, head: string] =
  ## Appends one observation. Data is canonicalised through one JSON round trip
  ## so the chain digest is the one replay will recompute.
  r.requireEpisode(episode)
  if kind notin ["turn", "action"]: raise newException(ExperimentError, "obs kind must be turn or action")
  let d = if data.isNil: newJObject() else: parseJson($data)
  let t = r.counts[episode] + 1
  let h = chainNext(r.heads[episode], kind, d)
  r.write(%*{"rec": "obs", "episode": episode, "t": t, "kind": kind, "data": d, "h": h})
  r.counts[episode] = t          # only once durable
  r.heads[episode] = h
  (t, h)

proc history*(r: Recorder; episode: string): tuple[t: int, head: string] =
  r.requireEpisode(episode)
  (r.counts[episode], r.heads[episode])

proc pointIneligible*(r: Recorder; episode: string; why: Ineligible) =
  if why == inNone: raise newException(ExperimentError, "pointIneligible needs a reason")
  let (t, h) = r.history(episode)
  r.write(%*{"rec": "point", "episode": episode, "eligible": false, "reason": $why,
             "histT": t, "histHead": h})

proc pointAssigned*(r: Recorder; episode: string; a: Assignment; intervention: string;
                    features: JsonNode = nil) =
  ## The write-ahead record of a randomized decision. Durable before the caller
  ## may deliver anything (E3).
  let (t, h) = r.history(episode)
  var rec = %*{"rec": "point", "episode": episode, "eligible": true, "k": a.k,
               "arm": $a.arm, "q": a.q, "p": a.p, "u": a.u, "x": seedHex(a.x),
               "intervention": intervention, "histT": t, "histHead": h}
  if not features.isNil: rec["features"] = features
  r.write(rec)

proc windowClose*(r: Recorder; episode: string; c: WindowClose) =
  r.requireEpisode(episode)
  r.write(%*{"rec": "window.close", "episode": episode, "k": c.k, "reason": $c.reason,
             "actions": c.actions})

proc delivery*(r: Recorder; episode: string; k: int; delivered: bool; detail = "") =
  r.requireEpisode(episode)
  r.write(%*{"rec": "delivery", "episode": episode, "k": k, "delivered": delivered, "detail": detail})

proc outcome*(r: Recorder; episode, name: string; value: JsonNode; k = -1) =
  ## Any writer (typically the evaluator's own recorder) may add outcomes.
  if name.len == 0: raise newException(ExperimentError, "empty outcome name")
  var rec = %*{"rec": "outcome", "episode": episode, "name": name,
               "value": (if value.isNil: newJNull() else: value)}
  if k >= 0: rec["k"] = %k
  r.write(rec)

proc episodeEnd*(r: Recorder; episode, reason: string) =
  r.requireEpisode(episode)
  r.write(%*{"rec": "episode.end", "episode": episode, "reason": reason})

# ---- strict replay ---------------------------------------------------------------

type
  EpisodeStatus* = enum
    esComplete = "COMPLETE"                 ## episode.end recorded
    esRunning = "RUNNING"                   ## no end, owner alive
    esInterrupted = "INTERRUPTED"           ## no end, owner proven dead (crash)
    esOwnerUnknown = "OWNER_STATUS_UNKNOWN" ## no end, liveness cannot be established

  PointRow* = object
    k*, histT*: int
    histHead*: string
    arm*: Arm
    q*, p*, u*: float
    features*: JsonNode
    closed*: bool
    closeReason*: string     ## "length" | "episode-end" | "" (still open / crash-censored)
    closeActions*: int
    deliveryRecorded*: bool
    delivered*: bool

  EpisodeSummary* = object
    episode*, task*, family*, owner*, seed*: string
    design*: Design
    conditions*: JsonNode
    status*: EpisodeStatus
    obs*, turns*, actions*, ineligible*: int
    points*: seq[PointRow]
    endReason*: string
    outcomes*: seq[JsonNode]

  ExpScan* = object
    episodes*: seq[EpisodeSummary]
    health*: JournalHealth
    tornLines*: seq[int]
    problems*: seq[string]

  EpState = ref object
    s: EpisodeSummary
    seedVal: uint64
    elig: Eligibility
    head: string
    pending: Option[WindowClose]   ## replay closed a window; its record must come next
    ended: bool                    ## episode.end seen

const KnownExpRecs = ["episode.start", "obs", "point", "window.close", "delivery", "outcome", "episode.end"]

proc isNum(n: JsonNode): bool = n != nil and n.kind in {JInt, JFloat}
proc near(a, b: float): bool = abs(a - b) <= FloatTol

proc commonProblem(r: JsonNode): string =
  template need(k: string; kinds: set[JsonNodeKind]) =
    if not r.hasKey(k) or r[k].kind notin kinds: return "field '" & k & "' missing or mistyped"
  need("rec", {JString}); need("episode", {JString}); need("w", {JString})
  need("n", {JInt}); need("crc", {JString}); need("ts", {JString})
  if r["rec"].getStr notin KnownExpRecs: return "unknown record type '" & r["rec"].getStr & "'"
  if r["episode"].getStr.len == 0 or r["w"].getStr.len == 0: return "empty episode or writer"
  if r["n"].getInt < 1: return "sequence number < 1"
  ""

proc scanExperimentContent*(content: string; alive: Liveness): ExpScan =
  var eps = initOrderedTable[string, EpState]()
  var lastN = initTable[string, int]()
  var lineNo = 0
  proc bad(res: var ExpScan; line: int; msg: string) = res.problems.add "line " & $line & ": " & msg

  for line in content.splitLines:
    inc lineNo
    if line.strip.len == 0: continue
    var r: JsonNode
    try: r = parseJson(line)
    except JsonParsingError, ValueError:
      result.tornLines.add lineNo
      continue
    if r.kind != JObject:
      result.bad(lineNo, "not a JSON object"); continue
    let cp = commonProblem(r)
    if cp.len > 0:
      result.bad(lineNo, cp); continue
    var body = r.copy
    body.delete("crc")
    if crc32($body) != r["crc"].getStr:
      result.bad(lineNo, "checksum mismatch"); continue
    let w = r["w"].getStr
    let n = r["n"].getInt
    let expectN = lastN.getOrDefault(w, 0) + 1
    if n != expectN:
      result.bad(lineNo, "writer " & w & ": sequence " & $n & ", expected " & $expectN)
      lastN[w] = max(lastN.getOrDefault(w, 0), n)
      continue
    lastN[w] = n

    let rec = r["rec"].getStr
    let epId = r["episode"].getStr
    template reject(msg: string) =
      result.bad(lineNo, "episode " & epId & ": " & msg)
      continue
    template need(k: string; kinds: set[JsonNodeKind]) =
      if not r.hasKey(k) or r[k].kind notin kinds: reject(rec & "." & k & " missing or mistyped")

    if rec == "episode.start":
      if eps.hasKey(epId): reject("second episode.start")
      need("schema", {JString}); need("task", {JString}); need("family", {JString})
      need("seed", {JString}); need("design", {JObject}); need("conditions", {JObject})
      if r["schema"].getStr != ExpSchema: reject("unsupported schema '" & r["schema"].getStr & "'")
      var seedVal: uint64
      try: seedVal = parseSeed(r["seed"].getStr)
      except RandomizerError as e: reject(e.msg)
      let dj = r["design"]
      if not (isNum(dj{"q"}) and dj{"k0"} != nil and dj["k0"].kind == JInt and
              dj{"windowLen"} != nil and dj["windowLen"].kind == JInt and
              dj{"intervention"} != nil and dj["intervention"].kind == JString):
        reject("design fields missing or mistyped")
      let d = Design(q: dj["q"].getFloat, k0: dj["k0"].getInt, windowLen: dj["windowLen"].getInt,
                     intervention: dj["intervention"].getStr)
      let dbad = validDesign(d)
      if dbad.len > 0: reject("invalid design: " & dbad)
      eps[epId] = EpState(seedVal: seedVal, elig: initEligibility(d.eligibilityCfg), head: GenesisHead,
        s: EpisodeSummary(episode: epId, task: r["task"].getStr, family: r["family"].getStr, owner: w,
                          seed: r["seed"].getStr, design: d, conditions: r["conditions"]))
      continue

    if not eps.hasKey(epId): reject("'" & rec & "' before episode.start")
    let st = eps[epId]
    if rec != "outcome" and w != st.s.owner:
      reject("'" & rec & "' by writer " & w & ", but the episode belongs to " & st.s.owner)
    if st.pending.isSome and rec notin ["window.close", "outcome"]:
      reject("window of point " & $st.pending.get.k & " closed at its last action but no window.close followed")

    case rec
    of "obs":
      if st.elig.ended: reject("observation after the episode ended")
      need("t", {JInt}); need("kind", {JString}); need("h", {JString})
      if not r.hasKey("data"): reject("obs.data missing")
      let kind = r["kind"].getStr
      if kind notin ["turn", "action"]: reject("obs.kind must be turn or action")
      if r["t"].getInt != st.s.obs + 1:
        reject("obs t=" & $r["t"].getInt & ", expected " & $(st.s.obs + 1))
      let h = chainNext(st.head, kind, r["data"])
      if h != r["h"].getStr: reject("obs t=" & $r["t"].getInt & ": history chain mismatch")
      st.head = h
      inc st.s.obs
      if kind == "turn":
        inc st.s.turns
        st.elig.onTurnCompleted()
      else:
        inc st.s.actions
        st.pending = st.elig.onToolAction()

    of "point":
      if st.elig.ended: reject("decision point after the episode ended")
      need("eligible", {JBool}); need("histT", {JInt}); need("histHead", {JString})
      if r["histT"].getInt != st.s.obs or r["histHead"].getStr != st.head:
        reject("point history reference (t=" & $r["histT"].getInt &
               ") does not match the observations before it (t=" & $st.s.obs & ")")
      let replayed = st.elig.check()
      if not r["eligible"].getBool:
        need("reason", {JString})
        if r.hasKey("arm"): reject("ineligible point carries an arm")
        if replayed == inNone: reject("point recorded ineligible, but replay finds it eligible")
        if r["reason"].getStr != $replayed:
          reject("ineligibility reason '" & r["reason"].getStr & "', replay says '" & $replayed & "'")
        inc st.s.ineligible
        continue
      if replayed != inNone:
        reject("point recorded eligible, but replay says " & $replayed & " (lockout violated)")
      need("k", {JInt}); need("arm", {JString}); need("x", {JString}); need("intervention", {JString})
      if not (isNum(r{"q"}) and isNum(r{"p"}) and isNum(r{"u"})): reject("point q/p/u missing or mistyped")
      let k = r["k"].getInt
      if k != st.elig.points: reject("point k=" & $k & ", expected " & $st.elig.points)
      if not near(r["q"].getFloat, st.s.design.q): reject("point q differs from the design")
      if r["intervention"].getStr != st.s.design.intervention:
        reject("point intervention '" & r["intervention"].getStr & "' differs from the design")
      let a = assign(st.seedVal, epId, k, st.s.design.q)
      var arm: Arm
      try: arm = parseArm(r["arm"].getStr)
      except RandomizerError as e: reject(e.msg)
      if arm != a.arm or r["x"].getStr != seedHex(a.x) or not near(r["u"].getFloat, a.u) or
         not near(r["p"].getFloat, a.p):
        reject("point k=" & $k & ": assignment does not re-derive from the seed")
      discard st.elig.openWindow()
      st.s.points.add PointRow(k: k, histT: st.s.obs, histHead: st.head, arm: arm, q: a.q, p: a.p, u: a.u,
                               features: r{"features"})

    of "window.close":
      need("k", {JInt}); need("reason", {JString}); need("actions", {JInt})
      let k = r["k"].getInt
      let reason = r["reason"].getStr
      let acts = r["actions"].getInt
      if k < 0 or k >= st.s.points.len: reject("window.close for unknown point " & $k)
      if reason == $crLength:
        if st.pending.isNone: reject("window.close(length) but replay has not closed a window")
        let c = st.pending.get
        if c.k != k or c.actions != acts: reject("window.close does not match replay (k=" & $c.k &
                                                ", actions=" & $c.actions & ")")
        st.pending = none(WindowClose)
      elif reason == $crEpisodeEnd:
        if not st.elig.windowOpen or st.elig.windowK != k or st.elig.windowActions != acts:
          reject("window.close(episode-end) does not match an open window")
        discard st.elig.endEpisode()   # the episode is ending; only episode.end may follow
      else:
        reject("unknown window.close reason '" & reason & "'")
      st.s.points[k].closed = true
      st.s.points[k].closeReason = reason
      st.s.points[k].closeActions = acts

    of "delivery":
      need("k", {JInt}); need("delivered", {JBool})
      let k = r["k"].getInt
      if k < 0 or k >= st.s.points.len: reject("delivery for unknown point " & $k)
      if st.s.points[k].arm == armContinue: reject("delivery recorded for a CONTINUE point")
      if st.s.points[k].deliveryRecorded: reject("second delivery record for point " & $k)
      st.s.points[k].deliveryRecorded = true
      st.s.points[k].delivered = r["delivered"].getBool

    of "outcome":
      need("name", {JString})
      if r["name"].getStr.len == 0 or not r.hasKey("value"): reject("outcome name/value missing")
      if r.hasKey("k"):
        if r["k"].kind != JInt or r["k"].getInt < 0 or r["k"].getInt >= st.s.points.len:
          reject("outcome for unknown point")
      st.s.outcomes.add r

    of "episode.end":
      need("reason", {JString})
      if st.ended: reject("second episode.end")
      if st.elig.windowOpen:
        reject("episode.end with point " & $st.elig.windowK & "'s window open (no window.close episode-end)")
      if not st.elig.ended: discard st.elig.endEpisode()
      st.ended = true
      st.s.endReason = r["reason"].getStr

    else: discard   # unreachable: KnownExpRecs

  for _, st in eps:
    var s = st.s
    s.status =
      if st.ended: esComplete
      else:
        case alive(s.owner)
        of lvAlive: esRunning
        of lvDead: esInterrupted
        of lvUnknown: esOwnerUnknown
    result.episodes.add s
  result.health =
    if result.problems.len > 0: jhCorrupt
    elif result.tornLines.len > 0: jhTorn
    else: jhOk

proc scanExperiment*(path: string): ExpScan =
  ## Reads the log under a shared lock (appends take it exclusively) and replays it.
  let liveness: Liveness = proc(w: string): WriterLiveness = writerLiveness(path, w)
  let fd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC or lO_NOFOLLOW)
  if fd < 0:
    if errno == ENOENT: return scanExperimentContent("", liveness)
    raise newException(ExperimentError, "cannot read experiment log " & path & ": " & $strerror(errno))
  defer: discard posix.close(fd)
  if c_flock(fd, LOCK_SH) != 0:
    raise newException(ExperimentError, "experiment log lock failed: " & $strerror(errno))
  defer: discard c_flock(fd, LOCK_UN)
  var content = ""
  var buf: array[65536, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      raise newException(ExperimentError, "experiment log read failed: " & $strerror(errno))
    if n == 0: break
    for i in 0 ..< n: content.add buf[i]
  scanExperimentContent(content, liveness)
