## Capability registry. A tool is a capability (realm + effect ceiling), a wire
## schema, an effect classifier and an executor. The registry is built from
## configuration: a disabled tool does not exist, so it is never advertised to
## the model (removing a capability removes it from the model's context).

import std/[json, tables]
import ./[types, sandbox, filetools, memory, latch, process]
export filetools.ToolProc

type
  EffectProc* = proc(args: JsonNode): EffectClass {.closure.}
  ToolSpec* = object
    capability*: Capability
    description*: string
    parameters*: JsonNode
    effectOf*: EffectProc       ## effect of THIS call, before execution
    run*: ToolProc
    shutdown*: proc(): int {.closure.}   ## kills what the tool started; returns how many (nil = nothing)
  ToolRegistry* = OrderedTable[string, ToolSpec]

proc echoSpec(): ToolSpec =
  ToolSpec(
    capability: Capability(name: "echo", realm: erInProcess, maxEffect: b0ReadOnly),
    description: "Echo text through the harness.",
    parameters: %*{"type": "object", "properties": {"text": {"type": "string"}},
                   "required": ["text"]},
    effectOf: proc(args: JsonNode): EffectClass = b0ReadOnly,
    run: proc(args: JsonNode; cfg: AgentConfig): ToolResult =
      ToolResult(ok: true, output: args{"text"}.getStr(""), exitCode: 0))

proc shellSpec(cfg: AgentConfig): ToolSpec =
  ## The shell's effect is bounded by its confinement, not by parsing the
  ## command string. Inside the sandbox (read-only root, writable workspace,
  ## no network) the worst case is a broad workspace mutation (B2). On the
  ## host the worst case is unbounded (B4).
  let realm = if cfg.unconfinedHost: erHost else: erSandbox
  let ceiling = if realm == erSandbox: b2BroadWorkspace else: b4Privileged
  ToolSpec(
    capability: Capability(name: "shell", realm: realm, maxEffect: ceiling),
    description: (if realm == erSandbox:
      "Run a shell command in the workspace. Sandboxed: the filesystem outside " &
      "the workspace is read-only and there is no network access."
      else: "Run a shell command on the host in the workspace directory."),
    parameters: %*{"type": "object", "properties": {"command": {"type": "string"}},
                   "required": ["command"]},
    effectOf: proc(args: JsonNode): EffectClass = ceiling,
    run: proc(args: JsonNode; cfg: AgentConfig): ToolResult =
      if args.kind != JObject or not args.hasKey("command") or
         args["command"].kind != JString:
        return ToolResult(ok: false, output: "missing string argument: command", exitCode: 2)
      let cmd = args["command"].getStr
      var r: tuple[output: string, exitCode: int, truncated, timedOut: bool]
      case realm
      of erSandbox:
        let exe = bwrapPath()
        if exe.len == 0:
          raise newException(ConfinementError, "sandbox requested but bwrap unavailable")
        # The workspace is opened and validated as an fd, and that fd is what
        # bwrap binds: no second path resolution between check and mount.
        let ws = openWorkspace(cfg.cwd)
        defer: ws.close()
        let (argv, extra) = sandboxCommand(exe, ws.path, cmd, cfg.scopeActive, cfg.unitPrefix,
                                           "sh", cfg.limitMemoryMb, cfg.limitPids)
        r = runBounded(argv, cfg.shellTimeoutSec, cfg.maxOutputBytes, ws.path,
                       keepFd = ws.fd, extraEnv = extra)
      of erHost:
        r = runBounded(@["/bin/sh", "-c", cmd], cfg.shellTimeoutSec,
                       cfg.maxOutputBytes, cfg.cwd, hostTree = true)
      else:
        raise newException(ConfinementError, "unsupported realm for shell: " & $realm)
      var output = r.output
      if r.truncated: output.add "\n[malyutka: output truncated at " & $cfg.maxOutputBytes & " bytes]"
      if r.timedOut: output.add "\n[malyutka: timed out after " & $cfg.shellTimeoutSec & "s]"
      ToolResult(ok: r.exitCode == 0, output: output, exitCode: r.exitCode,
                 truncated: r.truncated, timedOut: r.timedOut))

proc fileSpec(name, description: string; parameters: JsonNode; ceiling: EffectClass;
              run: ToolProc): ToolSpec =
  ## A proc (not inline in the loop) so each spec's closure owns ITS ceiling:
  ## capturing the loop variable made every file tool report the last tool's
  ## effect (B0), which silently skipped the journal.
  ToolSpec(
    capability: Capability(name: name, realm: erInProcess, maxEffect: ceiling),
    description: description, parameters: parameters,
    effectOf: proc(args: JsonNode): EffectClass = ceiling,
    run: run)

proc toolsFor*(cfg: AgentConfig): ToolRegistry =
  result = initOrderedTable[string, ToolSpec]()
  result["echo"] = echoSpec()
  if cfg.allowShell:
    result["shell"] = shellSpec(cfg)
  if cfg.allowProcess:
    let mgr = newProcManager(cfg.maxProcesses)
    result["process"] = ToolSpec(
      capability: Capability(name: "process", realm: erSandbox, maxEffect: b2BroadWorkspace),
      description: "Run long-lived commands in the sandbox without blocking. " &
        "action=start{command} returns an id; poll{id} returns new output and state; " &
        "log{id,tail?}; kill{id}; list. At most " & $cfg.maxProcesses & " run at once and all stop when the run ends.",
      parameters: %*{"type": "object", "properties": {"action": {"type": "string",
        "enum": ["start", "poll", "log", "kill", "list"]}, "command": {"type": "string"},
        "id": {"type": "string"}, "tail": {"type": "integer"}}, "required": ["action"]},
      effectOf: effectOfProcess,
      run: proc(args: JsonNode; c: AgentConfig): ToolResult = runProcess(mgr, args, c),
      shutdown: proc(): int = shutdown(mgr))
  if cfg.allowMemory and cfg.stateDir.len > 0:
    result["memory"] = fileSpec("memory",
      "Persistent notes that survive across sessions (max 8 KiB). " &
      "ops: add{text}, replace{old,new}, remove{text}. Keep entries short and factual.",
      %*{"type": "object", "properties": {"op": {"type": "string"}, "text": {"type": "string"},
         "old": {"type": "string"}, "new": {"type": "string"}}, "required": ["op"]},
      b2BroadWorkspace, runMemoryTool)
  if cfg.allowFiles:
    for t in fileToolProcs():
      result[t.name] = fileSpec(t.name, t.description, t.parameters, t.ceiling, t.run)

proc wireSchemas*(registry: ToolRegistry): JsonNode =
  ## OpenAI-compatible `tools` array for exactly the capabilities that exist.
  result = newJArray()
  for name, spec in registry:
    result.add %*{"type": "function", "function": {
      "name": name, "description": spec.description, "parameters": spec.parameters}}

proc proposeMandateSpec*(store: LatchStore; runId: string): ToolSpec =
  ## Lets the model draft a mandate. Drafting authorizes nothing: only the
  ## operator (`malyutka mandate approve`) can latch it. Classified B0: it has
  ## no effect outside the harness, and its own record in the mandate log is
  ## durable before the result returns.
  ToolSpec(
    capability: Capability(name: "propose_mandate", realm: erInProcess, maxEffect: b0ReadOnly),
    description: "Propose a mandate: a scoped approval the operator may grant so that " &
      "a class of future tool calls can run without asking each time. Nothing is " &
      "authorized until the operator approves it.",
    parameters: proposalSchema(),
    effectOf: proc(args: JsonNode): EffectClass = b0ReadOnly,
    run: proc(args: JsonNode; cfg: AgentConfig): ToolResult =
      try:
        let m = store.propose(scopeFromToolArgs(args), by = "model:" & runId)
        ToolResult(ok: true, exitCode: 0, output: "PROPOSED " & m.id & " digest " & m.digest &
          ". It authorizes nothing until the operator runs: malyutka mandate --approve:" &
          m.id & " --digest:" & m.digest)
      except ValueError, LatchError:
        ToolResult(ok: false, exitCode: 2, output: "proposal rejected: " & getCurrentExceptionMsg()))
