import std/[asyncdispatch, json, tables, times]
import ./[types, provider, tools, policy, events]

proc msg(role: Role; content: string; name = ""): Message =
  Message(role: role, content: content, name: name, createdAt: now())

proc runAgent*(p: Provider; task: string; cfg: AgentConfig;
               registry = defaultTools(); sink: EventSink = jsonlSink): Future[tuple[answer: string, messages: seq[Message]]] {.async.} =
  var messages = @[msg(rSystem, "You are Malyutka, a small robust typed agent harness. Prefer simple, verifiable actions. Use tools only when useful."),
                   msg(rUser, task)]
  for step in 0 ..< cfg.maxSteps:
    sink("step.start", %*{"step": step})
    let action = await p.next(messages)
    case action.kind
    of makFinal:
      messages.add msg(rAssistant, action.text)
      sink("agent.final", %*{"step": step, "text": action.text})
      return (action.text, messages)
    of makToolCall:
      sink("tool.proposed", %*{"id": action.call.id, "name": action.call.name, "args": action.call.args})
      let d = decide(action.call, cfg)
      sink("policy.decision", %*{"decision": $d.kind, "reason": d.reason})
      if d.kind != pdAllow:
        messages.add msg(rTool, "DENIED: " & d.reason, action.call.name)
        continue
      if not registry.hasKey(action.call.name):
        messages.add msg(rTool, "ERROR: unknown tool", action.call.name)
        continue
      let r = registry[action.call.name](action.call.args, cfg)
      sink("tool.result", %*{"name": action.call.name, "ok": r.ok, "exitCode": r.exitCode})
      messages.add msg(rAssistant, "TOOL_CALL " & action.call.name & " " & $action.call.args)
      messages.add msg(rTool, r.output, action.call.name)
  let answer = "Stopped: maxSteps reached"
  messages.add msg(rAssistant, answer)
  sink("agent.halt", %*{"reason": "maxSteps"})
  return (answer, messages)
