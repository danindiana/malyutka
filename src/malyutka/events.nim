import std/[json, strutils, times]
import ./types

## Events are semantic; presentation is a view. Every event carries the run ID
## and a run-unique, monotonically increasing event ID (invariant 7).

type
  EventSink* = proc(kind: string; payload: JsonNode) {.closure.}
  Emitter* = ref object
    runId*: string
    counter*: int
    sink*: EventSink

proc newEmitter*(runId: string; sink: EventSink): Emitter =
  Emitter(runId: runId, counter: 0, sink: sink)

proc nextId*(e: Emitter): string =
  inc e.counter
  e.runId & "-" & align($e.counter, 4, '0')

proc emit*(e: Emitter; kind: string; payload: JsonNode; id = ""): string =
  ## Not {.discardable.}: implicit discards inside {.async.} procs trigger
  ## "internal error: yield in expr not lowered" on Nim 1.6.
  ## Emits with a fresh ID unless one was pre-allocated (e.g. a Decision's ID).
  result = if id.len > 0: id else: e.nextId()
  var p = if payload.isNil: newJObject() else: payload
  p["id"] = %result
  p["run"] = %e.runId
  e.sink(kind, p)

proc nowStamp(): string = now().format("yyyy-MM-dd'T'HH:mm:sszzz")

proc jsonlSink*(kind: string; payload: JsonNode) =
  var e = newJObject()
  e["ts"] = %nowStamp()
  e["kind"] = %kind
  e["payload"] = payload
  echo $e

proc nullSink*(kind: string; payload: JsonNode) = discard

proc ansi(code: int): string = "\e[" & $code & "m"

proc themeCode(t: Theme): int =
  case t
  of thWarsaw: 32 # phosphor green
  of thNato: 33   # amber
  of thPlain: 0

proc themed(t: Theme; s: string): string =
  if t == thPlain: return s
  ansi(themeCode(t)) & s & ansi(0)

proc banner*(theme: Theme; provider, model, shellMode: string) =
  let lines = [
    "+--------------------------------------------------------------+",
    "| MALYUTKA // 9M14                         GUIDANCE : READY    |",
    "| LINUX NATIVE AGENT HARNESS               LINK     : LOCAL    |",
    "+--------------------------------------------------------------+",
    "  PROVIDER  " & provider,
    "  MODEL     " & model,
    "  SHELL     " & shellMode,
    "  MODE      " & (if theme == thWarsaw: "WARSAW" elif theme == thNato: "NATO" else: "PLAIN"),
    "+--------------------------------------------------------------+"
  ]
  for line in lines: stderr.writeLine(themed(theme, line))

proc short(s: string; n = 100): string =
  if s.len <= n: s else: s[0 ..< n] & "..."

proc consoleSink*(theme: Theme): EventSink =
  result = proc(kind: string; payload: JsonNode) =
    let id = payload{"id"}.getStr("")
    let seqPart = if id.len >= 4: id[^4 .. ^1] else: id
    var tag, detail: string
    case kind
    of "run.start":
      tag = "RUN "; detail = payload{"run"}.getStr & "  tools=" & $payload{"tools"}
    of "confinement.waived":
      tag = "WARN"; detail = "CONFINEMENT WAIVED: shell runs on host"
    of "step.start":
      tag = "STEP"; detail = "#" & $payload{"step"}.getInt
    of "tool.proposed":
      tag = "ACT "; detail = payload{"name"}.getStr & " " & short($payload{"args"})
    of "policy.decision":
      tag = "POL "; detail = "[" & payload{"verdict"}.getStr & "] " &
        payload{"effect"}.getStr & "  " & payload{"policy"}.getStr &
        (if payload{"reason"}.getStr.len > 0: ": " & payload{"reason"}.getStr else: "")
    of "tool.result":
      tag = "OBS "; detail = payload{"name"}.getStr & "  exit=" & $payload{"exitCode"}.getInt &
        (if payload{"truncated"}.getBool: " TRUNC" else: "") &
        (if payload{"timedOut"}.getBool: " TIMEOUT" else: "")
    of "journal.unknown_outcome":
      tag = "WARN"; detail = "UNKNOWN OUTCOME from run " & payload{"run"}.getStr & ": " &
        payload{"tool"}.getStr & " " & short($payload{"args"}, 60) & "  (malyutka journal)"
    of "journal.owner_unknown":
      tag = "WARN"; detail = "OWNER STATUS UNKNOWN for " & payload{"action"}.getStr & " (" &
        payload{"tool"}.getStr & "): cannot tell if its run is alive  (malyutka journal)"
    of "journal.degraded":
      tag = "WARN"; detail = "outcome not journaled: " & payload{"reason"}.getStr
    of "tool.cancelled":
      tag = "CNCL"; detail = payload{"name"}.getStr & "  " & payload{"reason"}.getStr
    of "confinement.failed":
      tag = "FAIL"; detail = payload{"reason"}.getStr
    of "approval.request":
      tag = "ASK "; detail = payload{"tool"}.getStr & " " & short($payload{"args"}, 60) &
        "  needs approval: " & payload{"reason"}.getStr
    of "approval.answer":
      tag = "APPR"; detail = payload{"answer"}.getStr & " (" & payload{"source"}.getStr & ")"
    of "session.saved":
      tag = "SAVE"; detail = payload{"status"}.getStr & " (" & $payload{"messages"}.getInt & " messages)"
    of "session.failed":
      tag = "WARN"; detail = "session not saved: " & payload{"reason"}.getStr
    of "memory.updated":
      tag = "MEM "; detail = payload{"op"}.getStr & " (" & $payload{"bytes"}.getInt & " bytes)"
    of "todo.update":
      tag = "TODO"; detail = $payload{"items"}.len & " item(s)"
    of "agent.final":
      tag = "DONE"; detail = short(payload{"text"}.getStr, 200)
    of "agent.halt":
      tag = "HALT"; detail = payload{"reason"}.getStr
    else:
      tag = "EVT "; detail = kind & " " & short($payload)
    stderr.writeLine(themed(theme, "  " & seqPart & " " & tag & "  " & detail))
