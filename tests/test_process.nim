## SPEC-008: background processes (invariant 16) and resource-limit wiring.
## Process tests need bubblewrap and skip without it; the limit-wiring tests use
## fake probes and need neither bwrap nor systemd; "real scope" tests skip when
## `systemd-run --user --scope` is unavailable.

import std/[asyncdispatch, json, os, posix, strutils, tables, times, unittest]
import malyutka/[types, provider, core, policy, tools, events, journal, sandbox]

let root = getTempDir() / ("malyutka-proc-" & $getCurrentProcessId())
createDir(root)

let (bwOk, bwDetail) = probeBwrap()
let (scopeOk, scopeDetail) = probeScopes()

proc ws(name: string): string =
  result = root / name
  removeDir(result)
  createDir(result)

proc pcfg(dir: string; maxProc = 4): AgentConfig =
  result = baseConfig()
  result.cwd = dir
  result.allowProcess = true
  result.allowShell = true
  result.maxProcesses = maxProc
  result.cgroupMode = cmOff           # no scope unless a test asks for one

proc call(reg: ToolRegistry; cfg: AgentConfig; args: JsonNode): ToolResult =
  reg["process"].run(args, cfg)

proc idOf(r: ToolResult): string = r.output.split(' ')[1]   # "started p1 (pid N)"

proc pidOf(r: ToolResult): Pid =
  let a = r.output.find("pid ") + 4
  Pid(parseInt(r.output[a ..< r.output.find(')')]))

proc tagged(cmd, name: string): tuple[cmd, tag: string] =
  ## A unique tag in the command line, so survivors can be found by exact content
  ## in /proc (never by a self-matching pgrep -f pattern). The trailing `true` keeps
  ## the shell alive instead of exec'ing the command, so its cmdline carries the tag.
  let tag = "m2tag-" & $getCurrentProcessId() & "-" & name
  (cmd & "; true # " & tag, tag)

proc countTag(tag: string): int =
  for kind, path in walkDir("/proc"):
    if kind != pcDir: continue
    let name = extractFilename(path)
    if name.len == 0 or name[0] notin {'0'..'9'}: continue
    try:
      if tag in readFile(path / "cmdline").replace('\0', ' '): inc result
    except CatchableError: discard

proc noSurvivors(tag: string): bool =
  for _ in 0 ..< 60:
    if countTag(tag) == 0: return true
    sleep(50)
  false

proc gone(pid: Pid): bool =
  # reaped by the manager, so a reaped child has no entry left
  for _ in 0 ..< 50:
    if not pidAlive(pid): return true
    sleep(40)
  false

var boomCommand = "sleep 60"

type Boom = ref object of Provider
  step: int

method next(p: Boom; messages: seq[Message]; tools: JsonNode): Future[ModelAction] {.async.} =
  inc p.step
  if p.step == 1:
    return ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "1", name: "process",
      args: %*{"action": "start", "command": boomCommand})])
  raise newException(IOError, "provider died")

suite "process tool: registry and classification":
  test "exists only with allowProcess; sandbox realm, ceiling B2, per-action effects":
    var c = baseConfig()
    check "process" notin toolsFor(c)
    c.allowProcess = true
    let reg = toolsFor(c)
    check reg["process"].capability.realm == erSandbox
    check reg["process"].capability.maxEffect == b2BroadWorkspace
    check reg["process"].effectOf(%*{"action": "start", "command": "x"}) == b2BroadWorkspace
    check reg["process"].effectOf(%*{"action": "kill", "id": "p1"}) == b1LocalReversible
    for a in ["poll", "log", "list"]: check reg["process"].effectOf(%*{"action": a}) == b0ReadOnly
    check reg["process"].effectOf(%*{}) == b0ReadOnly
    check reg["process"].shutdown != nil

  test "the denylist and dangerous-command layers see `process start` like `shell`":
    let cap = Capability(name: "process", realm: erSandbox, maxEffect: b2BroadWorkspace)
    check compose(defaultLayers(), ToolCall(id: "1", name: "process",
      args: %*{"action": "start", "command": "rm -rf /"}), cap, b2BroadWorkspace, baseConfig(), "e").verdict == vDeny
    check compose(defaultLayers(), ToolCall(id: "1", name: "process",
      args: %*{"action": "start", "command": "git push --force"}), cap, b2BroadWorkspace, baseConfig(), "e").verdict == vAsk
    check compose(defaultLayers(), ToolCall(id: "1", name: "process",
      args: %*{"action": "start", "command": "sleep 1"}), cap, b2BroadWorkspace, baseConfig(), "e").verdict == vAllow

if not bwOk:
  echo "SKIP process behaviour tests: " & bwDetail
else:
  suite "process tool: behaviour (needs bwrap)":
    test "start, poll output and exit code, incremental output, log tail":
      let d = ws("basic"); let cfg = pcfg(d); let reg = toolsFor(cfg)
      defer: discard reg["process"].shutdown()
      let s = call(reg, cfg, %*{"action": "start", "command": "echo one; sleep 1; echo two; exit 3"})
      check s.ok and s.eventKind == "process.started"
      let id = idOf(s)
      var seenOne = false
      var out1, out2 = ""
      let deadline = epochTime() + 10
      while epochTime() < deadline:
        let r = call(reg, cfg, %*{"action": "poll", "id": id})
        let body = r.output.split('\n', 1)
        let text = if body.len > 1: body[1] else: ""
        if "one" in text and not seenOne: (seenOne = true; out1 = text)
        elif seenOne and "two" in text: out2 = text
        if "exited 3" in body[0]: break
        sleep(100)
      check seenOne and "two" notin out1
      check out2.len == 0 or "one" notin out2           # polls return only what is new
      let log = call(reg, cfg, %*{"action": "log", "id": id, "tail": 100})
      check "one" in log.output and "two" in log.output and "exited 3" in log.output
      check call(reg, cfg, %*{"action": "list"}).output.contains(id & "  exited 3")

    test "kill stops a running process and reports it; the pid is gone":
      let d = ws("kill"); let cfg = pcfg(d); let reg = toolsFor(cfg)
      defer: discard reg["process"].shutdown()
      let (cmd, tag) = tagged("sleep 60", "kill")
      let s = call(reg, cfg, %*{"action": "start", "command": cmd})
      let pid = pidOf(s)
      check pidAlive(pid)
      sleep(400)
      check countTag(tag) > 0                            # the sandbox's shell is really there
      let k = call(reg, cfg, %*{"action": "kill", "id": idOf(s)})
      check k.ok and "exited" in k.output and k.eventKind == "process.exited"
      check gone(pid) and noSurvivors(tag)

    test "I16 killing right after start leaves no survivor (bwrap start-up race)":
      let d = ws("race"); let cfg = pcfg(d); let reg = toolsFor(cfg)
      for i in 1 .. 6:
        let (cmd, tag) = tagged("sleep 60", "race" & $i)
        let s = call(reg, cfg, %*{"action": "start", "command": cmd})
        check s.ok
        # no delay: the outer bwrap may not have armed its child's death signal yet
        discard call(reg, cfg, %*{"action": "kill", "id": idOf(s)})
        check noSurvivors(tag)

    test "at most maxProcesses run at once; a finished one frees its slot":
      let d = ws("cap"); let cfg = pcfg(d, maxProc = 2); let reg = toolsFor(cfg)
      defer: discard reg["process"].shutdown()
      let a = call(reg, cfg, %*{"action": "start", "command": "sleep 60"})
      discard call(reg, cfg, %*{"action": "start", "command": "sleep 60"})
      let third = call(reg, cfg, %*{"action": "start", "command": "sleep 60"})
      check not third.ok and "already 2 processes running" in third.output
      discard call(reg, cfg, %*{"action": "kill", "id": idOf(a)})
      check call(reg, cfg, %*{"action": "start", "command": "sleep 60"}).ok

    test "output beyond the ring is dropped visibly, never silently":
      let d = ws("ring"); let cfg = pcfg(d); let reg = toolsFor(cfg)
      defer: discard reg["process"].shutdown()
      let s = call(reg, cfg, %*{"action": "start", "command": "head -c 200000 /dev/zero | tr '\\0' x"})
      let id = idOf(s)
      sleep(1500)
      let r = call(reg, cfg, %*{"action": "poll", "id": id})
      check "earlier bytes were dropped" in r.output
      check "more bytes pending" in r.output
      check r.output.len < 20000

    test "errors: unknown id, unknown action, missing command, oversize command":
      let d = ws("errs"); let cfg = pcfg(d); let reg = toolsFor(cfg)
      check not call(reg, cfg, %*{"action": "poll", "id": "p99"}).ok
      check not call(reg, cfg, %*{"action": "dance"}).ok
      check not call(reg, cfg, %*{"action": "start"}).ok
      check not call(reg, cfg, %*{"action": "start", "command": 'x'.repeat(9000)}).ok

    test "I16 shutdown kills everything still running, is idempotent":
      let d = ws("shutdown"); let cfg = pcfg(d); let reg = toolsFor(cfg)
      let (c1, t1) = tagged("sleep 60", "sd1")
      let (c2, t2) = tagged("sleep 61", "sd2")
      let p1 = pidOf(call(reg, cfg, %*{"action": "start", "command": c1}))
      let p2 = pidOf(call(reg, cfg, %*{"action": "start", "command": c2}))
      let done = call(reg, cfg, %*{"action": "start", "command": "true"})
      sleep(500)
      check reg["process"].shutdown() == 2          # the finished one is not counted
      check gone(p1) and gone(p2) and noSurvivors(t1) and noSurvivors(t2)
      check reg["process"].shutdown() == 0
      discard done

    test "I16 a run that ends with processes running kills them and says so":
      let d = ws("run-end"); var cfg = pcfg(d)
      let (cmdEnd, tagEnd) = tagged("sleep 60", "runend")
      let jpath = root / "jstate" / "p.jsonl"; removeFile(jpath)
      let script = @[
        ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "1", name: "process",
          args: %*{"action": "start", "command": cmdEnd})]),
        ModelAction(kind: makFinal, text: "left it running")]
      var kinds: seq[string]; var ps: seq[JsonNode]
      let kp = addr kinds; let pp = addr ps
      let sink: EventSink = proc(k: string; p: JsonNode) = (kp[].add k; pp[].add p)
      let r = waitFor runAgent(newScriptedProvider(script), "t", cfg, sink = sink, journal = openJournal(jpath))
      check r.answer == "left it running"
      var pid = Pid(0)
      for i, k in kinds:
        if k == "process.started": pid = Pid(ps[i]["pid"].getInt)
      check int(pid) > 0
      check "process.reaped" in kinds
      check gone(pid) and noSurvivors(tagEnd)

    test "I16 even when the run dies with an exception":
      let d = ws("run-exc"); let cfg = pcfg(d)
      let (cmdExc, tagExc) = tagged("sleep 60", "runexc")
      boomCommand = cmdExc
      let jpath = root / "jstate" / "p2.jsonl"; removeFile(jpath)
      var seenPid = Pid(0)
      let pidp = addr seenPid
      let sink: EventSink = proc(k: string; p: JsonNode) =
        if k == "process.started": pidp[] = Pid(p["pid"].getInt)
      expect IOError:
        discard waitFor runAgent(Boom(name: "boom"), "t", cfg, sink = sink, journal = openJournal(jpath))
      check int(seenPid) > 0
      check gone(seenPid) and noSurvivors(tagExc)

    test "the sandbox environment never carries the launcher's variables (--clearenv)":
      let d = ws("env")
      let h = openWorkspace(d)
      defer: h.close()
      let r = runBounded(@[bwrapPath()] & bwrapArgv(h.path, "env | sort"), 10, 65536, h.path,
                         keepFd = h.fd, extraEnv = @[("XDG_RUNTIME_DIR", "/leak"), ("DBUS_SESSION_BUS_ADDRESS", "unix:path=/leak"), ("SECRET_TOKEN", "x")])
      check "XDG_RUNTIME_DIR" notin r.output and "DBUS" notin r.output and "SECRET_TOKEN" notin r.output
      check "PATH=" in r.output and "HOME=" in r.output and "TERM=dumb" in r.output

suite "limits wiring (fake probes)":
  type Seen = ref object
    scopeActive: bool
    unit: string
    calls: int

  proc sandboxTool(seen: Seen): ToolSpec =
    ToolSpec(capability: Capability(name: "box", realm: erSandbox, maxEffect: b0ReadOnly),
      description: "t", parameters: %*{"type": "object"},
      effectOf: proc(args: JsonNode): EffectClass = b0ReadOnly,
      run: proc(args: JsonNode; cfg: AgentConfig): ToolResult =
        seen.scopeActive = cfg.scopeActive
        seen.unit = cfg.unitPrefix
        inc seen.calls
        ToolResult(ok: true, output: "ran", exitCode: 0))

  proc okProbe(): tuple[ok: bool, detail: string] = (true, "fake")
  proc badProbe(): tuple[ok: bool, detail: string] = (false, "no user bus")

  proc run(cfg: AgentConfig; seen: Seen; scope: SandboxProbe; kinds: var seq[string]; ps: var seq[JsonNode]) =
    var reg = initOrderedTable[string, ToolSpec]()
    reg["box"] = sandboxTool(seen)
    let kp = addr kinds; let pp = addr ps
    let sink: EventSink = proc(k: string; p: JsonNode) = (kp[].add k; pp[].add p)
    let script = @[ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "1", name: "box", args: %*{})]),
                   ModelAction(kind: makFinal, text: "ok")]
    discard waitFor runAgent(newScriptedProvider(script), "t", cfg, registry = reg, sink = sink,
                             sandboxProbe = okProbe, scopeProbe = scope)

  test "scope available: limits applied, the tool sees scopeActive and a unit prefix":
    let seen = Seen(); var kinds: seq[string]; var ps: seq[JsonNode]
    run(baseConfig(), seen, okProbe, kinds, ps)
    check seen.scopeActive and seen.unit.startsWith("malyutka-9M14-")
    var lim: JsonNode
    for i, k in kinds:
      if k == "confinement.limits": lim = ps[i]
    check lim["applied"].getBool and lim["memoryMb"].getInt == 2048 and lim["pids"].getInt == 512

  test "auto + unavailable: the run continues, visibly without limits":
    let seen = Seen(); var kinds: seq[string]; var ps: seq[JsonNode]
    run(baseConfig(), seen, badProbe, kinds, ps)
    check not seen.scopeActive and seen.calls == 1
    check "confinement.degraded" in kinds and "confinement.limits" notin kinds
    for i, k in kinds:
      if k == "confinement.degraded": check ps[i]["reason"].getStr == "no user bus" and not ps[i]["applied"].getBool

  test "require + unavailable: the run is refused (like a missing sandbox)":
    var cfg = baseConfig(); cfg.cgroupMode = cmRequire
    let seen = Seen(); var kinds: seq[string]; var ps: seq[JsonNode]
    expect ConfinementError: run(cfg, seen, badProbe, kinds, ps)
    check seen.calls == 0 and "confinement.failed" in kinds

  test "off, or both limits 0, or no sandbox tool: the probe is never consulted":
    var probes = 0
    let pc = addr probes
    var counting: SandboxProbe = proc(): tuple[ok: bool, detail: string] = (inc pc[]; (true, "x"))
    var kinds: seq[string]; var ps: seq[JsonNode]
    var cfg = baseConfig(); cfg.cgroupMode = cmOff
    run(cfg, Seen(), counting, kinds, ps)
    cfg = baseConfig(); cfg.limitMemoryMb = 0; cfg.limitPids = 0
    run(cfg, Seen(), counting, kinds, ps)
    check probes == 0
    discard waitFor runAgent(newMockProvider(), "t", baseConfig(), scopeProbe = counting)   # echo only: no sandbox tool
    check probes == 0

  test "the sandboxed argv is wrapped in a limited scope only when active":
    let plain = sandboxCommand("/usr/bin/bwrap", "/w", "true", false, "malyutka-R", "sh", 2048, 512)
    check plain.argv[0] == "/usr/bin/bwrap" and plain.env.len == 0
    let scoped = sandboxCommand("/usr/bin/bwrap", "/w", "true", true, "malyutka-R", "sh", 256, 40)
    check scoped.argv[0].endsWith("systemd-run") or scoped.argv[0] == ""   # "" only if systemd-run is not installed
    check "--scope" in scoped.argv and "--user" in scoped.argv
    check "MemoryMax=256M" in scoped.argv and "MemorySwapMax=0" in scoped.argv and "TasksMax=40" in scoped.argv
    check scoped.argv[^1] != "" and "/usr/bin/bwrap" in scoped.argv
    let noMem = sandboxCommand("/usr/bin/bwrap", "/w", "true", true, "malyutka-R", "ps", 0, 40)
    check "MemoryMax=0M" notin noMem.argv and "TasksMax=40" in noMem.argv
    check nextUnit("malyutka-R", "sh") != nextUnit("malyutka-R", "sh")

if not scopeOk:
  echo "SKIP real-scope tests: " & scopeDetail
elif not bwOk:
  echo "SKIP real-scope tests: no bwrap"
else:
  suite "limits in a real systemd user scope":
    proc shellCfg(dir: string; mem, pids: int): AgentConfig =
      result = baseConfig()
      result.cwd = dir
      result.allowShell = true
      result.shellTimeoutSec = 20
      result.scopeActive = true
      result.unitPrefix = "malyutka-test-" & $getCurrentProcessId()
      result.limitMemoryMb = mem
      result.limitPids = pids

    test "TasksMax caps a fork loop":
      let d = ws("pids"); let cfg = shellCfg(d, 0, 30)
      let r = toolsFor(cfg)["shell"].run(%*{"command": "for i in $(seq 1 120); do sleep 20 >/dev/null 2>&1 & done 2>&1 | tail -1; echo end"}, cfg)
      check "Cannot fork" in r.output or "Resource temporarily unavailable" in r.output

    test "MemoryMax kills a memory hog, and the same command succeeds without a limit":
      let d = ws("mem"); let cmd = %*{"command": "python3 -c \"x=bytearray(700*1024*1024); print('alloc ok')\"; echo exit=$?"}
      let limited = shellCfg(d, 150, 0)
      let r1 = toolsFor(limited)["shell"].run(cmd, limited)
      check "alloc ok" notin r1.output and "exit=137" in r1.output
      var free = shellCfg(d, 0, 0); free.scopeActive = false
      let r2 = toolsFor(free)["shell"].run(cmd, free)
      check "alloc ok" in r2.output
