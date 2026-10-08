import std/[asyncdispatch, json, os, parseopt, strutils]
import malyutka/[types, provider, core, session, events, config, sandbox, journal]

const Version = "0.3.2"

proc usage() =
  echo """malyutka // 9M14 - Linux-native Nim agent harness (v""" & Version & """)

Usage:
  malyutka run [options] <task>
  malyutka doctor
  malyutka journal                     Journal health + actions with unknown outcome
  malyutka journal --reconcile:ID --as:completed|failed|not-executed
                                       Record the outcome you established for an action
  malyutka journal --ack:ID            Mark it seen, outcome still unknown

Options:
  --provider:mock|openai|ollama|vllm   Provider adapter (all but mock are OpenAI-compatible)
  --model:NAME               Model identifier
  --base-url:URL             e.g. http://127.0.0.1:11434 for Ollama
  --api-key:KEY              API key (prefer MALYUTKA_API_KEY)
  --allow-shell              Enable the shell capability (sandboxed with bubblewrap)
  --unconfined-host          WAIVER: run the shell on the host, unsandboxed
  --shell-timeout:SEC        Per-command wall-clock limit (default 30)
  --max-steps:N              Guidance-loop budget (default 16)
  --repeat-limit:N           Halt after N identical consecutive calls (default 3, 0=off)
  --request-timeout:SEC      Provider request timeout (default 300)
  --theme:warsaw|nato|plain  Console theme
  --json                     Emit canonical JSONL events on stdout
  --config:PATH              JSON config file

Environment:
  MALYUTKA_PROVIDER MALYUTKA_MODEL MALYUTKA_BASE_URL MALYUTKA_API_KEY
  MALYUTKA_STATE_DIR   journal + sessions (default ~/.local/state/malyutka)

Exit codes: 0 answered, 1 failure, 2 usage, 3 confinement unavailable, 4 halted,
            5 journal unavailable, misplaced, or unknown outcomes pending,
            6 journal corrupt (journal command)
"""

proc makeProvider(cfg: AgentConfig): Provider =
  case cfg.providerName.toLowerAscii
  of "mock": newMockProvider()
  of "openai", "ollama", "vllm":
    newOpenAICompatProvider(cfg.providerName.toLowerAscii, cfg.baseUrl, cfg.apiKey,
                            cfg.model, cfg.requestTimeoutSec)
  else: raise newException(ValueError, "unknown provider: " & cfg.providerName)

proc headline(msg: string): string =
  ## asyncdispatch appends an async traceback to exception messages.
  let cut = msg.find("\nAsync traceback:")
  (if cut >= 0: msg[0 ..< cut] else: msg).strip

proc stateDir(): string =
  getEnv("MALYUTKA_STATE_DIR", parentDir(defaultJournalPath()))

proc journalPath(): string = stateDir() / "journal.jsonl"

proc journalCmd() =
  var ack, reconcile, asState = ""
  for kind, key, val in getopt(commandLineParams()[1 .. ^1]):
    if kind == cmdLongOption:
      case key
      of "ack": ack = val
      of "reconcile": reconcile = val
      of "as": asState = val.toUpperAscii.replace("-", "_")
      else: stderr.writeLine("error: unknown option --" & key); quit(2)
  let path = journalPath()
  let scan = try: scanJournal(path)
             except JournalError as e: (stderr.writeLine("error: " & e.msg); quit(5))
  let target = if ack.len > 0: ack else: reconcile
  if target.len > 0:
    if ack.len > 0 and reconcile.len > 0:
      stderr.writeLine("error: use either --ack or --reconcile"); quit(2)
    if reconcile.len > 0 and asState notin ["COMPLETED", "FAILED", "NOT_EXECUTED"]:
      stderr.writeLine("error: --reconcile needs --as:completed|failed|not-executed"); quit(2)
    var current = ""
    for a in scan.actions:
      if a.action == target: current = $a.state
    let allowed = if ack.len > 0: @[$asUnknownOutcome]
                  else: @[$asUnknownOutcome, $asAckUnresolved]
    if current notin allowed:
      stderr.writeLine("error: " & target & " is " &
        (if current.len > 0: current else: "not in the journal") &
        "; expected " & allowed.join(" or ")); quit(2)
    let j = openJournal(path, writer = "operator-" & getEnv("USER", "unknown"))
    if ack.len > 0:
      j.append(%*{"rec": "ack", "action": ack, "by": getEnv("USER", "operator")})
      echo ack, " -> ACKNOWLEDGED_UNRESOLVED (outcome still unknown)"
    else:
      j.append(%*{"rec": "reconcile", "action": reconcile, "as": asState,
                  "by": getEnv("USER", "operator")})
      echo reconcile, " -> RECONCILED as ", asState
    j.close()
    quit(0)
  echo "journal: ", path
  echo "health:  ", $scan.health
  for p in scan.problems: echo "  CORRUPT: ", p
  if scan.tornLines.len > 0:
    echo "  torn line(s) ", scan.tornLines.join(", "),
         ": writes interrupted by a crash; the step each guarded never proceeded"
  var unresolved: seq[ActionSummary]
  for a in scan.actions:
    if a.state in {asUnknownOutcome, asAckUnresolved}: unresolved.add a
  if unresolved.len == 0:
    echo "no actions with unknown outcome"
  else:
    echo unresolved.len, " action(s) with unknown outcome. They may or may not have taken"
    echo "effect, and Malyutka will not re-run them:"
    for a in unresolved:
      echo "  ", a.action, "  ", $a.state, "  ", a.startedAt, "  ", a.tool, " ", $a.args
    echo "Inspect, then: malyutka journal --reconcile:<ID> --as:completed|failed|not-executed"
    echo "          or: malyutka journal --ack:<ID>   (seen; outcome stays unknown)"
  if scan.health == jhCorrupt: quit(6)
  var pending = false
  for a in unresolved:
    if a.state == asUnknownOutcome: pending = true
  quit(if pending: 5 else: 0)

proc doctor() =
  echo "malyutka: ", Version
  echo "designation: 9M14"
  echo "platform: ", hostOS, "/", hostCPU
  echo "nim: ", NimVersion
  echo "cwd: ", getCurrentDir()
  let (ok, detail) = probeBwrap()
  echo "sandbox: ", (if ok: "bwrap OK (" & detail & ")" else: "UNAVAILABLE - " & detail)
  echo "journal: ", journalPath()
  if not ok:
    echo "note: --allow-shell will refuse to run until the sandbox probe passes."
    quit(3)

proc main() =
  if paramCount() == 0: usage(); quit(0)
  let cmd = paramStr(1)
  if cmd == "doctor": doctor(); quit(0)
  if cmd == "journal": journalCmd()
  if cmd in ["-h", "--help", "help"]: usage(); quit(0)
  if cmd != "run": usage(); quit(2)

  var cfg = defaultConfig()
  var words: seq[string]
  var configPath = ""
  var p = initOptParser(commandLineParams()[1..^1])
  for kind, key, val in p.getopt():
    if kind == cmdLongOption and key == "config": configPath = val
  try:
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
        of "unconfined-host": cfg.unconfinedHost = true
        of "shell-timeout": cfg.shellTimeoutSec = parseInt(val)
        of "max-steps": cfg.maxSteps = parseInt(val)
        of "repeat-limit": cfg.repeatLimit = parseInt(val)
        of "request-timeout": cfg.requestTimeoutSec = parseInt(val)
        of "theme": cfg.theme = parseTheme(val)
        of "json": cfg.jsonEvents = true
        of "config": discard
        else: stderr.writeLine("error: unknown option --" & key); quit(2)
      of cmdShortOption:
        stderr.writeLine("error: unknown option -" & key); quit(2)
      of cmdArgument: words.add(key)
      of cmdEnd: discard
  except ValueError, IOError:
    stderr.writeLine("error: " & getCurrentExceptionMsg()); quit(2)
  if words.len == 0: stderr.writeLine("error: task required"); quit(2)
  if cfg.unconfinedHost and not cfg.allowShell:
    stderr.writeLine("warning: --unconfined-host has no effect without --allow-shell")

  let task = words.join(" ")
  let shellMode = if not cfg.allowShell: "DISABLED"
                  elif cfg.unconfinedHost: "HOST (UNCONFINED)"
                  else: "SANDBOX (bwrap)"
  if not cfg.jsonEvents: banner(cfg.theme, cfg.providerName, cfg.model, shellMode)
  let sink: EventSink = if cfg.jsonEvents: jsonlSink else: consoleSink(cfg.theme)
  try:
    let runId = newRunId()
    var j: Journal
    try:
      # State dir (journal + sessions) must be disjoint from the workspace.
      checkJournalPlacement(stateDir(), cfg.cwd)
      j = openJournal(journalPath(), writer = runId)
    except JournalError as e:
      stderr.writeLine("malyutka: journal unavailable, refusing to run: " & e.msg); quit(5)
    defer: j.close()
    let res = waitFor runAgent(makeProvider(cfg), task, cfg, sink = sink, runId = runId, journal = j)
    # Outside the workspace, like the journal: the sandboxed agent cannot edit it.
    saveSession(stateDir() / "sessions" / (res.runId & ".json"), res.runId, res.messages)
    if cfg.jsonEvents: stderr.writeLine("FINAL: " & res.answer)
    else: stderr.writeLine("\n" & res.answer)
    if res.halt != hrFinal: quit(4)
  except JournalError as e:
    stderr.writeLine("malyutka: journal refused the run: " & headline(e.msg))
    quit(5)
  except ConfinementError as e:
    stderr.writeLine("malyutka: confinement unavailable, refusing to run: " & headline(e.msg))
    stderr.writeLine("  fix: apt install bubblewrap, check `malyutka doctor`, or pass --unconfined-host")
    quit(3)
  except CatchableError as e:
    stderr.writeLine("malyutka: guidance failure: " & headline(e.msg))
    quit(1)

when isMainModule:
  main()
