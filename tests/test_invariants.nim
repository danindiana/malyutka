## One test per architectural invariant (see ARCHITECTURE.md). Test names
## start with the invariant number so a failure reads as a broken invariant.

import std/[asyncdispatch, json, os, posix, strutils, tables, unittest]
import malyutka/[types, provider, core, policy, tools, events, sandbox, journal]

# Private per-process scratch dir: never fixed names in shared /tmp.
let testTmp = getTempDir() / ("malyutka-t-" & $getCurrentProcessId())
createDir(testTmp)

proc cfgWith(allowShell = false; unconfined = false): AgentConfig =
  result = baseConfig()
  result.cwd = getCurrentDir()
  result.allowShell = allowShell
  result.unconfinedHost = unconfined

proc tmpJournal(name: string): Journal =
  let path = testTmp / "state" / (name & ".jsonl")
  removeFile(path)
  openJournal(path)

proc recs(j: Journal): seq[string] =
  for line in lines(j.path):
    if line.strip.len > 0: result.add parseJson(line)["rec"].getStr   # framing adds blank lines

proc deniedProbe(): tuple[ok: bool, detail: string] = (false, "test: no sandbox")
proc okProbe(): tuple[ok: bool, detail: string] = (true, "test")

proc collect(kinds: var seq[string]; payloads: var seq[JsonNode]): EventSink =
  let kp = addr kinds
  let pp = addr payloads
  result = proc(k: string; p: JsonNode) =
    kp[].add k
    pp[].add p

suite "architectural invariants":
  test "I1 model output is data: an unknown tool name executes nothing":
    let p = newScriptedProvider(@[
      ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "x", name: "rm_everything", args: %*{})]),
      ModelAction(kind: makFinal, text: "ok")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    let r = waitFor runAgent(p, "t", cfgWith(), sink = collect(kinds, ps))
    check "tool.result" notin kinds
    check r.messages[3].content.startsWith("DENIED by registry")

  test "I2 deny dominates allow regardless of layer order":
    let allowAll = PolicyLayer(id: "allow", check: proc(c: ToolCall; cap: Capability;
      e: EffectClass; cfg: AgentConfig): tuple[verdict: Verdict, reason: string] = (vAllow, ""))
    let denyAll = PolicyLayer(id: "deny", check: proc(c: ToolCall; cap: Capability;
      e: EffectClass; cfg: AgentConfig): tuple[verdict: Verdict, reason: string] = (vDeny, "no"))
    let cap = Capability(name: "echo", realm: erInProcess, maxEffect: b0ReadOnly)
    let call = ToolCall(id: "1", name: "echo", args: %*{})
    check compose([allowAll, denyAll], call, cap, b0ReadOnly, baseConfig(), "e").verdict == vDeny
    check compose([denyAll, allowAll], call, cap, b0ReadOnly, baseConfig(), "e").verdict == vDeny

  test "I2b no layer can exceed a capability's effect ceiling":
    let allowAll = PolicyLayer(id: "allow", check: proc(c: ToolCall; cap: Capability;
      e: EffectClass; cfg: AgentConfig): tuple[verdict: Verdict, reason: string] = (vAllow, ""))
    let cap = Capability(name: "x", realm: erSandbox, maxEffect: b2BroadWorkspace)
    let d = compose([allowAll], ToolCall(name: "x", args: %*{}), cap, b3External, baseConfig(), "e")
    check d.verdict == vDeny
    check d.policyId == "capability.ceiling"

  test "I2c an unanswered ASK fails closed":
    let askAll = PolicyLayer(id: "asker", check: proc(c: ToolCall; cap: Capability;
      e: EffectClass; cfg: AgentConfig): tuple[verdict: Verdict, reason: string] = (vAsk, "confirm?"))
    let r = waitFor runAgent(newMockProvider(), "t", cfgWith(), layers = @[askAll])
    check r.messages[3].content.startsWith("DENIED by asker: ASK unanswered")

  test "I5 requested sandbox + unavailable backend = run refused":
    expect ConfinementError:
      discard waitFor runAgent(newMockProvider(), "t", cfgWith(allowShell = true),
                               sandboxProbe = deniedProbe)

  test "I6 sandbox failure never becomes host execution":
    # Registry says sandbox; the probe passes but bwrap vanishes at call time.
    let reg = toolsFor(cfgWith(allowShell = true))
    check reg["shell"].capability.realm == erSandbox
    let savedPath = getEnv("PATH")
    putEnv("PATH", "/nonexistent")
    defer: putEnv("PATH", savedPath)
    let marker = testTmp / "malyutka-i6-marker"
    removeFile(marker)
    let p = newScriptedProvider(@[
      ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "s", name: "shell",
        args: %*{"command": "touch " & marker})]),
      ModelAction(kind: makFinal, text: "done")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    let r = waitFor runAgent(p, "t", cfgWith(allowShell = true), registry = reg, journal = tmpJournal("i6"),
                             sink = collect(kinds, ps), sandboxProbe = okProbe)
    check "confinement.failed" in kinds
    check r.messages[3].content.startsWith("NOT EXECUTED")
    check not fileExists(marker)

  test "I6b host realm exists only with the explicit waiver":
    check toolsFor(cfgWith(true, false))["shell"].capability.realm == erSandbox
    check toolsFor(cfgWith(true, true))["shell"].capability.realm == erHost
    # Defense in depth: even a host-realm capability is denied without the waiver.
    let hostCap = Capability(name: "shell", realm: erHost, maxEffect: b4Privileged)
    let d = compose(defaultLayers(), ToolCall(name: "shell", args: %*{"command": "true"}),
                    hostCap, b4Privileged, cfgWith(true, false), "e")
    check d.verdict == vDeny
    check d.policyId == "confinement"

  test "I6c the waiver is announced in the event stream":
    var kinds: seq[string]; var ps: seq[JsonNode]
    discard waitFor runAgent(newMockProvider(), "t", cfgWith(true, true), sink = collect(kinds, ps))
    check "confinement.waived" in kinds

  test "I7 every side effect links to an authorizing decision event":
    var kinds: seq[string]; var ps: seq[JsonNode]
    discard waitFor runAgent(newMockProvider(), "t", cfgWith(), sink = collect(kinds, ps))
    var decisionIds: seq[string]
    for i, k in kinds:
      if k == "policy.decision": decisionIds.add ps[i]["id"].getStr
      if k == "tool.result": check ps[i]["causedBy"].getStr in decisionIds

  test "I8 every decision names the responsible policy":
    var kinds: seq[string]; var ps: seq[JsonNode]
    discard waitFor runAgent(newMockProvider(), "t", cfgWith(), sink = collect(kinds, ps))
    for i, k in kinds:
      if k == "policy.decision": check ps[i]["policy"].getStr.len > 0

  test "I9 shell children do not inherit harness credentials":
    putEnv("MALYUTKA_API_KEY", "sk-test-secret")
    defer: delEnv("MALYUTKA_API_KEY")
    var c = cfgWith(allowShell = true, unconfined = true)   # host realm: worst case
    c.cwd = testTmp
    let r = toolsFor(c)["shell"].run(%*{"command": "env"}, c)
    check r.ok
    check "sk-test-secret" notin r.output
    check "MALYUTKA" notin r.output

  test "I11 repeated identical calls halt the run":
    var script: seq[ModelAction]
    for i in 0 ..< 6:
      script.add ModelAction(kind: makToolCalls, calls: @[
        ToolCall(id: "c" & $i, name: "echo", args: %*{"text": "same"})])
    let r = waitFor runAgent(newScriptedProvider(script), "t", cfgWith())
    check r.halt == hrRepetition

suite "sandbox broker":
  test "tmpfs /tmp is mounted before the workspace bind":
    let argv = bwrapArgv("/tmp/ws", "true")
    check argv.find("--bind-fd") > 0
    check argv.find("/tmp") < argv.find("--bind-fd")

  test "network is unshared":
    check "--unshare-all" in bwrapArgv("/w", "true")

  let (bwOk, _) = probeBwrap()
  if bwOk:
    test "sandboxed shell: workspace writable, root read-only, no network":
      let ws = testTmp / "malyutka-ws-test"
      createDir(ws)
      defer: removeDir(ws)
      var c = cfgWith(allowShell = true)
      c.cwd = ws
      let shell = toolsFor(c)["shell"]
      check shell.run(%*{"command": "echo hi > out.txt"}, c).ok
      check readFile(ws / "out.txt").strip == "hi"
      check not shell.run(%*{"command": "touch /etc/malyutka-escape"}, c).ok
      check not fileExists("/etc/malyutka-escape")
      let net = shell.run(%*{"command": "getent hosts example.com"}, c)
      check not net.ok

    test "sandboxed shell: timeout and output cap":
      var c = cfgWith(allowShell = true)
      c.shellTimeoutSec = 1
      c.maxOutputBytes = 1000
      let shell = toolsFor(c)["shell"]
      let slow = shell.run(%*{"command": "sleep 5"}, c)
      check slow.timedOut
      let loud = shell.run(%*{"command": "head -c 100000 /dev/zero | tr '\\0' x"}, c)
      check loud.truncated
      check loud.output.len < 1200
  else:
    echo "  [SKIP] live bwrap tests: sandbox probe failed on this host"

suite "write-ahead journal":
  proc touchScript(marker: string): MockProvider =
    newScriptedProvider(@[
      ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "s", name: "shell",
        args: %*{"command": "touch " & quoteShell(marker)})]),
      ModelAction(kind: makFinal, text: "done")])

  proc hostCfg(): AgentConfig =
    # Host realm (waived) so these tests do not depend on bwrap; the journal
    # rules are realm-independent.
    result = cfgWith(allowShell = true, unconfined = true)
    result.cwd = testTmp / "ws"
    createDir(result.cwd)

  test "J1 side-effecting action without a journal is denied, not executed":
    let marker = testTmp / "malyutka-j1"
    removeFile(marker)
    let r = waitFor runAgent(touchScript(marker), "t", hostCfg())
    check r.messages[3].content.startsWith("DENIED by journal")
    check not fileExists(marker)

  test "J2 completed action leaves intent, decision, started, outcome in order":
    let marker = testTmp / "malyutka-j2"
    removeFile(marker)
    let j = tmpJournal("j2")
    discard waitFor runAgent(touchScript(marker), "t", hostCfg(), journal = j)
    check fileExists(marker)
    check recs(j) == @["intent", "decision", "started", "outcome"]
    check unknownOutcomes(j.path).len == 0
    j.close()

  test "J3 intent not durable -> action never runs":
    let marker = testTmp / "malyutka-j3"
    removeFile(marker)
    let j = tmpJournal("j3"); j.failAfter = 0
    let r = waitFor runAgent(touchScript(marker), "t", hostCfg(), journal = j)
    check r.messages[3].content.startsWith("DENIED by journal: intent not durable")
    check not fileExists(marker)
    j.close()

  test "J4 'started' not durable -> action never runs":
    let marker = testTmp / "malyutka-j4"
    removeFile(marker)
    let j = tmpJournal("j4"); j.failAfter = 2   # intent + decision written, started fails
    let r = waitFor runAgent(touchScript(marker), "t", hostCfg(), journal = j)
    check r.messages[3].content.startsWith("DENIED by journal: decision not durable")
    check not fileExists(marker)
    check unknownOutcomes(j.path).len == 0      # never started: NOT_STARTED, not unknown
    j.close()

  test "J5 outcome not durable -> degradation is visible and outcome reported unknown":
    let marker = testTmp / "malyutka-j5"
    removeFile(marker)
    let j = tmpJournal("j5"); j.failAfter = 3   # outcome write fails after execution
    var kinds: seq[string]; var ps: seq[JsonNode]
    let r = waitFor runAgent(touchScript(marker), "t", hostCfg(), journal = j,
                             sink = collect(kinds, ps))
    check fileExists(marker)
    check "journal.degraded" in kinds
    check "outcome not journaled" in r.messages[3].content
    check unknownOutcomes(j.path).len == 1
    j.close()

  test "J6 crash after 'started': UNKNOWN_OUTCOME surfaced on next run, never re-executed":
    var j = tmpJournal("j6")
    j.append(%*{"rec": "intent", "action": "R-0007", "run": "R", "tool": "shell", "args": {"command": "make deploy"}})
    j.append(%*{"rec": "decision", "action": "R-0007", "verdict": "ALLOW"})
    j.append(%*{"rec": "started", "action": "R-0007"})
    # torn final line from a crash mid-write is ignored
    let f = open(j.path, fmAppend); f.write("{\"rec\": \"outco"); f.close()
    j.close()
    j = openJournal(j.path)              # the next process opens it after the crash
    let u = unknownOutcomes(j.path)
    check u.len == 1 and u[0].action == "R-0007" and u[0].state == asUnknownOutcome
    var kinds: seq[string]; var ps: seq[JsonNode]
    discard waitFor runAgent(newMockProvider(), "t", cfgWith(), journal = j, sink = collect(kinds, ps))
    check "journal.unknown_outcome" in kinds
    j.append(%*{"rec": "ack", "action": "R-0007"})
    check unknownOutcomes(j.path).len == 0
    j.close()

  test "J7 read-only (B0) actions are not journaled":
    let j = tmpJournal("j7")
    discard waitFor runAgent(newMockProvider(), "t", cfgWith(), journal = j)
    check getFileSize(j.path) == 0
    j.close()

removeDir(testTmp)

suite "journal integrity (0.3.2)":
  proc linesOf(path: string): seq[string] =
    for l in readFile(path).splitLines:
      if l.strip.len > 0: result.add l

  test "J8 a writer's torn fragment cannot swallow another writer's record":
    # 0.3.1 lost B-2 here: B had the journal open before A crashed mid-write.
    let b = tmpJournal("j8")
    b.append(%*{"rec": "intent", "action": "B-1"})
    let f = open(b.path, fmAppend); f.write("{\"rec\": \"started\", \"act"); f.close()
    b.append(%*{"rec": "intent", "action": "B-2"})
    let scan = scanJournal(b.path)
    var ids: seq[string]
    for a in scan.actions: ids.add a.action
    check "B-2" in ids
    check scan.health == jhTorn
    b.close()

  test "J9 eight concurrent writers: every record intact, no gaps":
    let path = testTmp / "state" / "j9.jsonl"
    removeFile(path)
    var kids: seq[Pid]
    for w in 0 ..< 8:
      let pid = posix.fork()
      if pid == 0:
        let j = openJournal(path, writer = "w" & $w)
        for i in 0 ..< 300:
          j.append(%*{"rec": "intent", "action": "w" & $w & "-" & $i, "pad": repeat('x', 1500)})
        quit(0)
      kids.add pid
    for k in kids:
      var st: cint
      discard posix.waitpid(k, st, 0)
    let scan = scanJournal(path)
    check scan.actions.len == 2400
    check scan.health == jhOk

  test "J10 an altered durable record is CORRUPT, and runs are refused":
    var j = tmpJournal("j10")
    for i in 0 ..< 3: j.append(%*{"rec": "intent", "action": "A-" & $i})
    j.close()
    var ls = linesOf(j.path)
    ls[1] = ls[1].replace("A-1", "A-9")          # parseable, checksum now wrong
    writeFile(j.path, ls.join("\n") & "\n")
    check scanJournal(j.path).health == jhCorrupt
    j = openJournal(j.path)
    expect JournalError:
      discard waitFor runAgent(newMockProvider(), "t", cfgWith(), journal = j)
    j.close()

  test "J11 a deleted durable record is CORRUPT (sequence gap)":
    let j = tmpJournal("j11")
    for i in 0 ..< 4: j.append(%*{"rec": "intent", "action": "G-" & $i})
    j.close()
    var ls = linesOf(j.path)
    ls.delete(1)
    writeFile(j.path, ls.join("\n") & "\n")
    let scan = scanJournal(j.path)
    check scan.health == jhCorrupt
    check "missing" in scan.problems.join(" ")

  test "J12 a torn tail alone is benign (TORN_TAIL), and runs proceed":
    var j = tmpJournal("j12")
    j.append(%*{"rec": "intent", "action": "T-1"})
    j.close()
    let f = open(j.path, fmAppend); f.write("{\"rec\": \"deci"); f.close()
    check scanJournal(j.path).health == jhTorn
    j = openJournal(j.path)
    var kinds: seq[string]; var ps: seq[JsonNode]
    discard waitFor runAgent(newMockProvider(), "t", cfgWith(), journal = j, sink = collect(kinds, ps))
    check "journal.torn" in kinds
    j.close()

  test "J13 journal inside the workspace (or vice versa) is refused":
    let ws = testTmp / "j13ws"
    createDir(ws)
    expect JournalError: checkJournalPlacement(ws / ".state", ws)
    expect JournalError: checkJournalPlacement(testTmp, ws)          # workspace inside state dir
    let link = testTmp / "j13link"                                   # symlink alias to workspace
    removeFile(link); createSymlink(ws, link)
    expect JournalError: checkJournalPlacement(link / "state", ws)
    checkJournalPlacement(testTmp / "state", ws)                     # disjoint: fine
    var c = cfgWith(); c.cwd = ws
    let j = openJournal(ws / ".state" / "journal.jsonl")
    expect JournalError:
      discard waitFor runAgent(newMockProvider(), "t", c, journal = j)
    j.close()

  test "J14 a symlinked or foreign journal file is refused":
    let target = testTmp / "state" / "real.jsonl"
    writeFile(target, "")
    let link = testTmp / "state" / "link.jsonl"
    removeFile(link); createSymlink(target, link)
    expect JournalError: discard openJournal(link)
    if getuid() == 0:
      let foreign = testTmp / "state" / "foreign.jsonl"
      writeFile(foreign, "")
      check posix.chown(cstring(foreign), 65534, 65534) == 0
      expect JournalError: discard openJournal(foreign)

  test "J15 reconcile records the established outcome; ack leaves it unresolved":
    let j = tmpJournal("j15")
    for id in ["R-1", "R-2"]:
      j.append(%*{"rec": "intent", "action": id, "tool": "shell", "args": {}})
      j.append(%*{"rec": "decision", "action": id, "verdict": "ALLOW"})
      j.append(%*{"rec": "started", "action": id})
    j.append(%*{"rec": "reconcile", "action": "R-1", "as": "FAILED"})
    j.append(%*{"rec": "ack", "action": "R-2"})
    var st = initTable[string, ActionSummary]()
    for a in scanJournal(j.path).actions: st[a.action] = a
    check st["R-1"].state == asReconciled
    check st["R-1"].reconciledAs == "FAILED"
    check st["R-2"].state == asAckUnresolved
    check unknownOutcomes(j.path).len == 0
    j.close()

  test "J16 states: denied, authorized-but-never-started, failed are distinguished":
    let j = tmpJournal("j16")
    j.append(%*{"rec": "intent", "action": "D"})
    j.append(%*{"rec": "decision", "action": "D", "verdict": "DENY"})
    j.append(%*{"rec": "intent", "action": "A"})
    j.append(%*{"rec": "decision", "action": "A", "verdict": "ALLOW"})
    j.append(%*{"rec": "intent", "action": "F"})
    j.append(%*{"rec": "decision", "action": "F", "verdict": "ALLOW"})
    j.append(%*{"rec": "started", "action": "F"})
    j.append(%*{"rec": "outcome", "action": "F", "state": "COMPLETED", "ok": false})
    var st = initTable[string, ActionState]()
    for a in scanJournal(j.path).actions: st[a.action] = a.state
    check st["D"] == asDenied
    check st["A"] == asAuthorized
    check st["F"] == asFailed
    j.close()

  test "J17 records with non-ASCII arguments round-trip their checksum":
    let j = tmpJournal("j17")
    j.append(%*{"rec": "intent", "action": "U", "args": {"command": "echo 'Малютка ✓ \"q\" \\ \t'"}})
    check scanJournal(j.path).health == jhOk
    j.close()
