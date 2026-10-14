## MCP client over stdio (SPEC-010, invariant 17). The server is an untrusted child:
## sandboxed by default (the same bwrap broker as `shell`), killed when the run ends,
## and everything it says is data: bounded lines, bounded results, bounded names,
## bounded time. Any protocol violation kills it and later calls fail cleanly.

import std/[json, os, posix, strutils, times]
import ./[types, sandbox, memory]

const
  MaxLine = 1 shl 20
  MaxTools = 100
  MaxDescription = 500
  MaxSchemaBytes = 16 * 1024
  InitTimeoutSec = 15
  MaxConfigBytes = 64 * 1024
  MaxServers = 16
  MaxMessagesPerRequest = 10_000
  ClientVersion = "0.8.0"
  ProtocolVersion = "2024-11-05"
  MaxResultBytes* = 64 * 1024

type
  McpError* = object of CatchableError          ## protocol or transport failure: the server is killed
  McpRemoteError* = object of McpError          ## the server answered with a JSON-RPC error: connection stays usable

  McpServerCfg* = object
    name*: string
    command*: seq[string]
    envAllow*: seq[string]
    sandbox*: bool
    maxEffect*: EffectClass
    trust*: string            ## "ask" | "allow" (allow only with maxEffect B0)
    timeoutSec*: int

  McpTool* = object
    name*, description*: string
    schema*: JsonNode

  McpConn* = ref object
    cfg*: McpServerCfg
    child: PipedChild
    buf: string
    nextId: int
    broken: bool
    closed: bool
    sandboxed: bool
    tools*: seq[McpTool]
    dropped*: seq[string]       ## tools the server listed that were unusable, with the reason

# ---- names -----------------------------------------------------------------

proc validServerName*(n: string): bool =
  if n.len < 1 or n.len > 16: return false
  for c in n:
    if c notin {'a'..'z', '0'..'9'}: return false
  true

proc sanitizeToolName*(s: string): string =
  ## [a-z0-9_] only, collapsed, trimmed; "" if nothing usable remains.
  var last = '_'
  for ch in s.toLowerAscii:
    let c = if ch in {'a'..'z', '0'..'9'}: ch else: '_'
    if c == '_' and last == '_': continue
    result.add c
    last = c
  result = result.strip(chars = {'_'})

proc validEnvName(n: string): bool =
  if n.len == 0 or n.len > 64 or n[0] in {'0'..'9'}: return false
  for c in n:
    if c notin {'A'..'Z', '0'..'9', '_'}: return false
  true

# ---- operator config ---------------------------------------------------------

proc parseEffectName(s: string): tuple[ok: bool, e: EffectClass] =
  case s
  of "B0": (true, b0ReadOnly)
  of "B1": (true, b1LocalReversible)
  of "B2": (true, b2BroadWorkspace)
  else: (false, b0ReadOnly)

proc parseServers*(text: string): tuple[servers: seq[McpServerCfg], problems: seq[string]] =
  var j: JsonNode
  try: j = parseJson(text)
  except CatchableError:
    result.problems.add "mcp.json is not valid JSON"; return
  if j.kind != JObject or not j.hasKey("servers") or j["servers"].kind != JArray:
    result.problems.add "mcp.json needs a \"servers\" array"; return
  if j["servers"].len > MaxServers:
    result.problems.add "more than " & $MaxServers & " servers"; return
  var seen: seq[string]
  for i in 0 ..< j["servers"].len:
    let s = j["servers"][i]
    let label = "server #" & $(i + 1)
    if s.kind != JObject: result.problems.add label & ": not an object"; continue
    let name = if s.hasKey("name") and s["name"].kind == JString: s["name"].getStr else: ""
    if not validServerName(name): result.problems.add label & ": name must be 1-16 of a-z0-9"; continue
    if name in seen: result.problems.add name & ": duplicate name"; continue
    var cfg = McpServerCfg(name: name, sandbox: true, trust: "ask", timeoutSec: 30)
    if not s.hasKey("command") or s["command"].kind != JArray or s["command"].len < 1 or s["command"].len > 32:
      result.problems.add name & ": command must be an array of 1-32 strings"; continue
    var okCmd = true
    for a in s["command"]:
      if a.kind != JString or a.getStr.len == 0 or a.getStr.len > 4096 or '\0' in a.getStr: okCmd = false
      else: cfg.command.add a.getStr
    if not okCmd: result.problems.add name & ": bad command argument"; continue
    if s.hasKey("envAllow"):
      if s["envAllow"].kind != JArray: result.problems.add name & ": envAllow must be an array"; continue
      var okEnv = true
      for e in s["envAllow"]:
        if e.kind != JString or not validEnvName(e.getStr): okEnv = false
        else: cfg.envAllow.add e.getStr
      if not okEnv: result.problems.add name & ": envAllow has an invalid variable name"; continue
    if s.hasKey("sandbox"):
      if s["sandbox"].kind != JBool: result.problems.add name & ": sandbox must be true or false"; continue
      cfg.sandbox = s["sandbox"].getBool
    let me = if s.hasKey("maxEffect") and s["maxEffect"].kind == JString: parseEffectName(s["maxEffect"].getStr) else: (false, b0ReadOnly)
    if not me.ok: result.problems.add name & ": maxEffect must be B0, B1 or B2"; continue
    cfg.maxEffect = me.e
    if s.hasKey("trust"):
      if s["trust"].kind != JString or s["trust"].getStr notin ["ask", "allow"]:
        result.problems.add name & ": trust must be \"ask\" or \"allow\""; continue
      cfg.trust = s["trust"].getStr
    if cfg.trust == "allow" and cfg.maxEffect != b0ReadOnly:
      result.problems.add name & ": trust \"allow\" is only accepted with maxEffect B0"; continue
    if s.hasKey("timeoutSec"):
      if s["timeoutSec"].kind != JInt or s["timeoutSec"].getInt < 1 or s["timeoutSec"].getInt > 300:
        result.problems.add name & ": timeoutSec must be 1-300"; continue
      cfg.timeoutSec = s["timeoutSec"].getInt
    seen.add name
    result.servers.add cfg

proc loadMcpConfig*(stateDir: string): tuple[servers: seq[McpServerCfg], problems: seq[string]] =
  ## Missing file = no servers. Unsafe file (symlink, foreign owner, group/world-writable,
  ## oversize) = a problem and NO servers: the file is never partially trusted.
  let (text, problem) = readOperatorFile(stateDir / "mcp.json", MaxConfigBytes, false)
  if problem.len > 0:
    result.problems.add problem
    return
  if text.len == 0: return
  parseServers(text)

# ---- transport ----------------------------------------------------------------

proc shellQuote(s: string): string = "'" & s.replace("'", "'\\''") & "'"

proc kill*(c: McpConn) =
  if c.closed: return
  c.closed = true
  c.broken = true
  discard posix.close(c.child.inFd)
  discard posix.close(c.child.outFd)
  if c.sandboxed: killSandbox(c.child.pid)
  else:
    discard posix.kill(-c.child.pid, SIGKILL)
    discard posix.kill(c.child.pid, SIGKILL)
  var status: cint
  discard waitpid(c.child.pid, status, 0)

proc fail(c: McpConn; msg: string) {.noreturn.} =
  ## Protocol/transport failure: the stream may be desynchronised, so the server dies.
  c.kill()
  raise newException(McpError, msg)

proc sendLine(c: McpConn; msg: JsonNode) =
  if c.broken: raise newException(McpError, "server is not running")
  let data = $msg & "\n"
  var off = 0
  while off < data.len:
    let n = posix.write(c.child.inFd, unsafeAddr data[off], data.len - off)
    if n < 0:
      if errno == EINTR: continue
      c.fail("cannot write to the server: " & $strerror(errno))
    off += n

proc readMessage(c: McpConn; deadline: float): JsonNode =
  while true:
    let nl = c.buf.find('\n')
    if nl >= 0:
      let line = c.buf[0 ..< nl]
      c.buf.delete(0 .. nl)
      if line.strip.len == 0: continue
      var j: JsonNode
      try: j = parseJson(line)
      except CatchableError: c.fail("the server sent invalid JSON")
      if j.kind != JObject: c.fail("the server sent a non-object message")
      return j
    if c.buf.len > MaxLine: c.fail("a server line exceeded " & $MaxLine & " bytes")
    let left = int((deadline - epochTime()) * 1000.0)
    if left <= 0: c.fail("timed out waiting for the server")
    var pfd = TPollfd(fd: c.child.outFd, events: POLLIN, revents: 0)
    let r = poll(addr pfd, 1, cint(left))
    if r < 0:
      if errno == EINTR: continue
      c.fail("poll failed")
    if r == 0: c.fail("timed out waiting for the server")
    var chunk: array[65536, char]
    let n = posix.read(c.child.outFd, addr chunk[0], chunk.len)
    if n < 0:
      if errno == EINTR: continue
      c.fail("read failed: " & $strerror(errno))
    if n == 0: c.fail("the server closed its output")
    for i in 0 ..< n: c.buf.add chunk[i]

proc request(c: McpConn; meth: string; params: JsonNode; timeoutSec: int): JsonNode =
  inc c.nextId
  let id = c.nextId
  c.sendLine(%*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params})
  let deadline = epochTime() + timeoutSec.float
  for _ in 0 ..< MaxMessagesPerRequest:
    let m = c.readMessage(deadline)
    if m.hasKey("method"):
      # a notification, or a request we do not support: answer so the server is not left waiting
      if m.hasKey("id"):
        c.sendLine(%*{"jsonrpc": "2.0", "id": m["id"],
                      "error": {"code": -32601, "message": "method not supported by this client"}})
      continue
    if m.hasKey("id") and m["id"].kind == JInt and m["id"].getInt == id:
      if m.hasKey("error"):
        let msg = if m["error"].kind == JObject and m["error"].hasKey("message") and m["error"]["message"].kind == JString:
                    m["error"]["message"].getStr else: "unspecified error"
        raise newException(McpRemoteError, "server error: " & (if msg.len > 300: msg[0 ..< 300] else: msg))
      if not m.hasKey("result"): c.fail("a response had neither result nor error")
      return m["result"]
    # a response to some other id (late, duplicated or invented): ignored
  c.fail("too many unrelated messages")

# ---- connection ----------------------------------------------------------------

proc clip(s: string; n: int): string = (if s.len <= n: s else: s[0 ..< n])

proc parseTool(t: JsonNode): tuple[ok: bool, tool: McpTool, why: string] =
  if t.kind != JObject or not t.hasKey("name") or t["name"].kind != JString:
    result.why = "entry without a string name"; return
  let name = t["name"].getStr
  if name.len == 0: result.why = "empty tool name"; return
  if name.len > 128: result.why = "tool name longer than 128 characters"; return
  var tool = McpTool(name: name, schema: %*{"type": "object"})
  if t.hasKey("description") and t["description"].kind == JString:
    tool.description = clip(t["description"].getStr, MaxDescription).replace("\n", " ")
  if t.hasKey("inputSchema") and t["inputSchema"].kind == JObject and
     t["inputSchema"].hasKey("type") and t["inputSchema"]["type"].kind == JString and
     t["inputSchema"]["type"].getStr == "object" and ($t["inputSchema"]).len <= MaxSchemaBytes:
    tool.schema = t["inputSchema"]
  (true, tool, "")

proc spawnServer(cfg: McpServerCfg; agent: AgentConfig): tuple[child: PipedChild, sandboxed: bool] =
  var extra: seq[EnvPair]
  for n in cfg.envAllow:
    if existsEnv(n): extra.add (n, getEnv(n))
  if cfg.sandbox:
    let exe = bwrapPath()
    if exe.len == 0: raise newException(McpError, "sandbox requested but bwrap is unavailable")
    let ws = openWorkspace(agent.cwd)
    defer: ws.close()
    var cmd: seq[string]
    for a in cfg.command: cmd.add shellQuote(a)
    result.child = startPiped(@[exe] & bwrapArgv(ws.path, cmd.join(" "), extra), ws.path, ws.fd)
    result.sandboxed = true
  else:
    let exe = if '/' in cfg.command[0]: cfg.command[0] else: findExe(cfg.command[0])
    if exe.len == 0 or not fileExists(exe): raise newException(McpError, "command not found: " & cfg.command[0])
    result.child = startPiped(@[exe] & cfg.command[1 .. ^1], agent.cwd, -1, extra, hostTree = true)

proc connect*(cfg: McpServerCfg; agent: AgentConfig): McpConn =
  let (child, sandboxed) = spawnServer(cfg, agent)
  let c = McpConn(cfg: cfg, child: child, sandboxed: sandboxed)
  try:
    discard c.request("initialize", %*{"protocolVersion": ProtocolVersion, "capabilities": {},
      "clientInfo": {"name": "malyutka", "version": ClientVersion}}, InitTimeoutSec)
    c.sendLine(%*{"jsonrpc": "2.0", "method": "notifications/initialized"})
    var cursor = ""
    for _ in 0 ..< 5:
      let params = if cursor.len > 0: %*{"cursor": cursor} else: newJObject()
      let r = c.request("tools/list", params, InitTimeoutSec)
      if r.kind != JObject or not r.hasKey("tools") or r["tools"].kind != JArray:
        c.fail("tools/list returned no tools array")
      for t in r["tools"]:
        if c.tools.len >= MaxTools: break
        let (ok, tool, why) = parseTool(t)
        if ok: c.tools.add tool
        elif c.dropped.len < 20: c.dropped.add why
      cursor = if r.hasKey("nextCursor") and r["nextCursor"].kind == JString: r["nextCursor"].getStr else: ""
      if cursor.len == 0 or c.tools.len >= MaxTools: break
  except CatchableError as e:
    c.kill()
    raise newException(McpError, cfg.name & ": " & e.msg)
  c

proc callTool*(c: McpConn; tool: string; args: JsonNode; maxBytes = MaxResultBytes): ToolResult =
  if c.broken:
    return ToolResult(ok: false, exitCode: 1, output: "ERROR: MCP server '" & c.cfg.name & "' is no longer running")
  try:
    let a = if args.kind == JObject: args else: newJObject()
    let r = c.request("tools/call", %*{"name": tool, "arguments": a}, c.cfg.timeoutSec)
    var text = ""
    var truncated = false
    if r.kind == JObject and r.hasKey("content") and r["content"].kind == JArray:
      for part in r["content"]:
        var piece = ""
        if part.kind == JObject and part.hasKey("type") and part["type"].kind == JString and part["type"].getStr == "text" and
           part.hasKey("text") and part["text"].kind == JString:
          piece = part["text"].getStr
        elif part.kind == JObject and part.hasKey("type") and part["type"].kind == JString:
          piece = "[non-text content omitted: " & clip(part["type"].getStr, 40) & "]"
        else:
          piece = "[unrecognised content part omitted]"
        if text.len > 0: text.add "\n"
        text.add piece
        if text.len > maxBytes:
          text = text[0 ..< maxBytes]
          truncated = true
          break
    else:
      text = clip($r, maxBytes)
    if truncated: text.add "\n[malyutka: MCP result truncated at " & $maxBytes & " bytes]"
    let isErr = r.kind == JObject and r.hasKey("isError") and r["isError"].kind == JBool and r["isError"].getBool
    ToolResult(ok: not isErr, exitCode: (if isErr: 1 else: 0), output: text, truncated: truncated)
  except McpRemoteError as e:
    ToolResult(ok: false, exitCode: 1, output: "ERROR: MCP " & c.cfg.name & ": " & e.msg)
  except McpError as e:
    ToolResult(ok: false, exitCode: 1, output: "ERROR: MCP " & c.cfg.name & ": " & e.msg & " (server stopped)")

proc pid*(c: McpConn): Pid = c.child.pid
proc running*(c: McpConn): bool = not c.broken
