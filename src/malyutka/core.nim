## Guidance loop. The model proposes tool calls; the registry decides whether a
## capability exists; the policy kernel decides whether it may run; the
## sandbox broker decides where. No path executes a call that was not ALLOWed.

import std/[asyncdispatch, json, oids, tables, times]
import ./[types, provider, tools, policy, events, sandbox]

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

proc newRunId*(): string = "9M14-" & ($genOid())[^8 .. ^1]

proc defaultProbe(): tuple[ok: bool, detail: string] = probeBwrap()

proc runAgent*(p: Provider; task: string; cfg: AgentConfig;
               registry = toolsFor(cfg); layers = defaultLayers();
               sink: EventSink = nullSink; runId = newRunId();
               sandboxProbe: SandboxProbe = defaultProbe): Future[RunResult] {.async.} =
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
      let (ok, detail) = sandboxProbe()
      if not ok:
        discard em.emit("confinement.failed", %*{"tool": n, "reason": detail})
        raise newException(ConfinementError,
          "capability '" & n & "' requires a sandbox: " & detail)
    elif spec.capability.realm == erHost:
      discard em.emit("confinement.waived", %*{"tool": n, "ceiling": $spec.capability.maxEffect})

  let schemas = wireSchemas(registry)
  result.messages = @[msg(rSystem, SystemPrompt), msg(rUser, task)]
  var lastSig = ""
  var repeats = 0

  for step in 0 ..< cfg.maxSteps:
    discard em.emit("step.start", %*{"step": step})
    let action = await p.next(result.messages, schemas)
    if action.kind == makFinal:
      result.messages.add msg(rAssistant, action.text)
      discard em.emit("agent.final", %*{"step": step, "text": action.text})
      result.answer = action.text
      result.halt = hrFinal
      return

    var asst = msg(rAssistant, action.text)
    asst.toolCalls = action.calls
    result.messages.add asst

    for call in action.calls:
      let proposedId = em.emit("tool.proposed",
        %*{"callId": call.id, "name": call.name, "args": call.args})

      # Generalized doom_loop (invariant 11): the same call repeated
      # repeatLimit times in a row halts the run without executing it.
      let sig = call.name & "\x1f" & $call.args
      if sig == lastSig: inc repeats else: (lastSig = sig; repeats = 1)
      if cfg.repeatLimit > 0 and repeats >= cfg.repeatLimit:
        let why = "identical call '" & call.name & "' proposed " & $repeats & " times consecutively"
        discard em.emit("agent.halt", %*{"reason": "repetition", "detail": why, "causedBy": proposedId})
        result.answer = "Halted: " & why
        result.halt = hrRepetition
        result.messages.add msg(rAssistant, result.answer)
        return

      let decisionId = em.nextId()
      var d: Decision
      if not registry.hasKey(call.name):
        d = Decision(eventId: decisionId, verdict: vDeny, effect: b0ReadOnly,
                     policyId: "registry", reason: "no such capability: " & call.name)
      else:
        let spec = registry[call.name]
        d = compose(layers, call, spec.capability, spec.effectOf(call.args), cfg, decisionId)
      if d.verdict == vAsk:
        # No approver is attached in M1.x: an unanswered ASK fails closed.
        d.verdict = vDeny
        d.reason = "ASK unanswered (no approver attached): " & d.reason
      discard em.emit("policy.decision", %*{"verdict": $d.verdict, "effect": $d.effect,
        "policy": d.policyId, "reason": d.reason, "causedBy": proposedId}, id = d.eventId)

      if d.verdict != vAllow:
        result.messages.add toolMsg(call.id, call.name,
          "DENIED by " & d.policyId & ": " & d.reason)
        continue

      var r: ToolResult
      try:
        r = registry[call.name].run(call.args, cfg)
      except ConfinementError as e:
        # Never retried on the host (invariant 6).
        discard em.emit("confinement.failed", %*{"tool": call.name, "reason": e.msg, "causedBy": d.eventId})
        r = ToolResult(ok: false, output: "NOT EXECUTED: confinement unavailable: " & e.msg, exitCode: -1)
      except CatchableError as e:
        r = ToolResult(ok: false, output: "ERROR: " & e.msg, exitCode: -1)
      discard em.emit("tool.result", %*{"name": call.name, "ok": r.ok, "exitCode": r.exitCode,
        "truncated": r.truncated, "timedOut": r.timedOut, "bytes": r.output.len,
        "causedBy": d.eventId})
      result.messages.add toolMsg(call.id, call.name, r.output)

  result.answer = "Stopped: maxSteps reached"
  result.halt = hrMaxSteps
  result.messages.add msg(rAssistant, result.answer)
  discard em.emit("agent.halt", %*{"reason": "maxSteps"})
