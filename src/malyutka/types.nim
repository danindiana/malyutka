import std/[json, times]

type
  Role* = enum
    rSystem = "system", rUser = "user", rAssistant = "assistant", rTool = "tool"

  ToolCall* = object
    id*: string
    name*: string
    args*: JsonNode

  Message* = object
    role*: Role
    content*: string
    name*: string
    toolCalls*: seq[ToolCall]   ## assistant turns that requested tools
    toolCallId*: string         ## tool turns: which call this answers
    createdAt*: DateTime

  ModelActionKind* = enum makFinal, makToolCalls
  ModelAction* = object
    text*: string               ## assistant content (may accompany tool calls)
    case kind*: ModelActionKind
    of makFinal: discard
    of makToolCalls:
      calls*: seq[ToolCall]

  ToolResult* = object
    ok*: bool
    output*: string
    exitCode*: int
    truncated*: bool
    timedOut*: bool
    preview*: string            ## short excerpt/diff surfaced in tool.result events
    eventKind*: string          ## tool-specific event (e.g. "todo.update"), "" = none
    eventPayload*: JsonNode

  # ---- authority kernel -------------------------------------------------

  ExecutionRealm* = enum
    erInProcess = "in-process"  ## pure computation inside the harness process
    erSandbox = "sandbox"       ## child process confined by the sandbox broker
    erHost = "host"             ## child process with the operator's full authority
    erRemote = "remote"         ## reserved
    erExternal = "external"     ## a server process speaking a protocol (MCP): ceiling set by the operator
    erNetwork = "network"       ## outbound web access through the sandboxed helper (SPEC-011)

  EffectClass* = enum
    ## Blast radius of an action. Ordered: higher = more consequential.
    b0ReadOnly = "B0", b1LocalReversible = "B1", b2BroadWorkspace = "B2",
    b3External = "B3", b4Privileged = "B4"

  Verdict* = enum
    ## Ordinal order IS precedence: the lowest verdict any layer returns wins.
    vDeny = "DENY", vAsk = "ASK", vAllow = "ALLOW"

  Capability* = object
    name*: string
    realm*: ExecutionRealm
    maxEffect*: EffectClass     ## ceiling no policy layer can exceed
    askExempt*: bool            ## only set by the operator (mcp.json trust:allow on a B0 server)

  Decision* = object
    eventId*: string
    verdict*: Verdict
    effect*: EffectClass
    policyId*: string           ## which layer decided (invariant 8)
    reason*: string

  CgroupMode* = enum
    ## Resource limits via a transient systemd user scope (SPEC-008).
    cmAuto = "auto", cmRequire = "require", cmOff = "off"

  ApprovalMode* = enum
    ## Who answers an ASK. `deny` is the fail-closed default.
    amDeny = "deny", amStdin = "stdin", amTty = "tty", amOff = "off"

  Theme* = enum thWarsaw, thNato, thPlain

  AgentConfig* = object
    maxSteps*: int
    cwd*: string
    allowShell*: bool
    allowFiles*: bool           ## enable read_file/search_files/write_file/patch/todo
    allowMemory*: bool          ## enable the `memory` tool (needs stateDir)
    stateDir*: string           ## journal/sessions/memory live here (never the workspace)
    soul*: string               ## operator text prepended to the system prompt
    personality*: string
    memoryText*: string         ## snapshot of memory.md taken at run start
    allowWeb*: bool             ## web_fetch / web_search through the sandboxed helper (SPEC-011)
    webDeny*: seq[string]       ## domain denylist (from <state>/web.json)
    webAllowPrivate*: seq[string]  ## hosts the operator allows on private addresses
    webTimeoutSec*: int
    webMaxChars*: int
    webCaFile*: string
    allowSkills*: bool          ## skills_list / skill_view / skill_save (SPEC-009)
    allowMcp*: bool             ## MCP stdio client (SPEC-010)
    allowProcess*: bool         ## enable the background `process` tool
    cgroupMode*: CgroupMode
    limitMemoryMb*: int         ## MemoryMax for sandboxed commands (0 = none)
    limitPids*: int             ## TasksMax (0 = none)
    maxProcesses*: int          ## concurrently running background processes
    scopeActive*: bool          ## set by the harness after a successful scope probe
    unitPrefix*: string         ## transient unit name prefix (run id)
    contextWindow*: int         ## tokens; 0 = compaction off (SPEC-006)
    compressNow*: bool          ## compact the loaded history before the first call
    approvals*: ApprovalMode
    approvalTimeoutSec*: int    ## unanswered ASK becomes DENY after this long
    unconfinedHost*: bool       ## explicit waiver: shell may run unsandboxed
    shellTimeoutSec*: int
    maxOutputBytes*: int
    repeatLimit*: int           ## identical consecutive tool calls before HALT
    providerName*: string
    model*: string
    baseUrl*: string
    apiKey*: string
    requestTimeoutSec*: int
    theme*: Theme
    jsonEvents*: bool
    askEnabled*: bool           ## approval layer on: effects >= askFrom yield ASK
    askFrom*: EffectClass
    mandates*: bool             ## commitment latch: mandates may resolve ASKs
    scopeMissLimit*: int        ## uncovered ASKs in a row that suspend the latch (0 = off)

proc baseConfig*(): AgentConfig =
  ## Defaults with no environment or filesystem input (tests use this).
  AgentConfig(maxSteps: 16, cwd: ".", allowShell: false, allowFiles: false, allowMemory: false,
    allowSkills: false, allowMcp: false, allowWeb: false,
    webTimeoutSec: 20, webMaxChars: 15000,
    allowProcess: false, cgroupMode: cmAuto, limitMemoryMb: 2048, limitPids: 512, maxProcesses: 4,
    scopeActive: false, unitPrefix: "malyutka",
    approvals: amDeny, approvalTimeoutSec: 300, unconfinedHost: false,
    shellTimeoutSec: 30, maxOutputBytes: 64 * 1024, repeatLimit: 3,
    providerName: "mock", model: "mock", baseUrl: "", apiKey: "",
    requestTimeoutSec: 300, theme: thPlain, jsonEvents: false,
    askEnabled: false, askFrom: b1LocalReversible, mandates: false, scopeMissLimit: 3)
