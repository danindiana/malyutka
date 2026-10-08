import std/[asyncdispatch, os, parseopt, strutils]
import malyutka/[types, provider, core, session, events, config]

proc usage() =
  echo """malyutka // 9M14 - Linux-native Nim agent harness

Usage:
  malyutka run [options] <task>
  malyutka doctor

Options:
  --provider:mock|openai     Provider adapter (openai is OpenAI-compatible)
  --model:NAME               Model identifier
  --base-url:URL             e.g. http://127.0.0.1:11434 for Ollama
  --api-key:KEY              API key (prefer MALYUTKA_API_KEY)
  --allow-shell              Enable shell capability (still policy gated)
  --max-steps:N              Guidance-loop budget
  --theme:warsaw|nato|plain  Console theme
  --json                     Emit canonical JSONL events
  --config:PATH              JSON config file

Environment:
  MALYUTKA_PROVIDER MALYUTKA_MODEL MALYUTKA_BASE_URL MALYUTKA_API_KEY
"""

proc makeProvider(cfg: AgentConfig): Provider =
  case cfg.providerName.toLowerAscii
  of "mock": newMockProvider()
  of "openai", "ollama", "vllm": newOpenAICompatProvider(cfg.baseUrl, cfg.apiKey, cfg.model)
  else: raise newException(ValueError, "unknown provider: " & cfg.providerName)

proc main() =
  if paramCount() == 0: usage(); quit(0)
  let cmd = paramStr(1)
  if cmd == "doctor":
    echo "malyutka: nominal"
    echo "designation: 9M14"
    echo "platform: ", hostOS, "/", hostCPU
    echo "cwd: ", getCurrentDir()
    quit(0)
  if cmd != "run": usage(); quit(2)

  var cfg = defaultConfig()
  var words: seq[string]
  var configPath = ""
  var p = initOptParser(commandLineParams()[1..^1])
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption:
      case key
      of "config": configPath = val
      else: discard
    else: discard
  if configPath.len > 0: cfg = loadConfig(configPath, cfg)

  p = initOptParser(commandLineParams()[1..^1])
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption:
      case key
      of "provider": cfg.providerName = val
      of "model": cfg.model = val
      of "base-url": cfg.baseUrl = val
      of "api-key": cfg.apiKey = val
      of "allow-shell": cfg.allowShell = true
      of "max-steps": cfg.maxSteps = parseInt(val)
      of "theme": cfg.theme = parseTheme(val)
      of "json": cfg.jsonEvents = true
      of "config": discard
      else: echo "warning: unknown option --", key
    of cmdArgument: words.add(key)
    else: discard
  if words.len == 0: echo "error: task required"; quit(2)

  let task = words.join(" ")
  if not cfg.jsonEvents: banner(cfg.theme, cfg.providerName, cfg.model)
  let sink = if cfg.jsonEvents: jsonlSink else: consoleSink(cfg.theme)
  try:
    let res = waitFor runAgent(makeProvider(cfg), task, cfg, sink = sink)
    createDir(".malyutka")
    saveSession(".malyutka/last-session.json", res.messages)
    if cfg.jsonEvents: stderr.writeLine("FINAL: " & res.answer)
    else: stderr.writeLine("\n" & res.answer)
  except CatchableError as e:
    stderr.writeLine("malyutka: guidance failure: " & e.msg)
    quit(1)

when isMainModule:
  main()
