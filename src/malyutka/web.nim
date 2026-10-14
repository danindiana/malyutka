## Web access, harness side (SPEC-011, invariant 18). This process never touches the network and never
## parses untrusted markup: it asks `malyutka_web` (a separate binary, TLS-enabled, run inside a
## bwrap sandbox with network but NO filesystem access) to fetch, and gets back one bounded JSON line.
## Here live: the strict config file, the helper call, paging, the in-run memo and the labelling of
## page text as untrusted data.

import std/[json, os, posix, strutils, tables, times]
import ./[types, sandbox, memory, urlsafety]

const
  MaxWebConfigBytes = 64 * 1024
  MaxHelperReply = 8 * 1024 * 1024
  MemoEntries = 16
  MinChars = 1000
  MaxChars = 60000
  FetchBodyCap = 2 * 1024 * 1024

type
  WebConfig* = object
    denyDomains*, allowPrivate*: seq[string]
    timeoutSec*, maxChars*: int
    caFile*: string
    disabled*: bool            ## the config file was unsafe or invalid: web access stays off

  WebState* = ref object
    memo: Table[string, JsonNode]
    order: seq[string]

proc newWebState*(): WebState = WebState(memo: initTable[string, JsonNode]())

# ---- config ------------------------------------------------------------------------

proc defaultWebConfig*(): WebConfig = WebConfig(timeoutSec: 20, maxChars: 15000)

proc strList(j: JsonNode; key: string; problems: var seq[string]): seq[string] =
  if j.kind != JArray:
    problems.add key & " must be an array of strings"
    return
  if j.len > 200:
    problems.add key & " has more than 200 entries"
    return
  for e in j:
    if e.kind != JString or e.getStr.len == 0 or e.getStr.len > 253 or '\0' in e.getStr:
      problems.add key & " has an invalid entry"
      return @[]
    result.add e.getStr.toLowerAscii

proc parseWebConfig*(text: string): tuple[cfg: WebConfig, problems: seq[string]] =
  result.cfg = defaultWebConfig()
  var j: JsonNode
  try: j = parseJson(text)
  except CatchableError:
    result.problems.add "web.json is not valid JSON"
    result.cfg.disabled = true
    return
  if j.kind != JObject:
    result.problems.add "web.json must be an object"
    result.cfg.disabled = true
    return
  if j.hasKey("fetch"):
    let f = j["fetch"]
    if f.kind != JObject:
      result.problems.add "fetch must be an object"
    else:
      if f.hasKey("denyDomains"): result.cfg.denyDomains = strList(f["denyDomains"], "fetch.denyDomains", result.problems)
      if f.hasKey("allowPrivateHosts"): result.cfg.allowPrivate = strList(f["allowPrivateHosts"], "fetch.allowPrivateHosts", result.problems)
      if f.hasKey("timeoutSec"):
        if f["timeoutSec"].kind == JInt and f["timeoutSec"].getInt in 1 .. 60: result.cfg.timeoutSec = f["timeoutSec"].getInt
        else: result.problems.add "fetch.timeoutSec must be 1-60"
      if f.hasKey("maxChars"):
        if f["maxChars"].kind == JInt and f["maxChars"].getInt in MinChars .. MaxChars: result.cfg.maxChars = f["maxChars"].getInt
        else: result.problems.add "fetch.maxChars must be " & $MinChars & "-" & $MaxChars
  if j.hasKey("caFile"):
    if j["caFile"].kind != JString: result.problems.add "caFile must be a string"
    elif j["caFile"].getStr.len > 0:
      let p = j["caFile"].getStr
      if not p.isAbsolute or not fileExists(p) or symlinkExists(p): result.problems.add "caFile must be an absolute path to a regular file"
      else: result.cfg.caFile = p
  # Any defect disables web access: a denylist that failed to load must not silently mean "no denylist".
  if result.problems.len > 0: result.cfg.disabled = true

proc loadWebConfig*(stateDir: string): tuple[cfg: WebConfig, problems: seq[string]] =
  ## Missing file = defaults. An unsafe file (symlink, foreign owner, group/world-writable, oversize)
  ## or an invalid one switches web access off rather than being partially trusted.
  let (text, problem) = readOperatorFile(stateDir / "web.json", MaxWebConfigBytes, false)
  if problem.len > 0:
    return (WebConfig(disabled: true, timeoutSec: 20, maxChars: 15000), @[problem])
  if text.len == 0: return (defaultWebConfig(), @[])
  parseWebConfig(text)

proc applyWebConfig*(cfg: var AgentConfig): seq[string] =
  ## Copies the operator's web settings into the run configuration (the policy layer reads them there).
  let (w, problems) = loadWebConfig(cfg.stateDir)
  cfg.webDeny = w.denyDomains
  cfg.webAllowPrivate = w.allowPrivate
  cfg.webTimeoutSec = w.timeoutSec
  cfg.webMaxChars = w.maxChars
  cfg.webCaFile = w.caFile
  if w.disabled: cfg.allowWeb = false
  problems

# ---- the helper -----------------------------------------------------------------------

proc helperExe*(): string =
  let o = getEnv("MALYUTKA_WEB_HELPER")
  if o.len > 0: return o
  getAppDir() / "malyutka_web"

proc readReply(fd: cint; deadline: float): tuple[data: string, timedOut: bool] =
  var chunk: array[16384, char]
  while true:
    let left = int((deadline - epochTime()) * 1000.0)
    if left <= 0: return (result.data, true)
    var pfd = TPollfd(fd: fd, events: POLLIN, revents: 0)
    let r = poll(addr pfd, 1, cint(min(left, 500)))
    if r < 0:
      if errno == EINTR: continue
      return
    if r == 0: continue
    let n = posix.read(fd, addr chunk[0], chunk.len)
    if n < 0:
      if errno == EINTR: continue
      return
    if n == 0: return
    for i in 0 ..< n: result.data.add chunk[i]
    if result.data.len > MaxHelperReply: return

proc callHelper*(req: JsonNode; timeoutSec: int; caFile: string; unconfined: bool): JsonNode =
  ## One request, one reply. Always returns an object with "ok"; never raises.
  let exe = helperExe()
  if not fileExists(exe):
    return %*{"ok": false, "error": "web helper not found (" & exe & "); build it with `nimble build`"}
  var argv: seq[string]
  var sandboxed = true
  let bw = bwrapPath()
  if bw.len > 0: argv = webHelperArgv(bw, exe, caFile)
  elif unconfined:
    argv = @[exe]
    sandboxed = false
  else:
    return %*{"ok": false, "error": "web access needs the bwrap sandbox for its helper (or the --unconfined-host waiver)"}
  var child: PipedChild
  try: child = startPiped(argv, "/", -1, @[], hostTree = not sandboxed)
  except CatchableError as e: return %*{"ok": false, "error": "cannot start the web helper: " & e.msg}
  let line = $req & "\n"
  var off = 0
  while off < line.len:
    let n = posix.write(child.inFd, unsafeAddr line[off], line.len - off)
    if n < 0:
      if errno == EINTR: continue
      break
    off += n
  discard posix.close(child.inFd)
  let (data, timedOut) = readReply(child.outFd, epochTime() + timeoutSec.float + 8.0)
  discard posix.close(child.outFd)
  if sandboxed: killSandbox(child.pid)
  else:
    discard posix.kill(-child.pid, SIGKILL)
    discard posix.kill(child.pid, SIGKILL)
  var status: cint
  discard waitpid(child.pid, status, 0)
  if timedOut: return %*{"ok": false, "error": "the web helper did not answer in time"}
  let reply = data.strip.splitLines()
  if reply.len == 0 or reply[0].len == 0:
    return %*{"ok": false, "error": "the web helper produced no answer (is libssl installed? try `malyutka doctor`)"}
  try:
    let j = parseJson(reply[0])
    if j.kind == JObject and j.hasKey("ok"): return j
  except CatchableError: discard
  %*{"ok": false, "error": "the web helper returned an unreadable answer"}

proc probeWebHelper*(unconfined: bool): tuple[ok: bool, detail: string] =
  let r = callHelper(%*{"op": "probe", "timeoutSec": 5}, 5, "", unconfined)
  if r["ok"].getBool: (true, "TLS ready, sandboxed")
  else: (false, r{"error"}.getStr("unknown error"))

# ---- the web_fetch tool ------------------------------------------------------------------

proc cutBoundary(s: string; pos: int): int =
  ## A byte offset at or before `pos` that does not split a UTF-8 sequence.
  result = clamp(pos, 0, s.len)
  while result > 0 and result < s.len and (ord(s[result]) and 0xC0) == 0x80: dec result

proc defang(text: string): string =
  ## Page text must not be able to forge our own label.
  text.replace("[web_fetch", "[web-fetch").replace("untrusted page text", "untrusted-page-text")

proc strArg(args: JsonNode; k: string): string =
  if args.kind == JObject and args.hasKey(k) and args[k].kind == JString: args[k].getStr else: ""

proc intArg(args: JsonNode; k: string; d: int): int =
  if args.kind == JObject and args.hasKey(k) and args[k].kind == JInt: args[k].getInt else: d

proc runWebFetch*(state: WebState; args: JsonNode; cfg: AgentConfig): ToolResult =
  let url = strArg(args, "url").strip
  let reason = urlPolicyReason(url, cfg.webDeny, cfg.webAllowPrivate)
  if reason.len > 0:                                   # defence in depth: the policy layer already denies this
    return ToolResult(ok: false, exitCode: 1, output: "ERROR: web_fetch refused: " & reason)
  let offset = max(0, intArg(args, "offset", 0))
  let limit = clamp(intArg(args, "char_limit", cfg.webMaxChars), MinChars, MaxChars)
  var page: JsonNode
  var cached = false
  if state.memo.hasKey(url):
    page = state.memo[url]
    cached = true
  else:
    let req = %*{"op": "fetch", "url": url, "timeoutSec": cfg.webTimeoutSec, "maxBody": FetchBodyCap,
                 "maxChars": 400_000, "denyDomains": cfg.webDeny, "allowPrivate": cfg.webAllowPrivate,
                 "caFile": (if cfg.webCaFile.len > 0: "/ca.pem" else: "")}
    page = callHelper(req, cfg.webTimeoutSec, cfg.webCaFile, cfg.unconfinedHost)
    if not page["ok"].getBool:
      return ToolResult(ok: false, exitCode: 1, output: "ERROR: web_fetch failed: " & page{"error"}.getStr("unknown error"))
    if state.order.len >= MemoEntries:
      state.memo.del(state.order[0])
      state.order.delete(0)
    state.memo[url] = page
    state.order.add url
  let text = page{"text"}.getStr
  let status = page{"status"}.getInt
  let start = cutBoundary(text, offset)
  let stop = cutBoundary(text, start + limit)
  var head = "[web_fetch " & page{"finalUrl"}.getStr(url) & " · HTTP " & $status & " · " & page{"contentType"}.getStr("?").split(';')[0]
  if page{"title"}.getStr.len > 0: head.add " · title: " & defang(page{"title"}.getStr)
  head.add " · chars " & $start & "-" & $stop & " of " & $text.len
  if page{"truncated"}.getBool: head.add " · source truncated"
  if cached: head.add " · cached"
  head.add " · untrusted page text]"
  var body = head & "\n" & defang(text[start ..< stop])
  if stop < text.len: body.add "\n[more: call web_fetch again with offset=" & $stop & "]"
  ToolResult(ok: status < 400, exitCode: (if status < 400: 0 else: 1), output: body,
    truncated: stop < text.len, eventKind: "web.fetched",
    eventPayload: %*{"host": page{"host"}.getStr, "status": status, "bytes": page{"bytes"}.getInt,
                     "redirects": page{"redirects"}.getInt, "cached": cached})
