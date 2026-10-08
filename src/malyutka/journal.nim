## Write-ahead action journal. For every side-effecting call (effect > B0):
##
##   intent -> decision -> started -> (execute) -> outcome
##
## Each record is appended and fdatasync'd BEFORE the next step proceeds, so a
## crash at any point leaves an accurate prefix. An action with `started` but
## no `outcome` is UNKNOWN_OUTCOME: it may or may not have taken effect, and
## Malyutka never re-executes it. If a record cannot be made durable, the
## action does not run.
##
## Integrity (0.3.2):
## * Framing: each record is written as "\n" & json & "\n". A fragment torn by
##   ANY crashed writer is therefore always terminated by the next writer's
##   leading newline; no record can be glued to it. (0.3.1 repaired the tail
##   at open time, which missed writers that already had the file open.)
## * flock: LOCK_EX around every append, LOCK_SH around every scan.
## * Each record carries its writer id `w`, a per-writer sequence number `n`
##   and a CRC-32 `crc` of the record without `crc`. A scan distinguishes a
##   TORN line (not parseable: a write that never completed, so the step it
##   guarded never proceeded) from CORRUPTION (a parseable record with a bad
##   CRC, or a gap in a writer's sequence: durable history lost or altered).
##   Corruption fails closed: runs are refused until the operator inspects.
##
## Containment: the journal must be a regular file owned by the operator,
## opened with O_NOFOLLOW, in a directory whose canonical path does not
## overlap the workspace (see `checkJournalPlacement`). The sandbox cannot
## see it; the agent cannot rewrite its own record.

import std/[algorithm, json, os, posix, strutils, tables, times]

proc c_flock(fd: cint; op: cint): cint {.importc: "flock", header: "<sys/file.h>".}
var lO_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
const LOCK_SH = 1.cint
const LOCK_EX = 2.cint
const LOCK_UN = 8.cint

type
  JournalError* = object of CatchableError
  Journal* = ref object
    path*: string      ## canonical
    writer*: string
    fd: cint
    seqNo: int
    failAfter*: int    ## test hook: fail appends after this many (-1 = never)

  ActionState* = enum
    asPrepared = "PREPARED"               ## intent only: never authorized
    asDenied = "DENIED"                   ## authorization refused
    asAuthorized = "AUTHORIZED"           ## allowed, `started` never durable: never ran
    asUnknownOutcome = "UNKNOWN_OUTCOME"  ## started, no outcome: may have happened
    asCompleted = "COMPLETED"
    asFailed = "FAILED"                   ## ran, reported failure
    asNotExecuted = "NOT_EXECUTED"        ## started, but confinement refused it
    asReconciled = "RECONCILED"           ## operator established the real outcome
    asAckUnresolved = "ACKNOWLEDGED_UNRESOLVED"  ## operator saw it; outcome still unknown

  ActionSummary* = object
    action*: string
    run*: string
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

# ---- writing -----------------------------------------------------------------

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
  Journal(path: canon, fd: fd, failAfter: -1,
          writer: (if writer.len > 0: writer else: "pid" & $getCurrentProcessId()))

proc close*(j: Journal) =
  if j != nil and j.fd >= 0:
    discard posix.close(j.fd)
    j.fd = -1

proc writeAll(fd: cint; data: string) =
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n < 0:
      if errno == EINTR: continue
      raise newException(JournalError, "journal write failed: " & $strerror(errno))
    off += n

proc append*(j: Journal; rec: JsonNode) =
  ## Durable or exception: never returns having silently lost the record.
  if j.failAfter >= 0 and j.seqNo >= j.failAfter:
    raise newException(JournalError, "journal write refused (test hook)")
  var r = rec.copy
  r["ts"] = %now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")
  r["w"] = %j.writer
  r["n"] = %(j.seqNo + 1)
  r["crc"] = %crc32($r)
  let framed = "\n" & $r & "\n"
  if c_flock(j.fd, LOCK_EX) != 0:
    raise newException(JournalError, "journal lock failed: " & $strerror(errno))
  try:
    writeAll(j.fd, framed)
    if fdatasync(j.fd) != 0:
      raise newException(JournalError, "journal fdatasync failed: " & $strerror(errno))
  finally:
    discard c_flock(j.fd, LOCK_UN)
  inc j.seqNo

# ---- reading -------------------------------------------------------------------

proc readLocked(path: string): string =
  let fd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC or lO_NOFOLLOW)
  if fd < 0:
    if errno == ENOENT: return ""
    raise newException(JournalError, "cannot read journal " & path & ": " & $strerror(errno))
  defer: discard posix.close(fd)
  if c_flock(fd, LOCK_SH) != 0:
    raise newException(JournalError, "journal lock failed: " & $strerror(errno))
  defer: discard c_flock(fd, LOCK_UN)
  var buf: array[65536, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      raise newException(JournalError, "journal read failed: " & $strerror(errno))
    if n == 0: break
    for i in 0 ..< n: result.add buf[i]

proc scanJournal*(path = defaultJournalPath()): JournalScan =
  var byId = initOrderedTable[string, ActionSummary]()
  var seqs = initTable[string, seq[int]]()
  var lineNo = 0
  for line in readLocked(path).splitLines:
    inc lineNo
    if line.strip.len == 0: continue
    var r: JsonNode
    try: r = parseJson(line)
    except JsonParsingError, ValueError:
      result.tornLines.add lineNo
      continue
    if r.kind != JObject:
      result.tornLines.add lineNo
      continue
    if r.hasKey("crc"):
      var body = r.copy
      let crc = body["crc"].getStr
      body.delete("crc")
      if crc32($body) != crc:
        result.problems.add "line " & $lineNo & ": checksum mismatch"
        continue
      seqs.mgetOrPut(r{"w"}.getStr, @[]).add r{"n"}.getInt
    let id = r{"action"}.getStr("")
    if id.len == 0: continue
    var a = byId.getOrDefault(id, ActionSummary(action: id, state: asPrepared))
    case r{"rec"}.getStr("")
    of "intent":
      a.run = r{"run"}.getStr; a.tool = r{"tool"}.getStr; a.args = r{"args"}
    of "decision":
      a.state = (if r{"verdict"}.getStr == "ALLOW": asAuthorized else: asDenied)
    of "started":
      a.state = asUnknownOutcome; a.startedAt = r{"ts"}.getStr
    of "outcome":
      a.state = case r{"state"}.getStr
        of "NOT_EXECUTED": asNotExecuted
        else: (if r{"ok"}.getBool(true): asCompleted else: asFailed)
    of "reconcile":
      if a.state in {asUnknownOutcome, asAckUnresolved}:
        a.state = asReconciled; a.reconciledAs = r{"as"}.getStr
    of "ack":
      if a.state == asUnknownOutcome: a.state = asAckUnresolved
    else: discard
    byId[id] = a
  # Per-writer sequence gaps = durable records lost.
  for w, ns in seqs:
    var sorted = ns
    sorted.sort()
    var expect = 1
    for n in sorted:
      if n > expect:
        result.problems.add "writer " & w & ": records " & $expect & ".." & $(n - 1) & " missing"
      expect = n + 1
  for _, a in byId: result.actions.add a
  result.health =
    if result.problems.len > 0: jhCorrupt
    elif result.tornLines.len > 0: jhTorn
    else: jhOk

proc unknownOutcomes*(scan: JournalScan): seq[ActionSummary] =
  for a in scan.actions:
    if a.state == asUnknownOutcome: result.add a

proc unknownOutcomes*(path = defaultJournalPath()): seq[ActionSummary] =
  unknownOutcomes(scanJournal(path))
