## Guidance loop. The model proposes tool calls; the registry decides whether a
## capability exists; the policy kernel decides whether it may run; the
## sandbox broker decides where. No path executes a call that was not ALLOWed.

import std/[asyncdispatch, json, os, strutils, sysrand, tables, times]
import ./[types, provider, tools, policy, events, sandbox, journal]

type
  HaltReason* = enum hrFinal, hrMaxSteps, hrRepetition
  RunResult* = object
    runId*: string
    answer*: string
    halt*: HaltReason
    messages*: seq[Message]

  SandboxProbe* = proc(): tuple[ok: bool, detail: string] {.closure.}

const SystemPrompt = "You are Malyutka, a small robust agent harness. Prefer simple, " &
  "verifiable actions. Use tools only when useful. Tool calls are checked by " &
  "policy before execution and may be denied."

proc msg(role: Role; content: string): Message =
  Message(role: role, content: content, createdAt: now())

proc toolMsg(callId, name, content: string): Message =
  Message(role: rTool, content: content, name: name, toolCallId: callId, createdAt: now())

proc validateTranscript*(messages: seq[Message]): string =
  ## Tool-protocol state machine. Returns "" when valid, else the first
  ## violation. Rules: every assistant tool call has a non-empty id unique
  ## within its turn; the calls are answered by exactly one tool message each,
  ## before any non-tool message; no tool message answers an unknown call.
  var pending: seq[string]
  for i, m in messages:
    case m.role
    of rAssistant:
      if pending.len > 0: return "message " & $i & ": unanswered calls " & $pending
      for c in m.toolCalls:
        if c.id.len == 0: return "message " & $i & ": tool call without id"
        if c.id in pending: return "message " & $i & ": duplicate call id " & c.id
        pending.add c.id
    of rTool:
      let k = pending.find(m.toolCallId)
      if k < 0: return "message " & $i & ": answers unknown call '" & m.toolCallId & "'"
      pending.delete(k)
    else:
      if pending.len > 0: return "message " & $i & ": unanswered calls " & $pending
  if pending.len > 0: return "end of transcript: unanswered calls " & $pending
  ""

proc newRunId*(): string =
  ## 32 random bits from the OS CSPRNG (std/oids pulled in std/random, whose
  ## compile-time init the Nim 2.2.4 wasm checker cannot evaluate).
  var hex = ""
  for b in urandom(4): hex.add toHex(BiggestInt(b), 2).toLowerAscii
  "9M14-" & hex

proc defaultProbe(): tuple[ok: bool, detail: string] = probeBwrap()

proc runAgent*(p: Provider; task: string; cfg: AgentConfig;
               registry = toolsFor(cfg); layers = defaultLayers();
               sink: EventSink = nullSink; runId = newRunId();
               sandboxProbe: SandboxProbe = defaultProbe;
               journal: Journal = nil): Future[RunResult] {.async.} =
  let em = newEmitter(runId, sink)
  result.runId = runId
  var names = newJArray()
  for n, _ in registry: names.add %n
  discard em.emit("run.start", %*{"provider": p.name, "tools": names,
                           "maxSteps": cfg.maxSteps, "repeatLimit": cfg.repeatLimit})

  # Fail closed before the model acts: a sandboxed capability without a
  # working sandbox aborts the run (invariants 5, 6).
  for n, spec in registry:
    if spec.capability.realm == erSandbox:
      try: openWorkspace(cfg.cwd).close()
      except ConfinementError as e:
        discard em.emit("confinement.failed", %*{"tool": n, "reason": e.msg})
        raise
      let (ok, detail) = sandboxProbe()
      if not ok:
        discard em.emit("confinement.failed", %*{"tool": n, "reason": detail})
        raise newException(ConfinementError,
          "capability '" & n & "' requires a sandbox: " & detail)
    elif spec.capability.realm == erHost:
      discard em.emit("confinement.waived", %*{"tool": n, "ceiling": $spec.capability.maxEffect})

  # Journal preconditions (fail closed): disjoint from the workspace, and no
  # corruption. Actions a previous run started but never recorded the outcome
  # of are surfaced, never re-executed.
  if journal != nil:
    checkJournalPlacement(parentDir(journal.path), cfg.cwd)
    let scan = scanJournal(journal.path)
    if scan.health == jhCorrupt:
      discard em.emit("journal.corrupt", %*{"problems": scan.problems})
      raise newException(JournalError, "journal is corrupt (" & scan.problems.join("; ") &
        "); inspect it with `malyutka journal` before running again")
    if scan.tornLines.len > 0:
      discard em.emit("journal.torn", %*{"lines": scan.tornLines})
    for a in unknownOutcomes(scan):
      discard em.emit("journal.unknown_outcome", %*{"action": a.action, "run": a.run,
        "tool": a.tool, "args": a.args, "startedAt": a.startedAt})

  let schemas = wireSchemas(registry)
  result.messages = @[msg(rSystem, SystemPrompt), msg(rUser, task)]
  var lastSig = ""
  var repeats = 0
  var idSeq = 0

  for step in 0 ..< cfg.maxSteps:
    discard em.emit("step.start", %*{"step": step})
    let action = await p.next(result.messages, schemas)
    if action.kind == makFinal:
      result.messages.add msg(rAssistant, action.text)
      discard em.emit("agent.final", %*{"step": step, "text": action.text})
      result.answer = action.text
      result.halt = hrFinal
      return

    # Normalize call ids: unique within the turn, whatever the provider sent.
    var calls = action.calls
    var seenIds: seq[string]
    for c in calls.mitems:
      if c.id.len == 0 or c.id in seenIds:
        inc idSeq
        c.id = runId & "-call-" & $idSeq
      seenIds.add c.id
      if c.args.isNil: c.args = newJObject()

    var asst = msg(rAssistant, action.text)
    asst.toolCalls = calls
    result.messages.add asst

    for ci, call in calls:
      let proposedId = em.emit("tool.proposed",
        %*{"callId": call.id, "name": call.name, "args": call.args})

      # Generalized doom_loop (invariant 11): the same call repeated
      # repeatLimit times in a row halts the run without executing it.
      let sig = call.name & "\x1f" & $call.args
      if sig == lastSig: inc repeats else: (lastSig = sig; repeats = 1)
      if cfg.repeatLimit > 0 and repeats >= cfg.repeatLimit:
        let why = "identical call '" & call.name & "' proposed " & $repeats & " times consecutively"
        # Protocol completeness: every call in this turn, including the one
        # that tripped the halt, receives exactly one terminal result.
        for rest in calls[ci .. ^1]:
          discard em.emit("tool.cancelled", %*{"callId": rest.id, "name": rest.name,
            "reason": "run halted: repetition"})
          result.messages.add toolMsg(rest.id, rest.name, "CANCELLED: run halted (" & why & ")")
        discard em.emit("agent.halt", %*{"reason": "repetition", "detail": why, "causedBy": proposedId})
        result.answer = "Halted: " & why
        result.halt = hrRepetition
        result.messages.add msg(rAssistant, result.answer)
        return

      let decisionId = em.nextId()
      var d: Decision
      var journaled = false
      if not registry.hasKey(call.name):
        d = Decision(eventId: decisionId, verdict: vDeny, effect: b0ReadOnly,
                     policyId: "registry", reason: "no such capability: " & call.name)
      else:
        let spec = registry[call.name]
        let effect = spec.effectOf(call.args)
        # Write-ahead: a side-effecting action's intent is durable before it
        # is even authorized; no durable intent, no action.
        var intentErr = ""
        if effect > b0ReadOnly:
          if journal == nil:
            intentErr = "side-effecting action requires a durable journal; none attached"
          else:
            try:
              journal.append(%*{"rec": "intent", "action": decisionId, "run": runId,
                "callId": call.id, "tool": call.name, "args": call.args, "effect": $effect})
              journaled = true
            except JournalError as e:
              intentErr = "intent not durable: " & e.msg
        if intentErr.len > 0:
          d = Decision(eventId: decisionId, verdict: vDeny, effect: effect,
                       policyId: "journal", reason: intentErr)
        else:
          d = compose(layers, call, spec.capability, effect, cfg, decisionId)
      if d.verdict == vAsk:
        # No approver is attached in M1.x: an unanswered ASK fails closed.
        d.verdict = vDeny
        d.reason = "ASK unanswered (no approver attached): " & d.reason
      if journaled:
        try:
          journal.append(%*{"rec": "decision", "action": decisionId,
            "verdict": $d.verdict, "policy": d.policyId, "reason": d.reason})
          if d.verdict == vAllow:
            journal.append(%*{"rec": "started", "action": decisionId})
        except JournalError as e:
          if d.verdict == vAllow:
            d = Decision(eventId: decisionId, verdict: vDeny, effect: d.effect,
                         policyId: "journal", reason: "decision not durable: " & e.msg)
      discard em.emit("policy.decision", %*{"verdict": $d.verdict, "effect": $d.effect,
        "policy": d.policyId, "reason": d.reason, "causedBy": proposedId}, id = d.eventId)

      if d.verdict != vAllow:
        result.messages.add toolMsg(call.id, call.name,
          "DENIED by " & d.policyId & ": " & d.reason)
        continue

      var r: ToolResult
      var executed = true
      try:
        r = registry[call.name].run(call.args, cfg)
      except ConfinementError as e:
        executed = false
        # Never retried on the host (invariant 6).
        discard em.emit("confinement.failed", %*{"tool": call.name, "reason": e.msg, "causedBy": d.eventId})
        r = ToolResult(ok: false, output: "NOT EXECUTED: confinement unavailable: " & e.msg, exitCode: -1)
      except CatchableError as e:
        r = ToolResult(ok: false, output: "ERROR: " & e.msg, exitCode: -1)
      discard em.emit("tool.result", %*{"name": call.name, "ok": r.ok, "exitCode": r.exitCode,
        "truncated": r.truncated, "timedOut": r.timedOut, "bytes": r.output.len,
        "causedBy": d.eventId})
      if journaled:
        try:
          journal.append(%*{"rec": "outcome", "action": decisionId,
            "state": (if executed: "COMPLETED" else: "NOT_EXECUTED"),
            "ok": r.ok, "exitCode": r.exitCode, "truncated": r.truncated, "timedOut": r.timedOut})
        except JournalError as e:
          # The action ran but its outcome is not durable: the journal will
          # (correctly) report UNKNOWN_OUTCOME. Make the degradation visible.
          discard em.emit("journal.degraded", %*{"action": decisionId, "reason": e.msg})
          r.output.add "\n[malyutka: outcome not journaled: " & e.msg & "]"
      result.messages.add toolMsg(call.id, call.name, r.output)

  result.answer = "Stopped: maxSteps reached"
  result.halt = hrMaxSteps
  result.messages.add msg(rAssistant, result.answer)
  discard em.emit("agent.halt", %*{"reason": "maxSteps"})
