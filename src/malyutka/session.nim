## Sessions: the transcript of a run, saved atomically after every step so a
## crash keeps it, and strictly decoded so a damaged or foreign file is refused
## rather than half-trusted. Resume rebuilds the MESSAGE LIST only; nothing
## journaled is ever replayed (invariant 15).

import std/[algorithm, json, os, posix, strutils, times]
import ./types

var lO_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

const
  SessionSchema* = 2
  MaxSessionBytes = 32 * 1024 * 1024
  TimeFmt = "yyyy-MM-dd'T'HH:mm:sszzz"

type
  SessionError* = object of CatchableError
  SessionMeta* = object
    parent*: string      ## run id this session continued ("" = fresh)
    title*: string
    provider*: string
    model*: string
    startedAt*: string
    updatedAt*: string
    status*: string      ## running | answered | halted
  SessionInfo* = object
    runId*: string
    meta*: SessionMeta
    messages*: int
    path*: string
  LoadedSession* = object
    runId*: string
    meta*: SessionMeta
    messages*: seq[Message]

proc stamp*(): string = now().format(TimeFmt)

proc encodeMessages(messages: seq[Message]): JsonNode =
  result = newJArray()
  for m in messages:
    var item = %*{"role": $m.role, "content": m.content, "name": m.name,
                  "createdAt": m.createdAt.format(TimeFmt)}
    if m.toolCallId.len > 0: item["toolCallId"] = %m.toolCallId
    if m.toolCalls.len > 0:
      var calls = newJArray()
      for c in m.toolCalls: calls.add %*{"id": c.id, "name": c.name, "args": c.args}
      item["toolCalls"] = calls
    result.add item

proc writeAtomic(path, data: string) =
  createDir(parentDir(path))
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  removeFile(tmp)
  let fd = posix.open(cstring(tmp), O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC or lO_NOFOLLOW, 0o600)
  if fd < 0: raise newException(SessionError, "cannot create " & tmp & ": " & $strerror(errno))
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n < 0:
      if errno == EINTR: continue
      let e = $strerror(errno)
      discard posix.close(fd); removeFile(tmp)
      raise newException(SessionError, "session write failed: " & e)
    off += n
  discard fsync(fd)
  discard posix.close(fd)
  moveFile(tmp, path)

proc saveSession*(path, runId: string; messages: seq[Message]; meta = SessionMeta()) =
  ## Atomic (temp + fsync + rename): a reader sees the old or the new file,
  ## never a torn one, and a crash between steps keeps the last good transcript.
  var m = meta
  if m.updatedAt.len == 0: m.updatedAt = stamp()
  if m.startedAt.len == 0: m.startedAt = m.updatedAt
  let doc = %*{"schema": SessionSchema, "run": runId,
    "meta": {"parent": m.parent, "title": m.title, "provider": m.provider, "model": m.model,
             "startedAt": m.startedAt, "updatedAt": m.updatedAt, "status": m.status},
    "messages": encodeMessages(messages)}
  writeAtomic(path, pretty(doc))

proc validId*(id: string): bool =
  ## Run ids become file names: letters, digits and '-' only.
  if id.len == 0 or id.len > 64: return false
  for c in id:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-'}: return false
  true

proc readRegular(path: string): string =
  let fd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC or lO_NOFOLLOW)
  if fd < 0: raise newException(SessionError, "cannot open session " & path & ": " & $strerror(errno))
  defer: discard posix.close(fd)
  var st: Stat
  if fstat(fd, st) != 0 or not S_ISREG(st.st_mode):
    raise newException(SessionError, "session is not a regular file: " & path)
  if st.st_size > MaxSessionBytes: raise newException(SessionError, "session file too large")
  var buf: array[16384, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      raise newException(SessionError, "session read failed")
    if n == 0: break
    for i in 0 ..< n: result.add buf[i]

proc strOf(j: JsonNode; k: string): string =
  if j.kind == JObject and j.hasKey(k) and j[k].kind == JString: j[k].getStr else: ""

proc parseRole(s: string): Role =
  case s
  of "system": rSystem
  of "user": rUser
  of "assistant": rAssistant
  of "tool": rTool
  else: raise newException(SessionError, "unknown role '" & s & "'")

proc decodeMeta(j: JsonNode): SessionMeta =
  let m = if j.kind == JObject and j.hasKey("meta") and j["meta"].kind == JObject: j["meta"] else: newJObject()
  SessionMeta(parent: strOf(m, "parent"), title: strOf(m, "title"), provider: strOf(m, "provider"),
    model: strOf(m, "model"), startedAt: strOf(m, "startedAt"), updatedAt: strOf(m, "updatedAt"),
    status: (let s = strOf(m, "status"); if s.len > 0: s else: "unknown"))

proc loadSession*(path: string): LoadedSession =
  ## Strict: unknown schema, unknown roles, wrong types => SessionError.
  ## Files written before schema 2 (no "schema" key) are accepted as legacy.
  var j: JsonNode
  try: j = parseJson(readRegular(path))
  except SessionError: raise
  except CatchableError as e: raise newException(SessionError, "session is not valid JSON: " & e.msg)
  if j.kind != JObject: raise newException(SessionError, "session is not an object")
  if j.hasKey("schema"):
    if j["schema"].kind != JInt or j["schema"].getInt != SessionSchema:
      raise newException(SessionError, "unsupported session schema " & $j["schema"])
  if not j.hasKey("run") or j["run"].kind != JString or not validId(j["run"].getStr):
    raise newException(SessionError, "session has no valid run id")
  if not j.hasKey("messages") or j["messages"].kind != JArray:
    raise newException(SessionError, "session has no messages array")
  result.runId = j["run"].getStr
  result.meta = decodeMeta(j)
  for item in j["messages"]:
    if item.kind != JObject or not item.hasKey("role") or item["role"].kind != JString or
       not item.hasKey("content") or item["content"].kind != JString:
      raise newException(SessionError, "malformed message")
    var m = Message(role: parseRole(item["role"].getStr), content: item["content"].getStr,
                    name: strOf(item, "name"), toolCallId: strOf(item, "toolCallId"))
    try: m.createdAt = parse(strOf(item, "createdAt"), TimeFmt)
    except CatchableError: m.createdAt = now()
    if item.hasKey("toolCalls"):
      if item["toolCalls"].kind != JArray: raise newException(SessionError, "malformed toolCalls")
      for c in item["toolCalls"]:
        if c.kind != JObject or strOf(c, "id").len == 0 or strOf(c, "name").len == 0:
          raise newException(SessionError, "malformed tool call")
        m.toolCalls.add ToolCall(id: strOf(c, "id"), name: strOf(c, "name"),
                                 args: (if c.hasKey("args"): c["args"] else: newJObject()))
    result.messages.add m

proc listSessions*(dir: string): seq[SessionInfo] =
  ## Newest first (by file mtime). Undecodable files are skipped, never trusted.
  var found: seq[tuple[t: times.Time, info: SessionInfo]]
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind != pcFile or not path.endsWith(".json"): continue
    try:
      let s = loadSession(path)
      found.add (getLastModificationTime(path),
                 SessionInfo(runId: s.runId, meta: s.meta, messages: s.messages.len, path: path))
    except CatchableError: discard
  found.sort(proc(a, b: tuple[t: times.Time, info: SessionInfo]): int = cmp(b.t, a.t))
  for f in found: result.add f.info

proc resolveSession*(dir, spec: string): string =
  ## "last" = newest; otherwise an exact id or a unique prefix. Returns the file path.
  if spec == "last":
    let all = listSessions(dir)
    if all.len == 0: raise newException(SessionError, "no sessions to resume")
    return all[0].path
  if not validId(spec): raise newException(SessionError, "invalid session id '" & spec & "'")
  let exact = dir / (spec & ".json")
  if fileExists(exact) and not symlinkExists(exact): return exact
  var hits: seq[string]
  for s in listSessions(dir):
    if s.runId.startsWith(spec): hits.add s.path
  if hits.len == 1: return hits[0]
  if hits.len == 0: raise newException(SessionError, "no session matches '" & spec & "'")
  raise newException(SessionError, "'" & spec & "' is ambiguous (" & $hits.len & " sessions)")

proc lineage*(dir, runId: string): seq[string] =
  ## runId and its ancestors (via meta.parent), bounded; unreadable links end the chain.
  var cur = runId
  for _ in 0 ..< 100:
    if not validId(cur) or cur in result: break
    result.add cur
    let p = dir / (cur & ".json")
    if not fileExists(p): break
    try: cur = loadSession(p).meta.parent
    except CatchableError: break
    if cur.len == 0: break

proc searchSessions*(dir, text: string; maxHits = 50): seq[tuple[runId, role, snippet: string]] =
  let needle = text.toLowerAscii
  if needle.len == 0: return
  for s in listSessions(dir):
    let all = try: loadSession(s.path).messages except CatchableError: @[]
    for m in all:
      if m.role == rSystem: continue
      let pos = m.content.toLowerAscii.find(needle)
      if pos >= 0:
        let a = max(0, pos - 30)
        let b = min(m.content.len, pos + needle.len + 50)
        result.add (s.runId, $m.role, m.content[a ..< b].replace("\n", " "))
        if result.len >= maxHits: return
