import std/[strutils]
import ./types

proc decide*(call: ToolCall; cfg: AgentConfig): PolicyDecision =
  if call.name == "shell" and not cfg.allowShell:
    return PolicyDecision(kind: pdDeny, reason: "shell disabled by policy")
  if call.name == "shell" and call.args.hasKey("command"):
    let c = call.args["command"].getStr.toLowerAscii
    for needle in ["rm -rf /", "mkfs", "shutdown", "reboot", ":(){ :|:& };:"]:
      if needle in c:
        return PolicyDecision(kind: pdDeny, reason: "dangerous shell pattern")
  PolicyDecision(kind: pdAllow, reason: "allowed")
