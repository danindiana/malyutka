## Policy kernel. Layers can only lower authority: the effective verdict is the
## most restrictive verdict any layer returns (DENY < ASK < ALLOW), and an
## effect above the capability's ceiling is denied before any layer runs.
## Every Decision names the layer responsible.

import std/[json, strutils]
import ./[types, urlsafety]

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
    if call.name in ["shell", "process"] and call.args.kind == JObject and call.args.hasKey("command"):
      let c = call.args["command"].getStr.toLowerAscii
      for needle in ["rm -rf /", "mkfs", "shutdown", "reboot", ":(){ :|:& };:",
                     "dd of=/dev/", "of=/dev/sd", "of=/dev/nvme", "> /dev/sd"]:
        if needle in c: return (vDeny, "matched pattern: " & needle)
    (vAllow, ""))

proc compact(c: string): string = c.toLowerAscii.splitWhitespace.join(" ")

proc pipesToShell(c: string): bool =
  for fetch in ["curl ", "wget "]:
    if fetch in c:
      for sink in ["| sh", "|sh", "| bash", "|bash", "| sudo", "|sudo", "| zsh"]:
        if sink in c: return true

proc dangerousShell(c: string): string =
  ## Returns the reason a shell command needs an operator's OK, or "".
  if pipesToShell(c): return "pipes a download into a shell"
  if "chmod -r 777" in c or "chmod 777 -r" in c: return "recursive chmod 777"
  if "git push --force" in c or "git push -f" in c: return "force push"
  if "drop table" in c or "drop database" in c: return "destructive SQL"
  for t in ["> /etc/", ">> /etc/", "tee /etc/", "tee -a /etc/"]:
    if t in c: return "writes under /etc"
  let words = c.split(' ')
  for i, w in words:
    if w == "rm":
      var recursive = false
      for k in i + 1 ..< words.len:
        let a = words[k]
        if a.startsWith("-") and ('r' in a or "recursive" in a): recursive = true
        elif recursive and not a.startsWith("-") and (a.startsWith("/") or a.startsWith("~") or
             a == ".." or a.startsWith("../") or a.startsWith("$")):
          return "recursive delete outside the workspace"

proc sensitivePath(p: string): string =
  let path = p.strip.toLowerAscii.replace("\\", "/")
  let base = path.rsplit('/', 1)[^1]
  if path.startsWith(".git/") or "/.git/" in path: return "writes inside .git/"
  if path.startsWith(".ssh/") or "/.ssh/" in path: return "writes to .ssh"
  if base == ".env" or base.startsWith(".env."): return "writes a .env file"
  if base in ["authorized_keys", "id_rsa", "id_ed25519"]: return "writes key material"

let dangerousLayer* = PolicyLayer(id: "approval.dangerous",
  check: proc(call: ToolCall; cap: Capability; effect: EffectClass;
              cfg: AgentConfig): tuple[verdict: Verdict, reason: string] =
    ## Legitimate-but-risky actions need an operator's OK. DENY-class commands
    ## are handled by the denylist and never reach an approver.
    if call.name == "skill_save":
      return (vAsk, "agent-authored skill (it persists across sessions)")
    if call.args.kind == JObject:
      if call.name in ["shell", "process"] and call.args.hasKey("command") and
         call.args["command"].kind == JString:
        let why = dangerousShell(compact(call.args["command"].getStr))
        if why.len > 0: return (vAsk, why)
      if call.name in ["write_file", "patch"] and call.args.hasKey("path") and
         call.args["path"].kind == JString:
        let why = sensitivePath(call.args["path"].getStr)
        if why.len > 0: return (vAsk, why)
    (vAllow, ""))

let approvalLayer* = PolicyLayer(id: "approval",
  check: proc(call: ToolCall; cap: Capability; effect: EffectClass;
              cfg: AgentConfig): tuple[verdict: Verdict, reason: string] =
    ## Opt-in (--ask-from). Can only lower ALLOW to ASK. An ASK is resolved by
    ## a latched mandate (latch.nim) or, with none attached, fails closed.
    if cfg.askEnabled and effect >= cfg.askFrom:
      (vAsk, "effect " & $effect & " needs approval (ask-from " & $cfg.askFrom & ")")
    else: (vAllow, ""))

let mcpAskLayer* = PolicyLayer(id: "mcp.ask",
  check: proc(call: ToolCall; cap: Capability; effect: EffectClass;
              cfg: AgentConfig): tuple[verdict: Verdict, reason: string] =
    ## Every MCP call asks (resolved by a latched mandate, an approver or the allowlist),
    ## unless the operator marked a read-only (B0) server trust:allow. Can only lower ALLOW.
    if cap.realm == erExternal and not cap.askExempt:
      (vAsk, "MCP tool " & call.name & " runs outside the harness")
    else: (vAllow, ""))

let webUrlLayer* = PolicyLayer(id: "web.url",
  check: proc(call: ToolCall; cap: Capability; effect: EffectClass;
              cfg: AgentConfig): tuple[verdict: Verdict, reason: string] =
    ## DENY, not ASK: a URL that carries credentials, targets a private/metadata address or a denylisted
    ## domain must never reach an approver (invariant 18). Checks that need DNS happen in the helper.
    if call.name == "web_fetch":
      let url = if call.args.kind == JObject and call.args.hasKey("url") and call.args["url"].kind == JString:
                  call.args["url"].getStr.strip else: ""
      let why = urlPolicyReason(url, cfg.webDeny, cfg.webAllowPrivate)
      if why.len > 0: return (vDeny, why)
    (vAllow, ""))

let webAskLayer* = PolicyLayer(id: "web.ask",
  check: proc(call: ToolCall; cap: Capability; effect: EffectClass;
              cfg: AgentConfig): tuple[verdict: Verdict, reason: string] =
    ## Every web call asks (mandate, approver or deny): it sends text to a third party and reads
    ## untrusted text back. Only an operator-trusted loopback search is exempt (askExempt).
    if cap.realm == erNetwork and not cap.askExempt:
      var target = call.name
      if call.name == "web_fetch" and call.args.kind == JObject and call.args.hasKey("url") and call.args["url"].kind == JString:
        let w = parseWebUrl(call.args["url"].getStr.strip)
        if w.ok: target = "fetch " & w.host
      return (vAsk, "web access: " & target)
    (vAllow, ""))

proc defaultLayers*(): seq[PolicyLayer] =
  @[confinementLayer, denylistLayer, dangerousLayer, approvalLayer, mcpAskLayer, webUrlLayer, webAskLayer]
