import std/[asyncdispatch, json, unittest]
import malyutka/[types, provider, core, config, tools, events]

proc cfgWith(allowShell = false): AgentConfig =
  result = baseConfig()
  result.allowShell = allowShell

suite "guidance loop":
  test "mock provider completes through tool loop":
    let r = waitFor runAgent(newMockProvider(), "test", cfgWith())
    check r.answer == "Guidance loop completed successfully."
    check r.halt == hrFinal
    check r.messages.len == 5   # system, user, assistant+calls, tool, final

  test "tool result answers its call id":
    let r = waitFor runAgent(newMockProvider(), "test", cfgWith())
    check r.messages[2].toolCalls.len == 1
    check r.messages[3].role == rTool
    check r.messages[3].toolCallId == r.messages[2].toolCalls[0].id

  test "every call in a multi-call turn gets a tool reply":
    let p = newScriptedProvider(@[
      ModelAction(kind: makToolCalls, calls: @[
        ToolCall(id: "a", name: "echo", args: %*{"text": "1"}),
        ToolCall(id: "b", name: "echo", args: %*{"text": "2"})]),
      ModelAction(kind: makFinal, text: "done")])
    let r = waitFor runAgent(p, "t", cfgWith())
    check r.messages[3].toolCallId == "a"
    check r.messages[4].toolCallId == "b"
    check r.messages[4].content == "2"

  test "maxSteps halts":
    var c = cfgWith(); c.maxSteps = 2; c.repeatLimit = 0
    var script: seq[ModelAction]
    for i in 0 ..< 5:
      script.add ModelAction(kind: makToolCalls, calls: @[
        ToolCall(id: "c" & $i, name: "echo", args: %*{"text": $i})])
    let r = waitFor runAgent(newScriptedProvider(script), "t", c)
    check r.halt == hrMaxSteps

  test "event ids are unique, ordered, and run-scoped":
    var ids: seq[string]
    let sink: EventSink = proc(k: string; p: JsonNode) = ids.add p["id"].getStr
    discard waitFor runAgent(newMockProvider(), "t", cfgWith(), sink = sink, runId = "R")
    check ids.len >= 6
    for i in 1 ..< ids.len: check ids[i] > ids[i-1]
    check ids[0] == "R-0001"

suite "configuration":
  test "theme aliases parse":
    check parseTheme("green") == thWarsaw
    check parseTheme("amber") == thNato

  test "disabled shell is not advertised to the model":
    let schemas = wireSchemas(toolsFor(cfgWith(false)))
    for s in schemas: check s["function"]["name"].getStr != "shell"
    check wireSchemas(toolsFor(cfgWith(true))).len == 2
