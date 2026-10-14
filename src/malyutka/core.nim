## Guidance loop. The model proposes tool calls; the registry decides whether a
## capability exists; the policy kernel decides whether it may run; the
## sandbox broker decides where. No path executes a call that was not ALLOWed.

import std/[asyncdispatch, json, os, strutils, sysrand, tables, times]
import ./[types, provider, tools, policy, events, sandbox, journal, approval, memory, latch, compact]

type
  HaltReason* = enum hrFinal, hrMaxSteps, hrRepetition, hrContext
  RunResult* = object
    runId*: string
    answer*: string
    halt*: HaltReason
    messages*: seq[Message]

  SandboxProbe* = proc(): tuple[ok: bool, detail: string] {.closure.}
  Checkpoint* = proc(messages: seq[Message]; status: string) {.closure.}
  ArchiveProc* = proc(dropped: seq[Message]) {.closure.}

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
               journal: Journal = nil;
               approver: Approver = nil;
               latch: LatchStore = nil;
               history: seq[Message] = @[];
               checkpoint: Checkpoint = nil;
               archive: ArchiveProc = nil): Future[RunResult] {.async.} =
  let em = newEmitter(runId, sink)
  result.runId = runId
  var names = newJArray()
  for n, _ in registry: names.add %n
  discard em.emit("run.start", %*{"schema": "events/2", "provider": p.name, "tools": names,
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
    for a in ownerUnknown(scan):
      discard em.emit("journal.owner_unknown", %*{"action": a.action, "run": a.run,
        "tool": a.tool, "args": a.args, "startedAt": a.startedAt})
    for a in unknownOutcomes(scan):
      discard em.emit("journal.unknown_outcome", %*{"action": a.action, "run": a.run,
        "tool": a.tool, "args": a.args, "startedAt": a.startedAt})

  # Mandate log preconditions (fail closed, invariant L3): disjoint from the
  # workspace and not corrupt. Without a latch attached, every ASK fails closed.
  if latch != nil:
    checkLatchPlacement(latch.path, cfg.cwd)
    let ls = latch.scan()
    if ls.health == lhCorrupt:
      discard em.emit("mandate.corrupt", %*{"problems": ls.problems})
      raise newException(LatchError, "mandate log is corrupt (" & ls.problems.join("; ") &
        "); inspect it with `malyutka mandate` before running again")
    let now = latch.clock()
    var active = newJArray()
    for m in ls.mandates:
      let st = m.effectiveState(now)
      if st in {msLatched, msSuspended, msProposed}:
        active.add %*{"mandate": m.id, "state": $st, "goal": m.goal, "tools": m.tools,
          "maxEffect": $m.maxEffect, "used": m.used, "maxActions": m.maxActions}
    discard em.emit("mandate.status", %*{"mandates": active})

  let schemas = wireSchemas(registry)
  let sys = msg(rSystem, buildSystemPrompt(cfg))
  if history.len > 0:
    # Resume (invariant 15): history only rebuilds the message list. Nothing in
    # it is replayed; its tool calls and results are inert text.
    let bad = validateTranscript(history)
    if bad.len > 0: raise newException(ValueError, "cannot resume: " & bad)
    result.messages = history
    if result.messages[0].role == rSystem: result.messages[0] = sys
    else: result.messages.insert(sys, 0)
    result.messages.add msg(rUser, task)
  else:
    result.messages = @[sys, msg(rUser, task)]

  proc save(status: string) =
    if checkpoint == nil: return
    try:
      checkpoint(result.messages, status)
      discard em.emit("session.saved", %*{"status": status, "messages": result.messages.len})
    except CatchableError as e:
      discard em.emit("session.failed", %*{"reason": e.msg})
  save("running")
  var lastSig = ""
  var repeats = 0
  var idSeq = 0
  var missStreak = 0    # consecutive ASKs no latched mandate covered

  for step in 0 ..< cfg.maxSteps:
    discard em.emit("step.start", %*{"step": step})
    if cfg.contextWindow > 0:
      # Invariant 10: compaction is observable (event + archive written BEFORE the
      # messages leave the prompt) and never silent. Every failure continues
      # uncompacted; only an overflow of the whole window halts.
      let forced = cfg.compressNow and step == 0
      let before = estimateTokens(result.messages)
      let pl = plan(result.messages, cfg.contextWindow, forced)
      if pl.ok:
        var failure = ""
        var summary = ""
        try: summary = await summarize(p, pl.p.dropped)
        except CatchableError as e: failure = "summariser: " & e.msg
        if failure.len == 0 and summary.strip.len == 0: failure = "empty summary"
        var candidate: seq[Message]
        if failure.len == 0:
          candidate = apply(result.messages, pl.p, summary)
          if validateTranscript(candidate).len > 0: failure = "invalid transcript after compaction"
          elif estimateTokens(candidate) >= before: failure = "no progress"
        if failure.len == 0:
          try:
            if archive == nil: raise newException(IOError, "no archive attached")
            archive(pl.p.dropped)
          except CatchableError as e: failure = "archive: " & e.msg
        if failure.len == 0:
          result.messages = candidate
          discard em.emit("context.compacted", %*{"dropped": pl.p.dropped.len,
            "kept": candidate.len, "tokensBefore": before,
            "tokensAfter": estimateTokens(candidate), "archived": true})
          save("running")
        else:
          discard em.emit("context.compaction_failed", %*{"reason": failure})
      elif forced:
        discard em.emit("context.compaction_failed", %*{"reason": pl.why})
      if estimateTokens(result.messages) > cfg.contextWindow:
        let why = "estimated " & $estimateTokens(result.messages) & " tokens exceed the " &
          $cfg.contextWindow & "-token context window and compaction could not help"
        discard em.emit("agent.halt", %*{"reason": "context", "detail": why})
        result.answer = "Halted: " & why
        result.halt = hrContext
        result.messages.add msg(rAssistant, result.answer)
        save("halted")
        return
    let action = await p.next(result.messages, schemas)
    if action.kind == makFinal:
      result.messages.add msg(rAssistant, action.text)
      discard em.emit("agent.final", %*{"step": step, "text": action.text})
      result.answer = action.text
      result.halt = hrFinal
      save("answered")
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
        save("halted")
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
      # Commitment latch: a latched mandate may resolve an ASK, and nothing
      # else. DENY and ALLOW never reach it (invariant L2).
      if d.verdict == vAsk and latch != nil:
        let u = latch.tryUse(call.name, d.effect, runId, decisionId)
        if u.mandate.len > 0:
          missStreak = 0
          d = Decision(eventId: decisionId, verdict: vAllow, effect: d.effect,
            policyId: "mandate:" & u.mandate,
            reason: "within latched mandate (" & $u.used & "/" & $u.maxActions & "): " & u.goal)
          discard em.emit("mandate.used", %*{"mandate": u.mandate, "used": u.used,
            "maxActions": u.maxActions, "action": decisionId, "causedBy": proposedId})
        elif u.error.len > 0:
          d.reason = "mandate use not durable (" & u.error & "); " & d.reason
          discard em.emit("mandate.error", %*{"reason": u.error, "causedBy": proposedId})
        elif u.anyLatched:
          # Deviation: the model keeps proposing what no latched mandate covers.
          inc missStreak
          discard em.emit("mandate.miss", %*{"tool": call.name, "effect": $d.effect,
            "streak": missStreak, "causedBy": proposedId})
          if cfg.scopeMissLimit > 0 and missStreak >= cfg.scopeMissLimit:
            let why = $missStreak & " consecutive calls outside every latched mandate"
            var ids: seq[string]
            var err = ""
            try: ids = latch.suspendLatched(why, "harness:" & runId)
            except LatchError as e: err = e.msg
            var idsJ = newJArray()
            for x in ids: idsJ.add %x
            discard em.emit("mandate.suspended", %*{"mandates": idsJ, "reason": why,
              "error": err, "causedBy": proposedId})
            missStreak = 0
      if d.verdict == vAsk:
        # No mandate resolved it. Invariant 14: this is the ONLY place an approver is
        # consulted, and it only ever sees ASK. A DENY from any layer never reaches it.
        if approver == nil:
          d.verdict = vDeny
          d.reason = "ASK unanswered (no approver attached): " & d.reason
        else:
          let req = ApprovalRequest(action: decisionId, tool: call.name,
            args: call.args, reason: d.reason, policy: d.policyId)
          var reply = ApprovalReply(answer: aaDeny, source: "error")
          try: reply = approver(req, em)
          except CatchableError as e: reply.source = "error: " & e.msg
          discard em.emit("approval.answer", %*{"action": decisionId,
            "answer": $reply.answer, "source": reply.source, "causedBy": proposedId})
          let asked = d.policyId & ": " & d.reason
          d.policyId = "approval.user"
          if reply.answer == aaDeny:
            d.verdict = vDeny
            d.reason = "denied (" & reply.source & "); asked by " & asked
          else:
            d.verdict = vAllow
            d.reason = "approved " & $reply.answer & " (" & reply.source & "); asked by " & asked
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
        "causedBy": d.eventId, "preview": r.preview})
      if r.eventKind.len > 0:
        discard em.emit(r.eventKind, r.eventPayload)
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
    save("running")

  result.answer = "Stopped: maxSteps reached"
  result.halt = hrMaxSteps
  result.messages.add msg(rAssistant, result.answer)
  discard em.emit("agent.halt", %*{"reason": "maxSteps"})
  save("halted")
