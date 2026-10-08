import std/[json, times]

type
  Role* = enum rSystem, rUser, rAssistant, rTool
  Message* = object
    role*: Role
    content*: string
    name*: string
    createdAt*: DateTime

  ToolCall* = object
    id*: string
    name*: string
    args*: JsonNode

  ModelActionKind* = enum makFinal, makToolCall
  ModelAction* = object
    case kind*: ModelActionKind
    of makFinal:
      text*: string
    of makToolCall:
      call*: ToolCall

  ToolResult* = object
    ok*: bool
    output*: string
    exitCode*: int

  PolicyDecisionKind* = enum pdAllow, pdDeny, pdAsk
  PolicyDecision* = object
    kind*: PolicyDecisionKind
    reason*: string

  Theme* = enum thWarsaw, thNato, thPlain

  AgentConfig* = object
    maxSteps*: int
    cwd*: string
    allowShell*: bool
    providerName*: string
    model*: string
    baseUrl*: string
    apiKey*: string
    theme*: Theme
    jsonEvents*: bool
