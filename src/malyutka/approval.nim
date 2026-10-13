## ASK approvals. An approver can only turn an ASK into an ALLOW (invariant
## 14): core.nim consults it exclusively on the ASK branch, so a DENY from any
## layer is final. Everything unanswerable fails closed: timeout, EOF on the
## control channel, malformed or mismatched answers, an unreadable allowlist.
##
## Grants: `session` lives in memory; `always` is persisted to
## <state>/allowlist.json (0600, O_NOFOLLOW, owned by the operator, strict
## schema + CRC; any defect makes the whole file untrusted, never partially).

import std/[algorithm, json, os, posix, sets, strutils, times]
import ./[types, events]

var lO_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

type
  ApprovalAnswer* = enum
    aaDeny = "deny", aaOnce = "once", aaSession = "session", aaAlways = "always"
  ApprovalRequest* = object
    action*: string       ## the decision event id this request is about
    tool*: string
    args*: JsonNode
    reason*: string
    policy*: string       ## the layer that asked
  ApprovalReply* = object
    answer*: ApprovalAnswer
    source*: string       ## operator | timeout | eof | allowlist | session | off | no-approver | error
  Approver* = proc(req: ApprovalRequest; em: Emitter): ApprovalReply {.closure.}

  GrantStore* = ref object
    session*: HashSet[string]
    always*: HashSet[string]
    path*: string         ## allowlist.json ("" = no persistence)
    problems*: seq[string]

const
  MaxAnswerLine* = 4096
  MaxAllowlistBytes = 1 shl 20
  MaxAllowlistEntries = 10_000

# ---- keys ------------------------------------------------------------------

proc grantKey*(tool: string; args: JsonNode): string =
  ## Exact-match key: tool + normalised arguments. A shell command is
  ## whitespace-collapsed; everything else is its compact JSON.
  if tool == "shell" and args.kind == JObject and args.hasKey("command") and
     args["command"].kind == JString:
    tool & "\x1f" & args["command"].getStr.splitWhitespace.join(" ")
  else:
    tool & "\x1f" & (if args.isNil: "{}" else: $args)

# ---- allowlist file ----------------------------------------------------------

proc entriesCrc(entries: JsonNode): string =
  var h = 0xFFFFFFFF'u32
  for ch in $entries:
    h = h xor uint32(ord(ch))
    for _ in 0 ..< 8:
      h = (if (h and 1) != 0: 0xEDB88320'u32 xor (h shr 1) else: h shr 1)
  toHex(BiggestInt(h xor 0xFFFFFFFF'u32), 8).toLowerAscii

proc readAllowlist*(path: string): tuple[keys: HashSet[string], problem: string] =
  ## Missing file = empty, no problem. Any defect = empty + a problem string.
  result.keys = initHashSet[string]()
  if path.len == 0: return
  let fd = posix.open(cstring(path), O_RDONLY or O_CLOEXEC or lO_NOFOLLOW)
  if fd < 0:
    if errno != ENOENT: result.problem = "cannot open allowlist: " & $strerror(errno)
    return
  defer: discard posix.close(fd)
  var st: Stat
  if fstat(fd, st) != 0:
    result.problem = "cannot stat allowlist"; return
  if not S_ISREG(st.st_mode):
    result.problem = "allowlist is not a regular file"; return
  if st.st_uid != getuid():
    result.problem = "allowlist is not owned by the operator"; return
  if (int(st.st_mode) and 0o077) != 0:
    result.problem = "allowlist is accessible to group/others (want 0600)"; return
  if st.st_size > MaxAllowlistBytes:
    result.problem = "allowlist too large"; return
  var content = ""
  var buf: array[4096, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      result.problem = "allowlist read failed"; return
    if n == 0: break
    for i in 0 ..< n: content.add buf[i]
  var j: JsonNode
  try: j = parseJson(content)
  except CatchableError: result.problem = "allowlist is not valid JSON"; return
  if j.kind != JObject or not j.hasKey("v") or j["v"].kind != JInt or j["v"].getInt != 1 or
     not j.hasKey("entries") or j["entries"].kind != JArray or
     not j.hasKey("crc") or j["crc"].kind != JString:
    result.problem = "allowlist has the wrong schema"; return
  if j["entries"].len > MaxAllowlistEntries:
    result.problem = "allowlist has too many entries"; return
  for e in j["entries"]:
    if e.kind != JString:
      result.problem = "allowlist entry is not a string"; return
  if entriesCrc(j["entries"]) != j["crc"].getStr:
    result.problem = "allowlist checksum mismatch (edited or damaged)"; return
  for e in j["entries"]: result.keys.incl e.getStr

proc writeAllowlist*(path: string; keys: HashSet[string]) =
  var arr = newJArray()
  var sorted: seq[string]
  for k in keys: sorted.add k
  sorted.sort()
  for k in sorted: arr.add %k
  let doc = $(%*{"v": 1, "entries": arr, "crc": entriesCrc(arr)})
  createDir(parentDir(path))
  let tmp = path & ".tmp-" & $getCurrentProcessId()
  removeFile(tmp)
  let fd = posix.open(cstring(tmp), O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC or lO_NOFOLLOW, 0o600)
  if fd < 0: raise newException(IOError, "cannot create allowlist: " & $strerror(errno))
  var off = 0
  while off < doc.len:
    let n = posix.write(fd, unsafeAddr doc[off], doc.len - off)
    if n < 0:
      if errno == EINTR: continue
      discard posix.close(fd); removeFile(tmp)
      raise newException(IOError, "allowlist write failed: " & $strerror(errno))
    off += n
  discard fsync(fd)
  discard posix.close(fd)
  moveFile(tmp, path)

proc newGrantStore*(path = ""): GrantStore =
  result = GrantStore(session: initHashSet[string](), always: initHashSet[string](), path: path)
  let (keys, problem) = readAllowlist(path)
  result.always = keys
  if problem.len > 0: result.problems.add problem

# ---- control channel -------------------------------------------------------

type LineResult* = enum lrLine, lrTimeout, lrEof, lrTooLong

proc readLineTimeout*(fd: cint; timeoutMs: int; line: var string): LineResult =
  ## Byte-at-a-time so no buffered state survives between calls (a following
  ## reader sees exactly the unread bytes). Lines over MaxAnswerLine are
  ## drained to the newline and reported as lrTooLong.
  line.setLen(0)
  let deadline = epochTime() + timeoutMs.float / 1000.0
  var tooLong = false
  while true:
    let left = int((deadline - epochTime()) * 1000.0)
    if left <= 0: return lrTimeout
    var pfd = TPollfd(fd: fd, events: POLLIN, revents: 0)
    let r = poll(addr pfd, 1, cint(left))
    if r < 0:
      if errno == EINTR: continue
      return lrEof
    if r == 0: return lrTimeout
    var c: char
    let n = posix.read(fd, addr c, 1)
    if n < 0:
      if errno == EINTR: continue
      return lrEof
    if n == 0: return lrEof
    if c == '\n':
      return (if tooLong: lrTooLong else: lrLine)
    if line.len >= MaxAnswerLine: tooLong = true
    elif not tooLong: line.add c

proc parseAnswer*(line: string; action: string): tuple[ok: bool, answer: ApprovalAnswer, why: string] =
  ## Strict: a JSON object naming THIS action and a known answer. Anything else
  ## is ignored (and never counts as consent).
  var j: JsonNode
  try: j = parseJson(line)
  except CatchableError: return (false, aaDeny, "not valid JSON")
  if j.kind != JObject or not j.hasKey("action") or j["action"].kind != JString or
     not j.hasKey("answer") or j["answer"].kind != JString:
    return (false, aaDeny, "missing action/answer")
  if j["action"].getStr != action: return (false, aaDeny, "answer is for a different action")
  case j["answer"].getStr
  of "once": (true, aaOnce, "")
  of "session": (true, aaSession, "")
  of "always": (true, aaAlways, "")
  of "deny": (true, aaDeny, "")
  else: (false, aaDeny, "unknown answer")

proc ttyAnswer(s: string): ApprovalAnswer =
  case s.strip.toLowerAscii
  of "o", "once", "y", "yes": aaOnce
  of "s", "session": aaSession
  of "a", "always": aaAlways
  else: aaDeny

# ---- approvers -------------------------------------------------------------

proc denyApprover*(): Approver =
  ## No operator: every ASK is denied (grants may still pre-approve; see gated).
  result = proc(req: ApprovalRequest; em: Emitter): ApprovalReply =
    ApprovalReply(answer: aaDeny, source: "no-approver")

proc offApprover*(): Approver =
  ## YOLO for ASK only. Hardline DENY is untouched: this is never consulted for it.
  result = proc(req: ApprovalRequest; em: Emitter): ApprovalReply =
    ApprovalReply(answer: aaOnce, source: "off")

proc stdinApprover*(timeoutSec: int; fd: cint = 0): Approver =
  ## JSONL control channel. Emits approval.request, then waits for
  ## {"action": "<id>", "answer": "once|session|always|deny"} on `fd`.
  var eof = false
  result = proc(req: ApprovalRequest; em: Emitter): ApprovalReply =
    if eof: return ApprovalReply(answer: aaDeny, source: "eof")
    let expires = now() + initDuration(seconds = timeoutSec)
    discard em.emit("approval.request", %*{"action": req.action, "tool": req.tool,
      "args": req.args, "reason": req.reason, "policy": req.policy,
      "timeoutSec": timeoutSec, "expiresAt": expires.format("yyyy-MM-dd'T'HH:mm:sszzz")})
    let deadline = epochTime() + timeoutSec.float
    var line = ""
    while true:
      let left = int((deadline - epochTime()) * 1000.0)
      if left <= 0: return ApprovalReply(answer: aaDeny, source: "timeout")
      case readLineTimeout(fd, left, line)
      of lrTimeout: return ApprovalReply(answer: aaDeny, source: "timeout")
      of lrEof:
        eof = true
        return ApprovalReply(answer: aaDeny, source: "eof")
      of lrTooLong:
        discard em.emit("approval.ignored", %*{"action": req.action, "reason": "answer line too long"})
      of lrLine:
        let (ok, ans, why) = parseAnswer(line, req.action)
        if ok: return ApprovalReply(answer: ans, source: "operator")
        discard em.emit("approval.ignored", %*{"action": req.action, "reason": why})

proc ttyApprover*(timeoutSec: int): Approver =
  result = proc(req: ApprovalRequest; em: Emitter): ApprovalReply =
    let fd = posix.open("/dev/tty", O_RDWR or O_CLOEXEC)
    if fd < 0: return ApprovalReply(answer: aaDeny, source: "no-tty")
    defer: discard posix.close(fd)
    let prompt = "\n[malyutka] " & req.tool & " " & $req.args & "\n  asks approval: " &
      req.reason & "\n  [o]nce / [s]ession / [a]lways / [d]eny (" & $timeoutSec & "s) > "
    discard posix.write(fd, unsafeAddr prompt[0], prompt.len)
    var line = ""
    case readLineTimeout(fd, timeoutSec * 1000, line)
    of lrLine: ApprovalReply(answer: ttyAnswer(line), source: "operator")
    of lrTimeout: ApprovalReply(answer: aaDeny, source: "timeout")
    of lrEof: ApprovalReply(answer: aaDeny, source: "eof")
    of lrTooLong: ApprovalReply(answer: aaDeny, source: "operator")

proc gated*(inner: Approver; store: GrantStore): Approver =
  ## Consults grants first, then the inner approver; records session/always.
  result = proc(req: ApprovalRequest; em: Emitter): ApprovalReply =
    let key = grantKey(req.tool, req.args)
    if key in store.always: return ApprovalReply(answer: aaOnce, source: "allowlist")
    if key in store.session: return ApprovalReply(answer: aaOnce, source: "session")
    result = inner(req, em)
    case result.answer
    of aaSession: store.session.incl key
    of aaAlways:
      store.always.incl key
      try:
        if store.path.len > 0: writeAllowlist(store.path, store.always)
      except CatchableError as e:
        discard em.emit("approval.ignored", %*{"action": req.action,
          "reason": "allowlist not saved: " & e.msg})
    else: discard

proc makeApprover*(mode: ApprovalMode; store: GrantStore; timeoutSec: int): Approver =
  let inner = case mode
    of amDeny: denyApprover()
    of amStdin: stdinApprover(timeoutSec)
    of amTty: ttyApprover(timeoutSec)
    of amOff: offApprover()
  gated(inner, store)
