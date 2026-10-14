## SPEC-010 MCP client (invariant 17) against tests/fake_mcp.py. Config strictness and
## policy tests need nothing; sandboxed-server tests need bubblewrap; the host-realm
## tests run the same fake server unsandboxed under the --unconfined-host waiver.

import std/[asyncdispatch, json, os, posix, strutils, tables, times, unittest]
import malyutka/[types, provider, core, policy, tools, events, journal, approval, sandbox, mcp]

const fakeServer = currentSourcePath().parentDir / "fake_mcp.py"
let root = getTempDir() / ("malyutka-mcp-" & $getCurrentProcessId())
createDir(root)
let (bwOk, bwDetail) = probeBwrap()

type Boom = ref object of Provider

method next(p: Boom; messages: seq[Message]; tools: JsonNode): Future[ModelAction] {.async.} =
  raise newException(IOError, "provider died")

proc fresh(name: string): string =
  result = root / name
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserExec, fpUserRead, fpUserWrite})

proc srv(name, mode: string; sandbox = true; maxEffect = "B1"; trust = "ask";
         timeoutSec = 10; tag = ""; envAllow: seq[string] = @[]): JsonNode =
  var cmd = %*["python3", (if sandbox: "fake_mcp.py" else: fakeServer), mode]
  if tag.len > 0: cmd.add %tag
  %*{"name": name, "command": cmd, "sandbox": sandbox, "maxEffect": maxEffect, "trust": trust,
     "timeoutSec": timeoutSec, "envAllow": envAllow}

proc setup(name: string; servers: varargs[JsonNode]; unconfined = false): AgentConfig =
  let state = fresh(name & "-state")
  let ws = fresh(name & "-ws")
  copyFile(fakeServer, ws / "fake_mcp.py")
  var arr = newJArray()
  for s in servers: arr.add s
  let path = state / "mcp.json"
  writeFile(path, $(%*{"servers": arr}))
  setFilePermissions(path, {fpUserRead, fpUserWrite})
  result = baseConfig()
  result.allowMcp = true
  result.stateDir = state
  result.cwd = ws
  result.unconfinedHost = unconfined
  result.allowShell = true

proc shutdownAll(reg: ToolRegistry) =
  for _, s in reg:
    if s.shutdown != nil: discard s.shutdown()

proc countTag(tag: string): int =
  for kind, path in walkDir("/proc"):
    if kind != pcDir: continue
    let n = extractFilename(path)
    if n.len == 0 or n[0] notin {'0'..'9'}: continue
    try:
      if tag in readFile(path / "cmdline").replace('\0', ' '): inc result
    except CatchableError: discard

proc noSurvivors(tag: string): bool =
  for _ in 0 ..< 60:
    if countTag(tag) == 0: return true
    sleep(50)
  false

proc kinds(evs: seq[tuple[kind: string, payload: JsonNode]]): seq[string] =
  for e in evs: result.add e.kind

proc call(reg: ToolRegistry; cfg: AgentConfig; name: string; args: JsonNode = %*{}): ToolResult =
  reg[name].run(args, cfg)

suite "mcp.json strictness":
  test "a valid config":
    let r = parseServers($(%*{"servers": [srv("notes", "good"), srv("ro", "good", maxEffect = "B0", trust = "allow")]}))
    check r.problems.len == 0 and r.servers.len == 2
    check r.servers[0].maxEffect == b1LocalReversible and r.servers[0].sandbox and r.servers[0].trust == "ask"
    check r.servers[1].trust == "allow"

  test "each kind of bad server is skipped with a reason; good ones survive":
    let bad = %*{"servers": [
      {"name": "Bad Name", "command": ["x"], "maxEffect": "B0"},
      {"name": "nocmd", "maxEffect": "B0"},
      {"name": "emptycmd", "command": [], "maxEffect": "B0"},
      {"name": "cmdtype", "command": [1], "maxEffect": "B0"},
      {"name": "b3", "command": ["x"], "maxEffect": "B3"},
      {"name": "noeffect", "command": ["x"]},
      {"name": "allowb1", "command": ["x"], "maxEffect": "B1", "trust": "allow"},
      {"name": "trustx", "command": ["x"], "maxEffect": "B0", "trust": "maybe"},
      {"name": "sandboxx", "command": ["x"], "maxEffect": "B0", "sandbox": "yes"},
      {"name": "tmo", "command": ["x"], "maxEffect": "B0", "timeoutSec": 0},
      {"name": "envbad", "command": ["x"], "maxEffect": "B0", "envAllow": ["lower"]},
      {"name": "dup", "command": ["x"], "maxEffect": "B0"},
      {"name": "dup", "command": ["x"], "maxEffect": "B0"},
      {"name": "fine", "command": ["x"], "maxEffect": "B2"}]}
    let r = parseServers($bad)
    check r.servers.len == 2                        # "dup" (first) and "fine"
    check r.problems.len == 12
    let joined = r.problems.join("|")
    for needle in ["name must be", "command must be", "bad command argument", "maxEffect must be",
                   "only accepted with maxEffect B0", "trust must be", "sandbox must be", "timeoutSec", "envAllow", "duplicate"]:
      check needle in joined

  test "not JSON, wrong shape, too many servers":
    check parseServers("{{{").problems.len == 1
    check parseServers("[]").problems.len == 1
    check parseServers("""{"servers": 5}""").problems.len == 1
    var many = newJArray()
    for i in 1 .. 17: many.add %*{"name": "s" & $i, "command": ["x"], "maxEffect": "B0"}
    check parseServers($(%*{"servers": many})).servers.len == 0

  test "the file itself: missing is fine; symlink, group-writable, oversize are refused wholesale":
    let st = fresh("cfgfile")
    check loadMcpConfig(st).servers.len == 0 and loadMcpConfig(st).problems.len == 0
    let good = $(%*{"servers": [srv("a", "good")]})
    writeFile(st / "mcp.json", good); setFilePermissions(st / "mcp.json", {fpUserRead, fpUserWrite})
    check loadMcpConfig(st).servers.len == 1
    setFilePermissions(st / "mcp.json", {fpUserRead, fpUserWrite, fpGroupWrite})
    let gw = loadMcpConfig(st)
    check gw.servers.len == 0 and gw.problems.len == 1
    setFilePermissions(st / "mcp.json", {fpUserRead, fpUserWrite})
    moveFile(st / "mcp.json", st / "real.json")
    createSymlink(st / "real.json", st / "mcp.json")
    check loadMcpConfig(st).servers.len == 0 and loadMcpConfig(st).problems.len == 1
    removeFile(st / "mcp.json")
    writeFile(st / "mcp.json", "x".repeat(70000)); setFilePermissions(st / "mcp.json", {fpUserRead, fpUserWrite})
    check loadMcpConfig(st).servers.len == 0 and loadMcpConfig(st).problems.len == 1

  test "names: servers and tools":
    check validServerName("notes1") and not validServerName("Notes") and not validServerName("a_b") and not validServerName("")
    check sanitizeToolName("Bad Name!") == "bad_name"
    check sanitizeToolName("a--b..c") == "a_b_c"
    check sanitizeToolName("___") == "" and sanitizeToolName("") == ""
    check sanitizeToolName("ÄÖ-ok") == "ok"

suite "I17 registration, ceilings and the ASK layer (host realm, no bwrap needed)":
  test "sandbox:false without the waiver is refused; with it the server connects and the waiver is announced":
    var cfg = setup("waiver", srv("h", "good", sandbox = false))
    var reg = toolsFor(cfg)
    var k = kinds(drainMcpEvents())
    check "mcp.failed" in k and "mcp.connected" notin k
    check "mcp_h_echo" notin reg
    cfg = setup("waiver2", srv("h", "good", sandbox = false), unconfined = true)
    reg = toolsFor(cfg)
    k = kinds(drainMcpEvents())
    defer: shutdownAll(reg)
    check "confinement.waived" in k and "mcp.connected" in k
    check "mcp_h_echo" in reg

  test "tools are external-realm capabilities with the operator's ceiling and no way to exceed it":
    let cfg = setup("ceil", srv("h", "good", sandbox = false, maxEffect = "B1"), unconfined = true)
    let reg = toolsFor(cfg)
    discard drainMcpEvents()
    defer: shutdownAll(reg)
    for n in ["mcp_h_echo", "mcp_h_add", "mcp_h_big", "mcp_h_fail", "mcp_h_env", "mcp_h_img"]:
      check reg[n].capability.realm == erExternal
      check reg[n].capability.maxEffect == b1LocalReversible
      check reg[n].effectOf(%*{"anything": 1}) == b1LocalReversible      # conservative: the ceiling
      check not reg[n].capability.askExempt
      check reg[n].description.startsWith("[MCP h] ")
    # a policy that tried to allow more is still capped by compose
    let cap = reg["mcp_h_echo"].capability
    let d = compose(defaultLayers(), ToolCall(id: "1", name: "mcp_h_echo", args: %*{}), cap, b2BroadWorkspace, baseConfig(), "e")
    check d.verdict == vDeny and d.policyId == "capability.ceiling"

  test "every MCP call asks by default; trust:allow works only on B0 servers":
    let cfg = setup("ask", srv("rw", "good", sandbox = false, maxEffect = "B1"),
                    srv("ro", "good", sandbox = false, maxEffect = "B0", trust = "allow"), unconfined = true)
    let reg = toolsFor(cfg)
    discard drainMcpEvents()
    defer: shutdownAll(reg)
    proc verdict(name: string): Verdict =
      let spec = reg[name]
      compose(defaultLayers(), ToolCall(id: "1", name: name, args: %*{}), spec.capability,
              spec.effectOf(%*{}), baseConfig(), "e").verdict
    check verdict("mcp_rw_echo") == vAsk
    check verdict("mcp_ro_echo") == vAllow
    check reg["mcp_ro_echo"].capability.askExempt and not reg["mcp_rw_echo"].capability.askExempt

  test "name collisions and unusable names are refused; built-ins can never be shadowed":
    let cfg = setup("collide", srv("c", "collide", sandbox = false), unconfined = true)
    let reg = toolsFor(cfg)
    let evs = drainMcpEvents()
    defer: shutdownAll(reg)
    check "mcp_c_shell" in reg and "mcp_c_echo" in reg and "mcp_c_bad_name" in reg and "mcp_c_ok" in reg
    check reg["shell"].capability.realm != erExternal          # the built-in is untouched
    check reg["shell"].capability.name == "shell"
    var refused = 0
    for e in evs:
      if e.kind == "mcp.refused": inc refused
    check refused == 3                                          # "OK" (dup), "" and the 200-char name
    for n, s in reg:
      if n.startsWith("mcp_"): check n.len <= 64 and s.capability.realm == erExternal

  test "paging, the 100-tool cap, and servers that lie about descriptions and schemas":
    var cfg = setup("pages", srv("p", "pages", sandbox = false), unconfined = true)
    var reg = toolsFor(cfg); discard drainMcpEvents()
    check "mcp_p_t1" in reg and "mcp_p_t2" in reg and "mcp_p_t3" in reg
    shutdownAll(reg)
    cfg = setup("many", srv("m", "many", sandbox = false), unconfined = true)
    reg = toolsFor(cfg); discard drainMcpEvents()
    var n = 0
    for k, _ in reg:
      if k.startsWith("mcp_m_"): inc n
    check n == 100
    shutdownAll(reg)
    cfg = setup("lies", srv("l", "lies", sandbox = false), unconfined = true)
    reg = toolsFor(cfg); discard drainMcpEvents()
    check reg["mcp_l_liar"].description.len <= 8 + 500 + 1
    check reg["mcp_l_liar"].parameters == %*{"type": "object"}
    shutdownAll(reg)

suite "calling servers (host realm)":
  proc withServer(name, mode: string; timeoutSec = 10; tag = ""; envAllow: seq[string] = @[]): (AgentConfig, ToolRegistry) =
    let cfg = setup(name, srv("s", mode, sandbox = false, timeoutSec = timeoutSec, tag = tag, envAllow = envAllow), unconfined = true)
    let reg = toolsFor(cfg)
    discard drainMcpEvents()
    (cfg, reg)

  test "echo, add, non-text parts, isError, truncation at 64 KiB":
    let (cfg, reg) = withServer("calls", "good")
    defer: shutdownAll(reg)
    check call(reg, cfg, "mcp_s_echo", %*{"text": "héllo"}).output == "héllo"
    check call(reg, cfg, "mcp_s_add", %*{"a": 2, "b": 40}).output == "42"
    let img = call(reg, cfg, "mcp_s_img")
    check img.ok and "[non-text content omitted: image]" in img.output and "caption" in img.output
    let f = call(reg, cfg, "mcp_s_fail")
    check not f.ok and f.exitCode == 1 and "it failed" in f.output
    let big = call(reg, cfg, "mcp_s_big")
    check big.ok and big.truncated and big.output.len < 65 * 1024 and "truncated" in big.output

  test "the server's environment is scrubbed; only envAllow names pass":
    putEnv("MCP_TEST_VAR", "visible"); putEnv("SECRET_TOKEN", "hunter2")
    defer: (delEnv("MCP_TEST_VAR"); delEnv("SECRET_TOKEN"))
    let (cfg, reg) = withServer("env", "good", envAllow = @["MCP_TEST_VAR"])
    defer: shutdownAll(reg)
    let names = call(reg, cfg, "mcp_s_env").output.split(' ')
    check "MCP_TEST_VAR" in names and "PATH" in names
    check "SECRET_TOKEN" notin names and "MALYUTKA_API_KEY" notin names

  test "a server that hangs: timeout, killed, later calls fail cleanly, nothing survives":
    let tag = "mcptag-" & $getCurrentProcessId() & "-hang"
    let (cfg, reg) = withServer("hang", "hang", timeoutSec = 1, tag = tag)
    check countTag(tag) >= 1
    let t0 = epochTime()
    let r = call(reg, cfg, "mcp_s_slow")
    check epochTime() - t0 < 6.0                             # the 1 s timeout is honoured, not waited out
    check not r.ok and "timed out" in r.output and "server stopped" in r.output
    check noSurvivors(tag)
    let again = call(reg, cfg, "mcp_s_slow")
    check not again.ok and "no longer running" in again.output
    shutdownAll(reg)

  test "broken servers never register: bad JSON, a 2 MiB line, exit before init":
    for mode in ["badjson", "flood", "initfail"]:
      let tag = "mcptag-" & $getCurrentProcessId() & "-" & mode
      let cfg = setup("broken-" & mode, srv("b", mode, sandbox = false, timeoutSec = 5, tag = tag), unconfined = true)
      let reg = toolsFor(cfg)
      let evs = drainMcpEvents()
      check "mcp.failed" in kinds(evs) and "mcp.connected" notin kinds(evs)
      check "mcp_b_slow" notin reg
      check noSurvivors(tag)

  test "stray ids are ignored; a server that only ever sends the wrong id times out":
    var (cfg, reg) = withServer("wrongid", "wrongid")
    check call(reg, cfg, "mcp_s_slow").output == "right answer"
    shutdownAll(reg)
    (cfg, reg) = withServer("onlywrong", "onlywrong", timeoutSec = 1)
    let r = call(reg, cfg, "mcp_s_slow")
    check not r.ok and "timed out" in r.output
    shutdownAll(reg)

  test "server-to-client requests are answered with method-not-found":
    let (cfg, reg) = withServer("srvreq", "serverreq")
    defer: shutdownAll(reg)
    let r = call(reg, cfg, "mcp_s_slow")
    check r.ok and "-32601" in r.output

  test "a server that dies mid-call, and a JSON-RPC error that leaves the connection usable":
    var (cfg, reg) = withServer("exitcall", "exitcall")
    let r = call(reg, cfg, "mcp_s_slow")
    check not r.ok and "closed" in r.output
    check "no longer running" in call(reg, cfg, "mcp_s_slow").output
    shutdownAll(reg)
    (cfg, reg) = withServer("remoteerr", "remoteerr")
    defer: shutdownAll(reg)
    let e1 = call(reg, cfg, "mcp_s_slow")
    check not e1.ok and "server error: nope" in e1.output and e1.output.len < 600
    let e2 = call(reg, cfg, "mcp_s_slow")
    check "server error" in e2.output and "no longer running" notin e2.output

if not bwOk:
  echo "SKIP sandboxed MCP tests: " & bwDetail
else:
  suite "sandboxed servers (needs bwrap)":
    test "a sandboxed server connects, answers, and sees only the scrubbed environment":
      putEnv("SECRET_TOKEN", "hunter2"); putEnv("XDG_RUNTIME_DIR", "/leak")
      defer: (delEnv("SECRET_TOKEN"); delEnv("XDG_RUNTIME_DIR"))
      let cfg = setup("sb", srv("s", "good", sandbox = true, envAllow = @["LANG"]))
      let reg = toolsFor(cfg)
      let evs = drainMcpEvents()
      defer: shutdownAll(reg)
      check "mcp.connected" in kinds(evs)
      check call(reg, cfg, "mcp_s_echo", %*{"text": "in the box"}).output == "in the box"
      let names = call(reg, cfg, "mcp_s_env").output.split(' ')
      check "SECRET_TOKEN" notin names and "XDG_RUNTIME_DIR" notin names and "MALYUTKA_API_KEY" notin names
      check "PATH" in names

    test "a sandboxed server that hangs is killed together with its whole tree":
      let tag = "mcptag-" & $getCurrentProcessId() & "-sbhang"
      let cfg = setup("sbhang", srv("s", "hang", sandbox = true, timeoutSec = 1, tag = tag))
      let reg = toolsFor(cfg); discard drainMcpEvents()
      check countTag(tag) >= 1
      check not call(reg, cfg, "mcp_s_slow").ok
      check noSurvivors(tag)
      shutdownAll(reg)

    test "a program that exists on the host but not in the sandbox fails to connect: no fallback to the host":
      let bait = getHomeDir() / (".malyutka-mcp-bait-" & $getCurrentProcessId())
      createDir(bait)
      defer: removeDir(bait)
      copyFile(fakeServer, bait / "fake_mcp.py")
      # $HOME is not mounted in the sandbox, so this path only resolves on the host
      let cfg = setup("sbmiss", %*{"name": "s", "command": ["python3", bait / "fake_mcp.py", "good"],
                                   "sandbox": true, "maxEffect": "B1", "trust": "ask", "timeoutSec": 5, "envAllow": []})
      let reg = toolsFor(cfg)
      let evs = drainMcpEvents()
      defer: shutdownAll(reg)
      check "mcp.failed" in kinds(evs) and "mcp_s_echo" notin reg

suite "MCP tools in the loop":
  proc script(name: string): seq[ModelAction] =
    @[ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "1", name: name, args: %*{"text": "hi"})]),
      ModelAction(kind: makFinal, text: "done")]

  test "unasked it is denied; approved it runs, is journaled, and the server dies with the run":
    let tag = "mcptag-" & $getCurrentProcessId() & "-loop"
    var cfg = setup("loop", srv("s", "good", sandbox = false, tag = tag), unconfined = true)
    let jp = root / "loopj" / "j.jsonl"
    removeFile(jp)
    var seen: seq[string]
    let sp = addr seen
    let sink: EventSink = proc(k: string; p: JsonNode) = sp[].add k
    var r = waitFor runAgent(newScriptedProvider(script("mcp_s_echo")), "t", cfg, sink = sink, journal = openJournal(jp))
    check r.messages[3].content.startsWith("DENIED by mcp.ask")
    check "mcp.connected" in seen
    check noSurvivors(tag)                                   # killed when the run ended
    cfg = setup("loop2", srv("s", "good", sandbox = false, tag = tag & "2"), unconfined = true)
    var asked = 0
    let ap = addr asked
    let yes: Approver = proc(req: ApprovalRequest; em: Emitter): ApprovalReply =
      inc ap[]
      ApprovalReply(answer: aaOnce, source: "operator")
    removeFile(jp)
    r = waitFor runAgent(newScriptedProvider(script("mcp_s_echo")), "t", cfg, journal = openJournal(jp), approver = yes)
    check asked == 1 and r.messages[3].content == "hi"
    check "mcp_s_echo" in readFile(jp)                       # B1: intent/decision/started/outcome
    check noSurvivors(tag & "2")

  test "the server is killed even when the run dies with an exception":
    let tag = "mcptag-" & $getCurrentProcessId() & "-exc"
    let cfg = setup("exc", srv("s", "good", sandbox = false, tag = tag), unconfined = true)
    expect IOError:
      discard waitFor runAgent(Boom(name: "boom"), "t", cfg)
    check noSurvivors(tag)
