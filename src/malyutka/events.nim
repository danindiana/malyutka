import std/[json, strutils, terminal, times]
import ./types

type EventSink* = proc(kind: string; payload: JsonNode) {.closure.}

proc jsonlSink*(kind: string; payload: JsonNode) =
  var e = newJObject()
  e["ts"] = %now().format("yyyy-MM-dd'T'HH:mm:sszzz")
  e["kind"] = %kind
  e["payload"] = payload
  echo $e

proc ansi(code: int): string = "\e[" & $code & "m"

proc themeCode(t: Theme): int =
  case t
  of thWarsaw: 32 # phosphor green
  of thNato: 33   # amber
  of thPlain: 0

proc themed(t: Theme; s: string): string =
  if t == thPlain: return s
  ansi(themeCode(t)) & s & ansi(0)

proc banner*(theme: Theme; provider, model: string) =
  let lines = [
    "+--------------------------------------------------------------+",
    "| MALYUTKA // 9M14                         GUIDANCE : READY   |",
    "| LINUX NATIVE AGENT HARNESS               LINK     : LOCAL   |",
    "+--------------------------------------------------------------+",
    "  PROVIDER  " & provider,
    "  MODEL     " & model,
    "  MODE      " & (if theme == thWarsaw: "WARSAW" elif theme == thNato: "NATO" else: "PLAIN"),
    "+--------------------------------------------------------------+"
  ]
  for line in lines: stderr.writeLine(themed(theme, line))

proc consoleSink*(theme: Theme): EventSink =
  result = proc(kind: string; payload: JsonNode) =
    let tag = case kind
      of "step.start": "STEP"
      of "tool.proposed": "ACT "
      of "policy.decision": "POL "
      of "tool.result": "OBS "
      of "agent.final": "DONE"
      of "agent.halt": "HALT"
      else: "EVT "
    var detail = ""
    case kind
    of "step.start": detail = "#" & $payload{"step"}.getInt
    of "tool.proposed": detail = payload{"name"}.getStr
    of "policy.decision": detail = payload{"decision"}.getStr & "  " & payload{"reason"}.getStr
    of "tool.result": detail = payload{"name"}.getStr & "  exit=" & $payload{"exitCode"}.getInt
    of "agent.final": detail = payload{"text"}.getStr
    of "agent.halt": detail = payload{"reason"}.getStr
    else: detail = $payload
    stderr.writeLine(themed(theme, "  " & tag & "  " & detail))
