import std/[json, osproc, tables, strutils]
import ./types

type ToolProc* = proc(args: JsonNode; cfg: AgentConfig): ToolResult {.closure.}
type ToolRegistry* = Table[string, ToolProc]

proc echoTool(args: JsonNode; cfg: AgentConfig): ToolResult =
  let text = if args.hasKey("text"): args["text"].getStr else: ""
  ToolResult(ok: true, output: text, exitCode: 0)

proc shellTool(args: JsonNode; cfg: AgentConfig): ToolResult =
  if not args.hasKey("command"):
    return ToolResult(ok: false, output: "missing command", exitCode: 2)
  let cmd = args["command"].getStr
  let r = execCmdEx(cmd, workingDir = cfg.cwd)
  ToolResult(ok: r.exitCode == 0, output: r.output, exitCode: r.exitCode)

proc defaultTools*(): ToolRegistry =
  result = initTable[string, ToolProc]()
  result["echo"] = echoTool
  result["shell"] = shellTool
