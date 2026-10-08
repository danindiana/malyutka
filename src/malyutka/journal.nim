## Write-ahead action journal. For every side-effecting call (effect > B0):
##
##   intent -> decision -> started -> (execute) -> outcome
##
## Each record is appended and fdatasync'd BEFORE the next step proceeds, so a
## crash at any point leaves an accurate prefix. An action with `started` but
## no `outcome` whose run is dead is UNKNOWN_OUTCOME: it may or may not have
## taken effect, and Malyutka never re-executes it. If a record cannot be made
## durable, the action does not run.
##
## Framing: each record is written as "\n" & json & "\n", so a fragment torn
## by ANY crashed writer is terminated by the next writer's leading newline.
##
## Strict decoding (0.3.3). A record is valid iff
##   SchemaValid ∧ ChecksumValid ∧ SequenceValid ∧ TransitionValid:
## * Schema: known `rec`, required fields with the right JSON kinds; `w`, `n`,
##   `crc`, `ts` are mandatory (0.3.2 silently accepted records without `crc`,
##   which let a forged record bypass checksum verification).
## * Checksum: CRC-32 over the record without `crc`.
## * Sequence: for each writer, `n` is exactly 1, 2, 3, ... in FILE order. A
##   gap, duplicate (replay) or reordering is corruption. (0.3.2 sorted before
##   checking, so duplicates and reorderings passed.) Writer ids are unique per
##   journal handle (a random suffix), so independent commands never collide.
## * Transitions: per action, intent -> decision -> [ALLOW] started -> outcome,
##   each exactly once, all by the writer that wrote the intent; operator
##   `ack`/`reconcile` only on an UNKNOWN_OUTCOME (dead-owner) action.
## A line that does not parse at all is TORN (a write that never completed;
## the step it guarded never proceeded). Anything parseable that fails a
## predicate is CORRUPT, and corruption fails closed.
##
## Liveness: every journal handle holds an exclusive flock on
## <state>/runs/<writer>.lock for its lifetime. The kernel drops it when the
## process dies (including SIGKILL), so "started, no outcome" is IN_PROGRESS
## while the owner lives and UNKNOWN_OUTCOME only once it is PROVEN dead (we
## took its lock). If liveness cannot be established (lock file missing,
## unreadable, foreign, symlinked; unexpected flock error) the action is
## OWNER_STATUS_UNKNOWN, never assumed dead. Operators can ack or reconcile
## only proven-dead actions. (0.3.4: 0.3.3 treated those failures as dead.)
##
## Operator decisions (`transact`) scan and append under ONE exclusive lock,
## so a concurrent writer cannot change the action between check and append.
##
## Containment: the journal must be a regular file owned by the operator,
## opened with O_NOFOLLOW, in a directory whose canonical path does not
## overlap the workspace (see `checkJournalPlacement`). CRC-32 detects
## accidental corruption and casual tampering; it is NOT a defense against an
## adversary with the operator's uid (that needs a keyed hash chain or an
## external append-only service).

import std/[json, os, posix, strutils, sysrand, tables, times]

proc c_flock(fd: cint; op: cint): cint {.importc: "flock", header: "<sys/file.h>".}
var lO_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
const LOCK_SH = 1.cint
const LOCK_EX = 2.cint
const LOCK_NB = 4.cint
const LOCK_UN = 8.cint

type
  JournalError* = object of CatchableError
  Journal* = ref object
    path*: string      ## canonical
    writer*: string    ## unique per handle
    fd: cint
    lockFd: cint       ## liveness lock, held for the handle's lifetime
    seqNo: int
    failAfter*: int    ## test hook: fail appends after this many (-1 = never)

  ActionState* = enum
    asPrepared = "PREPARED"               ## intent only: never authorized
    asDenied = "DENIED"                   ## authorization refused
    asAuthorized = "AUTHORIZED"           ## allowed, `started` never durable: never ran
    asInProgress = "IN_PROGRESS"          ## started, no outcome, owner still alive
    asOwnerUnknown = "OWNER_STATUS_UNKNOWN"  ## started, no outcome, owner liveness cannot be established
    asUnknownOutcome = "UNKNOWN_OUTCOME"  ## started, no outcome, owner dead: may have happened
    asCompleted = "COMPLETED"
    asFailed = "FAILED"                   ## ran, reported failure
    asNotExecuted = "NOT_EXECUTED"        ## started, but confinement refused it
    asReconciled = "RECONCILED"           ## operator established the real outcome
    asAckUnresolved = "ACKNOWLEDGED_UNRESOLVED"  ## operator saw it; outcome still unknown

  ActionSummary* = object
    action*: string
    run*: string
    owner*: string
    tool*: string
    args*: JsonNode
    state*: ActionState
    startedAt*: string
    reconciledAs*: string

  JournalHealth* = enum jhOk = "OK", jhTorn = "TORN_TAIL", jhCorrupt = "CORRUPT"

  JournalScan* = object
    actions*: seq[ActionSummary]
    health*: JournalHealth
    tornLines*: seq[int]
    problems*: seq[string]   ## corruption details

  WriterLiveness* = enum lvAlive = "ALIVE", lvDead = "DEAD", lvUnknown = "UNKNOWN"
  Liveness* = proc(writer: string): WriterLiveness {.closure.}

# ---- CRC-32 (IEEE) --------------------------------------------------------

proc makeCrcTable(): array[256, uint32] =
  for i in 0 ..< 256:
    var c = uint32(i)
    for _ in 0 ..< 8:
      c = (if (c and 1) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1)
    result[i] = c
const crcTable = makeCrcTable()

proc crc32*(s: string): string =
  var c = 0xFFFFFFFF'u32
  for ch in s: c = crcTable[(c xor uint32(ord(ch))) and 0xFF] xor (c shr 8)
  toHex(BiggestInt(c xor 0xFFFFFFFF'u32), 8).toLowerAscii

# ---- placement -------------------------------------------------------------

proc defaultJournalPath*(): string =
  let base = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state")
  base / "malyutka" / "journal.jsonl"

proc canonicalDir(dir: string): string =
  try:
    createDir(dir)
    expandFilename(dir)
  except OSError as e:
    raise newException(JournalError, "cannot use journal directory '" & dir & "': " & e.msg)

proc checkJournalPlacement*(journalDir, workspace: string) =
  ## The journal directory and the workspace must be disjoint after resolving
  ## symlinks. Otherwise the sandboxed agent could write its own audit trail.
  let jd = canonicalDir(journalDir)
  var ws: string
  try: ws = expandFilename(workspace)
  except OSError: return   # no workspace on disk: nothing it could reach
  if jd == ws or jd.isRelativeTo(ws) or ws.isRelativeTo(jd):
    raise newException(JournalError, "journal directory '" & jd &
      "' overlaps the workspace '" & ws & "': the agent could rewrite its own record")

# ---- liveness locks ----------------------------------------------------------

proc safeName(w: string): string =
  for ch in w:
    result.add(if ch.isAlphaNumeric or ch in {'-', '_', '.'}: ch else: '_')

proc lockPath(journalPath, writer: string): string =
  parentDir(journalPath) / "runs" / (safeName(writer) & ".lock")

proc writerLiveness*(journalPath, writer: string): WriterLiveness =
  ## ALIVE iff the writer's exclusive flock is held; DEAD only if we could
  ## take that lock ourselves (the kernel releases it on process death,
  ## including SIGKILL). Anything else is UNKNOWN, not DEAD: a missing,
  ## symlinked, foreign or unreadable lock file, or an unexpected flock error,
  ## proves nothing about the process. Lock files are never deleted, so a
  ## missing one means it was removed out from under us.
  let p = lockPath(journalPath, writer)
  let fd = posix.open(cstring(p), O_RDONLY or O_CLOEXEC or lO_NOFOLLOW)
  if fd < 0: return lvUnknown
  defer: discard posix.close(fd)
  var st: Stat
  if fstat(fd, st) != 0 or not S_ISREG(st.st_mode) or st.st_uid != getuid():
    return lvUnknown
  if c_flock(fd, LOCK_EX or LOCK_NB) == 0:
    discard c_flock(fd, LOCK_UN)
    return lvDead
  if errno == EWOULDBLOCK: lvAlive else: lvUnknown

# ---- writing -----------------------------------------------------------------

proc randHex(nbytes: int): string =
  for b in urandom(nbytes): result.add toHex(BiggestInt(b), 2).toLowerAscii

proc openJournal*(path = defaultJournalPath(); writer = ""): Journal =
  let dir = canonicalDir(parentDir(path))
  let canon = dir / extractFilename(path)
  let fd = posix.open(cstring(canon), O_WRONLY or O_APPEND or O_CREAT or O_CLOEXEC or lO_NOFOLLOW, 0o600)
  if fd < 0:
    raise newException(JournalError, "cannot open journal " & canon & ": " & $strerror(errno) &
      (if errno == ELOOP: " (journal path is a symlink)" else: ""))
  var st: Stat
  if fstat(fd, st) != 0 or not S_ISREG(st.st_mode) or st.st_uid != getuid():
    discard posix.close(fd)
    raise newException(JournalError, "refusing journal " & canon &
      ": not a regular file owned by uid " & $getuid())
  # Unique writer id per handle: two handles never share a sequence space.
  let base = if writer.len > 0: writer else: "pid" & $getCurrentProcessId()
  let w = base & "." & randHex(6)
  discard canonicalDir(dir / "runs")
  let lfd = posix.open(cstring(lockPath(canon, w)), O_RDWR or O_CREAT or O_CLOEXEC or lO_NOFOLLOW, 0o600)
  if lfd < 0 or c_flock(lfd, LOCK_EX or LOCK_NB) != 0:
    discard posix.close(fd)
    if lfd >= 0: discard posix.close(lfd)
    raise newException(JournalError, "cannot take liveness lock for writer " & w)
  Journal(path: canon, fd: fd, lockFd: lfd, failAfter: -1, writer: w)

proc close*(j: Journal) =
  if j != nil and j.fd >= 0:
    discard posix.close(j.fd)
    j.fd = -1
    discard posix.close(j.lockFd)        # releases the liveness lock
    j.lockFd = -1                        # the file stays: its absence must mean UNKNOWN

proc writeAll(fd: cint; data: string) =
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n < 0:
      if errno == EINTR: continue
      raise newException(JournalError, "journal write failed: " & $strerror(errno))
    off += n

proc lockEx(j: Journal) =
  if c_flock(j.fd, LOCK_EX) != 0:
    raise newException(JournalError, "journal lock failed: " & $strerror(errno))

proc unlock(j: Journal) = discard c_flock(j.fd, LOCK_UN)

proc appendUnlocked(j: Journal; rec: JsonNode) =
  if j.failAfter >= 0 and j.seqNo >= j.failAfter:
    raise newException(JournalError, "journal write refused (test hook)")
  var r = rec.copy
  r["ts"] = %now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")
  r["w"] = %j.writer
  r["n"] = %(j.seqNo + 1)
  r["crc"] = %crc32($r)
  writeAll(j.fd, "\n" & $r & "\n")
  if fdatasync(j.fd) != 0:
    raise newException(JournalError, "journal fdatasync failed: " & $strerror(errno))
  inc j.seqNo

proc append*(j: Journal; rec: JsonNode) =
  ## Durable or exception: never returns having silently lost the record.
  j.lockEx()
  try: j.appendUnlocked(rec)
  finally: j.unlock()

# ---- strict decoding ---------------------------------------------------------

const KnownRecs = ["intent", "decision", "started", "outcome", "reconcile", "ack"]

proc schemaProblem(r: JsonNode): string =
  ## "" if the record has every required field with the right JSON kind.
  template need(k: string; kinds: set[JsonNodeKind]) =
    if not r.hasKey(k) or r[k].kind notin kinds: return "field '" & k & "' missing or mistyped"
  need("rec", {JString}); need("action", {JString}); need("w", {JString})
  need("n", {JInt}); need("crc", {JString}); need("ts", {JString})
  let rec = r["rec"].getStr
  if rec notin KnownRecs: return "unknown record type '" & rec & "'"
  if r["action"].getStr.len == 0 or r["w"].getStr.len == 0: return "empty action or writer"
  if r["n"].getInt < 1: return "sequence number < 1"
  case rec
  of "intent":
    if r.hasKey("tool") and r["tool"].kind != JString: return "intent.tool mistyped"
  of "decision":
    need("verdict", {JString})
    if r["verdict"].getStr notin ["ALLOW", "DENY"]: return "decision.verdict invalid"
  of "outcome":
    need("state", {JString}); need("ok", {JBool})
    if r["state"].getStr notin ["COMPLETED", "NOT_EXECUTED"]: return "outcome.state invalid"
  of "reconcile":
    need("as", {JString})
    if r["as"].getStr notin ["COMPLETED", "FAILED", "NOT_EXECUTED"]: return "reconcile.as invalid"
  else: discard
  ""

proc scanContent*(content: string; alive: Liveness): JournalScan =
  var byId = initOrderedTable[string, ActionSummary]()
  var lastN = initTable[string, int]()
  var lineNo = 0
  proc corrupt(res: var JournalScan; line: int; msg: string) =
    res.problems.add "line " & $line & ": " & msg
  for line in content.splitLines:
    inc lineNo
    if line.strip.len == 0: continue
    var r: JsonNode
    try: r = parseJson(line)
    except JsonParsingError, ValueError:
      result.tornLines.add lineNo
      continue
    if r.kind != JObject:
      result.corrupt(lineNo, "not a JSON object"); continue
    # SchemaValid
    let sp = schemaProblem(r)
    if sp.len > 0:
      result.corrupt(lineNo, sp); continue
    # ChecksumValid
    var body = r.copy
    body.delete("crc")
    if crc32($body) != r["crc"].getStr:
      result.corrupt(lineNo, "checksum mismatch"); continue
    # SequenceValid: exactly last+1 in file order, per writer
    let w = r["w"].getStr
    let n = r["n"].getInt
    let expect = lastN.getOrDefault(w, 0) + 1
    if n != expect:
      result.corrupt(lineNo, "writer " & w & ": sequence " & $n & ", expected " & $expect &
        (if n < expect: " (duplicate or reordered record)" else: " (records missing)"))
      lastN[w] = max(lastN.getOrDefault(w, 0), n)
      continue
    lastN[w] = n
    # TransitionValid
    let id = r["action"].getStr
    let rec = r["rec"].getStr
    if rec == "intent":
      if byId.hasKey(id):
        result.corrupt(lineNo, "action " & id & ": second intent"); continue
      byId[id] = ActionSummary(action: id, state: asPrepared, owner: w, run: r{"run"}.getStr,
                               tool: r{"tool"}.getStr, args: r{"args"})
      continue
    if not byId.hasKey(id):
      result.corrupt(lineNo, "action " & id & ": '" & rec & "' before its intent"); continue
    var a = byId[id]
    let operatorRec = rec in ["reconcile", "ack"]
    if not operatorRec and w != a.owner:
      result.corrupt(lineNo, "action " & id & ": '" & rec & "' by writer " & w &
                     ", but the action belongs to " & a.owner); continue
    let ok = case rec
      of "decision": a.state == asPrepared
      of "started": a.state == asAuthorized
      of "outcome": a.state == asUnknownOutcome          # provisional state for "started"
      of "ack": a.state == asUnknownOutcome
      of "reconcile": a.state in {asUnknownOutcome, asAckUnresolved}
      else: false
    if not ok:
      result.corrupt(lineNo, "action " & id & ": invalid transition '" & rec & "' from " & $a.state)
      continue
    case rec
    of "decision": a.state = (if r["verdict"].getStr == "ALLOW": asAuthorized else: asDenied)
    of "started": a.state = asUnknownOutcome; a.startedAt = r["ts"].getStr
    of "outcome":
      a.state = (if r["state"].getStr == "NOT_EXECUTED": asNotExecuted
                 elif r["ok"].getBool: asCompleted else: asFailed)
    of "ack": a.state = asAckUnresolved
    of "reconcile": a.state = asReconciled; a.reconciledAs = r["as"].getStr
    else: discard
    byId[id] = a
  for _, a in byId.mpairs:
    if a.state == asUnknownOutcome:
      case alive(a.owner)
      of lvAlive: a.state = asInProgress
      of lvUnknown: a.state = asOwnerUnknown   # blocks ack/reconcile; reported
      of lvDead: discard
  for _, a in byId: result.actions.add a
  result.health =
    if result.problems.len > 0: jhCorrupt
    elif result.tornLines.len > 0: jhTorn
    else: jhOk

proc readFd(fd: cint): string =
  var buf: array[65536, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      raise newException(JournalError, "journal read failed: " & $strerror(errno))
    if n == 0: break
    for i in 0 ..< n: result.add buf[i]

proc openForRead(path: string): cint =
  result = posix.open(cstring(path), O_RDONLY or O_CLOEXEC or lO_NOFOLLOW)
  if result < 0 and errno != ENOENT:
    raise newException(JournalError, "cannot read journal " & path & ": " & $strerror(errno))

proc livenessFor(path: string): Liveness =
  result = proc(w: string): WriterLiveness = writerLiveness(path, w)

proc scanJournal*(path = defaultJournalPath()): JournalScan =
  let fd = openForRead(path)
  if fd < 0: return scanContent("", livenessFor(path))
  defer: discard posix.close(fd)
  if c_flock(fd, LOCK_SH) != 0:
    raise newException(JournalError, "journal lock failed: " & $strerror(errno))
  defer: discard c_flock(fd, LOCK_UN)
  scanContent(readFd(fd), livenessFor(path))

proc transact*(j: Journal; decide: proc(scan: JournalScan): JsonNode): JsonNode =
  ## Scan and append under one exclusive lock: the state `decide` sees is the
  ## state the appended record applies to. `decide` returns nil to append
  ## nothing (or raises). Returns the appended record.
  j.lockEx()
  try:
    let rfd = openForRead(j.path)   # same file; read through a new fd, no second flock
    var content = ""
    if rfd >= 0:
      try: content = readFd(rfd)
      finally: discard posix.close(rfd)
    let rec = decide(scanContent(content, livenessFor(j.path)))
    if rec != nil: j.appendUnlocked(rec)
    rec
  finally:
    j.unlock()

proc ownerUnknown*(scan: JournalScan): seq[ActionSummary] =
  for a in scan.actions:
    if a.state == asOwnerUnknown: result.add a

proc unknownOutcomes*(scan: JournalScan): seq[ActionSummary] =
  for a in scan.actions:
    if a.state == asUnknownOutcome: result.add a

proc unknownOutcomes*(path = defaultJournalPath()): seq[ActionSummary] =
  unknownOutcomes(scanJournal(path))
