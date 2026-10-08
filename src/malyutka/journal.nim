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
## The journal lives in the operator's state directory, outside every
## workspace; the sandbox cannot see it, so the agent cannot rewrite its own
## record. (Append-only by construction, not cryptographically sealed.)

import std/[json, os, posix, strutils, tables, times]

type
  JournalError* = object of CatchableError
  Journal* = ref object
    path*: string
    fd: cint
    failAfter*: int   ## test hook: fail appends after this many (-1 = never)
    written: int

  ActionState* = enum
    asNotStarted = "NOT_STARTED"        ## intent/decision only: never executed
    asUnknownOutcome = "UNKNOWN_OUTCOME"
    asCompleted = "COMPLETED"
    asAcknowledged = "ACKNOWLEDGED"     ## operator reviewed an unknown outcome

  ActionSummary* = object
    action*: string
    run*: string
    tool*: string
    args*: JsonNode
    state*: ActionState
    startedAt*: string

proc defaultJournalPath*(): string =
  let base = getEnv("XDG_STATE_HOME", getHomeDir() / ".local" / "state")
  base / "malyutka" / "journal.jsonl"

proc openJournal*(path = defaultJournalPath()): Journal =
  try: createDir(parentDir(path))
  except OSError as e: raise newException(JournalError, "cannot create journal dir: " & e.msg)
  let fd = posix.open(cstring(path), O_WRONLY or O_APPEND or O_CREAT or O_CLOEXEC, 0o600)
  if fd < 0:
    raise newException(JournalError, "cannot open journal " & path & ": " & $strerror(errno))
  # Crash repair: if the previous process died mid-write, the file ends in a
  # torn line. Terminate it so the next record starts on its own line
  # (otherwise it would be glued to the fragment and lost to the scanner).
  var st: Stat
  if fstat(fd, st) == 0 and st.st_size > 0:
    let rfd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC)
    if rfd >= 0:
      var last: char
      if pread(rfd, addr last, 1, st.st_size - 1) == 1 and last != '\n':
        discard posix.write(fd, cstring("\n"), 1)
        discard fdatasync(fd)
      discard posix.close(rfd)
  Journal(path: path, fd: fd, failAfter: -1)

proc close*(j: Journal) =
  if j != nil and j.fd >= 0:
    discard posix.close(j.fd)
    j.fd = -1

proc append*(j: Journal; rec: JsonNode) =
  ## Durable or exception: never returns having silently lost the record.
  if j.failAfter >= 0 and j.written >= j.failAfter:
    raise newException(JournalError, "journal write refused (test hook)")
  var r = rec
  r["ts"] = %now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")
  let line = $r & "\n"
  var off = 0
  while off < line.len:
    let n = posix.write(j.fd, unsafeAddr line[off], line.len - off)
    if n < 0:
      if errno == EINTR: continue
      raise newException(JournalError, "journal write failed: " & $strerror(errno))
    off += n
  if fdatasync(j.fd) != 0:
    raise newException(JournalError, "journal fdatasync failed: " & $strerror(errno))
  inc j.written

proc scanJournal*(path = defaultJournalPath()): seq[ActionSummary] =
  ## Folds the journal into per-action state. A torn final line (crash
  ## mid-write) is ignored: its step had not been made durable, so the step
  ## it guarded did not proceed.
  if not fileExists(path): return
  var byId = initOrderedTable[string, ActionSummary]()
  for line in lines(path):
    if line.strip.len == 0: continue
    var r: JsonNode
    try: r = parseJson(line)
    except JsonParsingError: continue
    let id = r{"action"}.getStr("")
    if id.len == 0: continue
    var a = byId.getOrDefault(id, ActionSummary(action: id, state: asNotStarted))
    case r{"rec"}.getStr("")
    of "intent":
      a.run = r{"run"}.getStr; a.tool = r{"tool"}.getStr; a.args = r{"args"}
    of "started":
      a.state = asUnknownOutcome; a.startedAt = r{"ts"}.getStr
    of "outcome":
      a.state = asCompleted
    of "ack":
      if a.state == asUnknownOutcome: a.state = asAcknowledged
    else: discard
    byId[id] = a
  for _, a in byId: result.add a

proc unknownOutcomes*(path = defaultJournalPath()): seq[ActionSummary] =
  for a in scanJournal(path):
    if a.state == asUnknownOutcome: result.add a
