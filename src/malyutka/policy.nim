## Policy kernel. Layers can only lower authority: the effective verdict is the
## most restrictive verdict any layer returns (DENY < ASK < ALLOW), and an
## effect above the capability's ceiling is denied before any layer runs.
## Every Decision names the layer responsible.

import std/[json, strutils]
import ./types

type PolicyLayer* = object
  id*: string
  check*: proc(call: ToolCall; cap: Capability; effect: EffectClass;
               cfg: AgentConfig): tuple[verdict: Verdict, reason: string] {.closure.}

proc compose*(layers: openArray[PolicyLayer]; call: ToolCall; cap: Capability;
              effect: EffectClass; cfg: AgentConfig; eventId: string): Decision =
  if effect > cap.maxEffect:
    return Decision(eventId: eventId, verdict: vDeny, effect: effect,
      policyId: "capability.ceiling",
      reason: "effect " & $effect & " exceeds ceiling " & $cap.maxEffect)
  result = Decision(eventId: eventId, verdict: vAllow, effect: effect,
                    policyId: "default", reason: "no layer objected")
  for layer in layers:
    let (v, why) = layer.check(call, cap, effect, cfg)
    if v < result.verdict:
      result.verdict = v
      result.policyId = layer.id
      result.reason = why
    if result.verdict == vDeny: break

let confinementLayer* = PolicyLayer(id: "confinement",
  check: proc(call: ToolCall; cap: Capability; effect: EffectClass;
              cfg: AgentConfig): tuple[verdict: Verdict, reason: string] =
    ## Host-realm side effects require the operator's explicit waiver.
    if cap.realm == erHost and effect > b0ReadOnly and not cfg.unconfinedHost:
      (vDeny, "host execution without --unconfined-host waiver")
    else: (vAllow, ""))

let denylistLayer* = PolicyLayer(id: "heuristic.denylist",
  check: proc(call: ToolCall; cap: Capability; effect: EffectClass;
              cfg: AgentConfig): tuple[verdict: Verdict, reason: string] =
    ## UX speed bump only. NOT a security boundary: trivially bypassed by
    ## quoting, aliases, `sh -c`, absolute paths. Confinement is the boundary.
    if call.name == "shell" and call.args.kind == JObject and call.args.hasKey("command"):
      let c = call.args["command"].getStr.toLowerAscii
      for needle in ["rm -rf /", "mkfs", "shutdown", "reboot", ":(){ :|:& };:"]:
        if needle in c: return (vDeny, "matched pattern: " & needle)
    (vAllow, ""))

proc defaultLayers*(): seq[PolicyLayer] = @[confinementLayer, denylistLayer]
