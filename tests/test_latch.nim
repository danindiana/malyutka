## Commitment latch (latch.nim). Test names start with the latch invariant
## they pin (L1-L5, see ARCHITECTURE.md), so a failure reads as a broken
## invariant. Each was mutation-checked: removing the defense makes it fail.

import std/[asyncdispatch, json, os, strutils, tables, unittest]
import malyutka/[types, provider, core, policy, tools, journal, latch]

let testTmp = getTempDir() / ("malyutka-latch-" & $getCurrentProcessId())
createDir(testTmp)

var fakeNow = 1_000_000.0
proc fakeClock(): float = fakeNow

proc store(name: string): LatchStore =
  let p = testTmp / "state" / (name & ".mandates.jsonl")
  removeFile(p)
  newLatchStore(p, fakeClock)

proc tmpJournal(name: string): Journal =
  let p = testTmp / "state" / (name & ".journal.jsonl")
  removeFile(p)
  openJournal(p)

proc cfgAsk(askFrom = b1LocalReversible; missLimit = 3): AgentConfig =
  result = baseConfig()
  result.cwd = testTmp / "ws"
  createDir(result.cwd)
  result.askEnabled = true
  result.askFrom = askFrom
  result.mandates = true
  result.scopeMissLimit = missLimit

proc fakeSpec(name: string; effect: EffectClass; ceiling = b2BroadWorkspace;
              onRun: proc() = nil): ToolSpec =
  ## In-process stand-in with a chosen effect class: no sandbox needed.
  ToolSpec(capability: Capability(name: name, realm: erInProcess, maxEffect: ceiling),
    description: "test tool", parameters: %*{"type": "object"},
    effectOf: proc(args: JsonNode): EffectClass = effect,
    run: proc(args: JsonNode; cfg: AgentConfig): ToolResult =
      if onRun != nil: onRun()
      ToolResult(ok: true, output: "ran " & name, exitCode: 0))

proc calls(names: varargs[string]): seq[ModelAction] =
  var i = 0
  for n in names:
    inc i
    result.add ModelAction(kind: makToolCalls,
      calls: @[ToolCall(id: "c" & $i, name: n, args: %*{"i": i})])
  result.add ModelAction(kind: makFinal, text: "done")

proc toolOutputs(r: RunResult): seq[string] =
  for m in r.messages:
    if m.role == rTool: result.add m.content

proc grantScope(tools: seq[string]; eff = b1LocalReversible; actions = 10; ttl = 600): JsonNode =
  scopeJson("test goal", tools, eff, actions, ttl)

proc runWith(s: LatchStore; reg: ToolRegistry; script: seq[ModelAction];
             cfg = cfgAsk(); layers = defaultLayers(); j: Journal = nil): RunResult =
  let jj = if j != nil: j else: tmpJournal("run-" & $getCurrentProcessId())
  waitFor runAgent(newScriptedProvider(script), "t", cfg, registry = reg,
                   layers = layers, journal = jj, latch = s)

proc reg(specs: varargs[ToolSpec]): ToolRegistry =
  result = initOrderedTable[string, ToolSpec]()
  for sp in specs: result[sp.capability.name] = sp

suite "commitment latch":
  setup:
    fakeNow = 1_000_000.0

  test "baseline: without --ask-from nothing asks, so behaviour is unchanged":
    var cfg = cfgAsk()
    cfg.askEnabled = false
    let r = runWith(nil, reg(fakeSpec("w", b1LocalReversible)), calls("w"), cfg)
    check r.toolOutputs == @["ran w"]

  test "baseline: an ASK with no mandate fails closed":
    let s = store("nomandate")
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"))
    check r.toolOutputs[0].startsWith("DENIED by approval: ASK unanswered")

  test "a latched mandate resolves a covered ASK":
    let s = store("covered")
    let m = s.grant(grantScope(@["w"]), "operator:test")
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w", "w"))
    check r.toolOutputs == @["ran w", "ran w"]
    check s.scan().mandates[0].used == 2
    check m.id.startsWith("M-")

  test "L1 a proposal alone authorizes nothing":
    let s = store("l1-proposal")
    discard s.propose(grantScope(@["w"]), by = "model:run1")
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"))
    check r.toolOutputs[0].startsWith("DENIED by approval")

  test "L1 the model cannot approve or resume":
    let s = store("l1-model")
    let m = s.propose(grantScope(@["w"]), by = "model:run1")
    expect LatchError: discard s.approve(m.id, "model:run1")
    expect LatchError: discard s.approve(m.id, "")
    check s.scan().mandates[0].recorded == msProposed

  test "L1 approval is bound to the digest the operator reviewed":
    let s = store("l1-digest")
    let m = s.propose(grantScope(@["w"]), by = "model:run1")
    expect LatchError: discard s.approve(m.id, "operator:t", expectDigest = "00000000")
    check s.approve(m.id, "operator:t", expectDigest = m.digest).recorded == msLatched

  test "L1 a forged approval record (model identity or wrong digest) is corruption":
    for forged in ["model:x", "operator:x|baddigest"]:
      let s = store("l1-forge")
      let m = s.propose(grantScope(@["w"]), by = "model:run1")
      let parts = forged.split('|')
      let dg = if parts.len > 1: parts[1] else: m.digest
      # Append directly, bypassing approve(), with a valid chain and CRC.
      discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
        @[%*{"rec": "approve", "mandate": m.id, "by": parts[0], "digest": dg}])
      check s.scan().health == lhCorrupt

  test "L2 a mandate never overrides a DENY":
    let s = store("l2-deny")
    discard s.grant(grantScope(@["w"]), "operator:t")
    let denyAll = PolicyLayer(id: "deny", check: proc(c: ToolCall; cap: Capability;
      e: EffectClass; cfg: AgentConfig): tuple[verdict: Verdict, reason: string] = (vDeny, "no"))
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"),
                    layers = defaultLayers() & @[denyAll])
    check r.toolOutputs[0].startsWith("DENIED by deny")
    check s.scan().mandates[0].used == 0

  test "L2 a mandate never allows above its own maxEffect or another tool":
    let s = store("l2-scope")
    discard s.grant(grantScope(@["w"], eff = b1LocalReversible), "operator:t")
    let r = runWith(s, reg(fakeSpec("w", b2BroadWorkspace), fakeSpec("x", b1LocalReversible)),
                    calls("w", "x"), cfgAsk(missLimit = 0))
    check r.toolOutputs[0].startsWith("DENIED by approval")
    check r.toolOutputs[1].startsWith("DENIED by approval")
    check s.scan().mandates[0].used == 0

  test "L2 a mandate never lifts an action above the capability ceiling":
    let s = store("l2-ceiling")
    discard s.grant(grantScope(@["w"], eff = b4Privileged), "operator:t")
    let r = runWith(s, reg(fakeSpec("w", b3External, ceiling = b2BroadWorkspace)), calls("w"))
    check r.toolOutputs[0].startsWith("DENIED by capability.ceiling")
    check s.scan().mandates[0].used == 0

  test "L3 a mandate log inside the workspace refuses the run":
    let cfg = cfgAsk()
    let s = newLatchStore(cfg.cwd / "state" / "mandates.jsonl", fakeClock)
    expect LatchError:
      discard runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"), cfg)

  test "L3 an edited scope is detected and refuses the run":
    let s = store("l3-edit")
    discard s.grant(grantScope(@["w"], actions = 1), "operator:t")
    # Raise the budget and recompute that record's CRC: the approval digest
    # and the chain both no longer match.
    var lines: seq[string]
    for line in readFile(s.path).splitLines:
      if line.strip.len == 0: continue
      var r = parseJson(line)
      if r["rec"].getStr == "propose":
        r["scope"]["maxActions"] = %1000
        r.delete("crc")
        r["crc"] = %crc32($r)
      lines.add $r
    writeFile(s.path, "\n" & lines.join("\n\n") & "\n")
    check s.scan().health == lhCorrupt
    expect LatchError:
      discard runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"))

  test "L3 a deleted record breaks the chain":
    let s = store("l3-delete")
    discard s.grant(grantScope(@["w"]), "operator:t")
    discard runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w", "w"))
    var kept: seq[string]
    var dropped = false
    for line in readFile(s.path).splitLines:
      if line.strip.len == 0: continue
      if not dropped and parseJson(line)["rec"].getStr == "use":
        dropped = true; continue          # erase one use to win back budget
      kept.add line
    writeFile(s.path, "\n" & kept.join("\n\n") & "\n")
    check s.scan().health == lhCorrupt

  test "L4 revoke takes effect before the next policy decision, without approval":
    let s = store("l4-revoke")
    let m = s.grant(grantScope(@["w"]), "operator:t")
    let revoker = fakeSpec("w", b1LocalReversible, onRun = proc() =
      s.revoke(m.id, "test", "anyone"))
    let r = runWith(s, reg(revoker), calls("w", "w"))
    check r.toolOutputs[0] == "ran w"
    check r.toolOutputs[1].startsWith("DENIED by approval")

  test "L4 a streak of uncovered ASKs suspends the latch":
    let s = store("l4-deviation")
    let m = s.grant(grantScope(@["w"]), "operator:t")
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible), fakeSpec("x", b1LocalReversible)),
                    calls("x", "x", "x", "w"), cfgAsk(missLimit = 3))
    check s.scan().mandates[0].recorded == msSuspended
    check r.toolOutputs[3].startsWith("DENIED by approval")
    # Only the operator can resume it.
    s.resume(m.id, "operator:t")
    check s.scan().mandates[0].effectiveState(fakeNow) == msLatched

  test "L5 every mandate-authorized action names its mandate in journal and log":
    let s = store("l5")
    let m = s.grant(grantScope(@["w"]), "operator:t")
    let j = tmpJournal("l5")
    discard runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"), j = j)
    var decisionAction = ""
    for line in lines(j.path):
      if line.strip.len == 0: continue
      let r = parseJson(line)
      if r["rec"].getStr == "decision":
        check r["policy"].getStr == "mandate:" & m.id
        check r["verdict"].getStr == "ALLOW"
        decisionAction = r["action"].getStr
    var useAction = ""
    for line in readFile(s.path).splitLines:
      if line.strip.len == 0: continue
      let r = parseJson(line)
      if r["rec"].getStr == "use": useAction = r["action"].getStr
    check decisionAction.len > 0
    check useAction == decisionAction

  test "budget: maxActions uses, then EXHAUSTED":
    let s = store("budget")
    discard s.grant(grantScope(@["w"], actions = 2), "operator:t")
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w", "w", "w"))
    check r.toolOutputs[0] == "ran w"
    check r.toolOutputs[1] == "ran w"
    check r.toolOutputs[2].startsWith("DENIED by approval")
    check s.scan().mandates[0].effectiveState(fakeNow) == msExhausted

  test "TTL: an expired mandate authorizes nothing":
    let s = store("ttl")
    discard s.grant(grantScope(@["w"], ttl = 60), "operator:t")
    fakeNow += 61
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"))
    check r.toolOutputs[0].startsWith("DENIED by approval")
    check s.scan().mandates[0].effectiveState(fakeNow) == msExpired

  test "write-ahead: a use that cannot be made durable authorizes nothing":
    let s = store("durable")
    discard s.grant(grantScope(@["w"]), "operator:t")
    s.failAppend = true
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"))
    check r.toolOutputs[0].startsWith("DENIED by approval")
    check "not durable" in r.toolOutputs[0]

  test "propose_mandate: the model drafts, the operator latches":
    let s = store("propose-tool")
    let script = @[
      ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "p", name: "propose_mandate",
        args: %*{"goal": "tidy", "tools": ["w"], "max_effect": "B1",
                 "max_actions": 5, "ttl_sec": 300})]),
      ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "c", name: "w", args: %*{})]),
      ModelAction(kind: makFinal, text: "done")]
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible), proposeMandateSpec(s, "run1")), script)
    check r.toolOutputs[0].startsWith("PROPOSED M-")
    check r.toolOutputs[1].startsWith("DENIED by approval")
    let m = s.scan().mandates[0]
    check m.proposedBy == "model:run1"
    discard s.approve(m.id, "operator:t", expectDigest = m.digest)
    let r2 = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"))
    check r2.toolOutputs[0] == "ran w"

  test "propose_mandate rejects wildcard and self-referential scopes":
    let s = store("propose-bad")
    let spec = proposeMandateSpec(s, "run1")
    for tools in [%["*"], %["propose_mandate"], newJArray()]:
      let res = spec.run(%*{"goal": "g", "tools": tools, "max_effect": "B1",
                             "max_actions": 1, "ttl_sec": 10}, baseConfig())
      check not res.ok
    check s.scan().mandates.len == 0

  test "a torn tail is benign; a corrupt log refuses writes":
    let s = store("torn")
    let m = s.grant(grantScope(@["w"]), "operator:t")
    let f = open(s.path, fmAppend)
    f.write("\n{\"rec\":\"use\",\"mand")      # crash mid-write
    f.close()
    check s.scan().health == lhTorn
    let r = runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w"))
    check r.toolOutputs[0] == "ran w"
    writeFile(s.path, readFile(s.path).replace("\"test goal\"", "\"other goal\""))
    check s.scan().health == lhCorrupt
    expect LatchError: s.revoke(m.id, "x", "y")

  test "L3 a rewritten earlier record breaks the chain even with a valid CRC":
    let s = store("l3-rewrite")
    discard s.grant(grantScope(@["w"]), "operator:t")
    discard runWith(s, reg(fakeSpec("w", b1LocalReversible)), calls("w", "w"))
    var outLines: seq[string]
    var done = false
    for line in readFile(s.path).splitLines:
      if line.strip.len == 0: continue
      var r = parseJson(line)
      if not done and r["rec"].getStr == "use":
        r["action"] = %"forged-action"     # attribute the use elsewhere
        r.delete("crc")
        r["crc"] = %crc32($r)
        done = true
      outLines.add $r
    writeFile(s.path, "\n" & outLines.join("\n\n") & "\n")
    check s.scan().health == lhCorrupt

  test "L4 a use recorded after revocation is corruption":
    let s = store("l4-forged-use")
    let m = s.grant(grantScope(@["w"]), "operator:t")
    s.revoke(m.id, "stop", "anyone")
    discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
      @[%*{"rec": "use", "mandate": m.id, "by": "run:x", "run": "x", "action": "a"}])
    check s.scan().health == lhCorrupt

  test "L1 the model cannot resume a suspended mandate, directly or by forged record":
    let s = store("l1-resume")
    let m = s.grant(grantScope(@["w"]), "operator:t")
    check s.suspendLatched("test", "harness:x") == @[m.id]
    expect LatchError: s.resume(m.id, "model:run1")
    check s.scan().mandates[0].recorded == msSuspended
    discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
      @[%*{"rec": "resume", "mandate": m.id, "by": "model:run1"}])
    check s.scan().health == lhCorrupt

  test "L1 a proposal whose digest does not match its scope is corruption":
    let s = store("l1-propose-digest")
    let scope = grantScope(@["w"])
    discard s.transact(proc(sc: LatchScan; now: float): seq[JsonNode] =
      @[%*{"rec": "propose", "mandate": "M-forged", "by": "operator:t",
           "scope": scope, "digest": "00000000"}])
    check s.scan().health == lhCorrupt
