import std/[asyncdispatch, json, strutils, unittest]
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

# Deterministic xorshift64* PRNG for the fuzzer. Not std/random: its
# compile-time initialization cannot be evaluated by the Nim 2.2.4 wasm checker
# used for 2.x certification, and a fuzzer needs nothing more than this.
type Rng = object
  s: uint64
proc next(r: var Rng): uint64 =
  r.s = r.s xor (r.s shr 12); r.s = r.s xor (r.s shl 25); r.s = r.s xor (r.s shr 27)
  r.s * 0x2545F4914F6CDD1D'u64
proc rand(r: var Rng; s: HSlice[int, int]): int =
  s.a + int(r.next mod uint64(s.b - s.a + 1))
proc chance(r: var Rng; p: float): bool = float(r.next shr 11) / float(1'u64 shl 53) < p
proc sample[T](r: var Rng; xs: openArray[T]): T = xs[r.rand(0 .. xs.high)]

suite "tool protocol completeness":
  test "repetition halt mid-turn answers every call in the turn":
    var c = cfgWith(); c.repeatLimit = 2
    let same = ToolCall(id: "", name: "echo", args: %*{"text": "same"})
    let p = newScriptedProvider(@[
      ModelAction(kind: makToolCalls, calls: @[same]),
      ModelAction(kind: makToolCalls, calls: @[same,
        ToolCall(id: "", name: "echo", args: %*{"text": "other"}),
        ToolCall(id: "", name: "nope", args: %*{})])])
    let r = waitFor runAgent(p, "t", c)
    check r.halt == hrRepetition
    check validateTranscript(r.messages) == ""
    var cancelled = 0
    for m in r.messages:
      if m.role == rTool and m.content.startsWith("CANCELLED"): inc cancelled
    check cancelled == 3

  test "duplicate and missing provider call ids are made unique":
    let p = newScriptedProvider(@[
      ModelAction(kind: makToolCalls, calls: @[
        ToolCall(id: "call_0", name: "echo", args: %*{"text": "a"}),
        ToolCall(id: "call_0", name: "echo", args: %*{"text": "b"}),
        ToolCall(id: "", name: "echo", args: nil)]),
      ModelAction(kind: makFinal, text: "ok")])
    let r = waitFor runAgent(p, "t", cfgWith())
    check validateTranscript(r.messages) == ""
    check r.messages[2].toolCalls[0].id != r.messages[2].toolCalls[1].id

  test "validator rejects the M1 failure shapes":
    let a = Message(role: rAssistant, toolCalls: @[ToolCall(id: "x", name: "echo")])
    check validateTranscript(@[a]) != ""                                  # unanswered
    check validateTranscript(@[Message(role: rTool, toolCallId: "")]) != "" # orphan tool msg
    check validateTranscript(@[a, Message(role: rTool, toolCallId: "x")]) == ""

  test "protocol fuzz: 2000 random scripts keep the transcript valid":
    var rng = Rng(s: 0x9_14)
    let names = ["echo", "echo", "shell", "nope", ""]
    for trial in 0 ..< 2000:
      var script: seq[ModelAction]
      for t in 0 ..< rng.rand(0 .. 7):
        if rng.chance(0.15):
          script.add ModelAction(kind: makFinal, text: "f")
          continue
        var calls: seq[ToolCall]
        for k in 0 ..< rng.rand(1 .. 4):
          let id = case rng.rand(0 .. 3)
            of 0: ""
            of 1: "dup"
            else: "c" & $rng.rand(0 .. 5)
          let args = case rng.rand(0 .. 3)
            of 0: nil
            of 1: %*{"text": "same"}
            of 2: %*{"command": "true"}
            else: %*{"text": $rng.rand(0 .. 2)}
          calls.add ToolCall(id: id, name: rng.sample(names), args: args)
        script.add ModelAction(kind: makToolCalls, text: "", calls: calls)
      var c = cfgWith()
      c.maxSteps = rng.rand(1 .. 6)
      c.repeatLimit = rng.rand(0 .. 3)
      let r = waitFor runAgent(newScriptedProvider(script), "t", c)
      let v = validateTranscript(r.messages)
      if v != "":
        checkpoint "trial " & $trial & ": " & v
        fail()
        break
