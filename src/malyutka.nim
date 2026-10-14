import std/[asyncdispatch, json, os, parseopt, strutils, tables]
import malyutka/[types, provider, core, session, events, config, sandbox, journal, approval, memory, latch, tools, web]

const Version = "0.8.0"

proc usage() =
  echo """malyutka // 9M14 - Linux-native Nim agent harness (v""" & Version & """)

Usage:
  malyutka run [options] <task>
  malyutka doctor
  malyutka sessions [--json]           List saved sessions (newest first)
  malyutka sessions --show:ID          Print a session transcript
  malyutka sessions --search:TEXT      Ranked search over transcripts (--limit:N, --json)
  malyutka journal                     Journal health + actions with unknown outcome
  malyutka journal --reconcile:ID --as:completed|failed|not-executed
                                       Record the outcome you established for an action
  malyutka journal --ack:ID            Mark it seen, outcome still unknown
  malyutka mandate                     List mandates and mandate-log health
  malyutka mandate --grant --tools:a,b --max-effect:B2 --actions:N --ttl:SEC --goal:TEXT
                                       Propose and approve a mandate in one step
  malyutka mandate --approve:ID [--digest:CRC]   Latch a proposed mandate
  malyutka mandate --revoke:ID [--reason:TEXT]   Revoke (never needs approval)
  malyutka mandate --resume:ID                   Re-latch a suspended mandate

Options:
  --provider:mock|openai|ollama|vllm   Provider adapter (all but mock are OpenAI-compatible)
  --model:NAME               Model identifier
  --base-url:URL             e.g. http://127.0.0.1:11434 for Ollama
  --api-key:KEY              API key (prefer MALYUTKA_API_KEY)
  --allow-shell              Enable the shell capability (sandboxed with bubblewrap)
  --allow-files              Enable read_file/search_files/write_file/patch/todo (workspace only)
  --approvals:deny|stdin|tty|off
                             Who answers an ASK (default deny = fail closed). stdin: JSONL
                             control channel (see spec/SPEC-002); off needs --i-know-approvals-off
  --approval-timeout:SEC     Unanswered ASK becomes DENY after SEC (default 300)
  --resume:ID|last           Continue a saved session with this task as the next user turn
                             (never re-executes anything; see spec/SPEC-003)
  --resume-despite-unknown   Resume even if the session has unresolved UNKNOWN_OUTCOME actions
  --context-window:N         Model context size in tokens; compaction starts at 75% (default 32768, 0 = off)
  --compress                 Compact the loaded history before the first call (with --resume)
  --allow-process            Enable the background `process` tool (start/poll/log/kill/list; sandboxed)
  --max-processes:N          Concurrent background processes (default 4)
  --cgroups:auto|require|off Resource limits via a systemd user scope (default auto: degrade visibly)
  --limit-memory:MB          MemoryMax for sandboxed commands (default 2048, 0 = none)
  --limit-pids:N             TasksMax for sandboxed commands (default 512, 0 = none)
  --mcp                      Connect the MCP servers in <state>/mcp.json (sandboxed; every call asks; see spec/SPEC-010)
  --web                      Enable web_fetch (via the sandboxed malyutka_web helper; every call asks; see spec/SPEC-011)
  --skills                   Enable skills_list / skill_view / skill_save (<state>/skills; save needs approval)
  --allow-memory             Enable the `memory` tool and inject memory.md into the prompt
  --soul:PATH                Operator persona file (default <state>/SOUL.md if present)
  --personality:NAME         concise|teacher|kawaii|terse-ops
  --unconfined-host          WAIVER: run the shell on the host, unsandboxed
  --shell-timeout:SEC        Per-command wall-clock limit (default 30)
  --max-steps:N              Guidance-loop budget (default 16)
  --repeat-limit:N           Halt after N identical consecutive calls (default 3, 0=off)
  --request-timeout:SEC      Provider request timeout (default 300)
  --theme:warsaw|nato|plain  Console theme
  --json                     Emit canonical JSONL events on stdout
  --ask-from:B0..B4          Approval layer: effects at or above this class ASK
  --mandates                 Let latched mandates resolve ASKs; adds propose_mandate
  --scope-miss-limit:N       Uncovered ASKs in a row that suspend the latch (default 3, 0=off)
  --config:PATH              JSON config file

Environment:
  MALYUTKA_PROVIDER MALYUTKA_MODEL MALYUTKA_BASE_URL MALYUTKA_API_KEY
  MALYUTKA_STATE_DIR   journal + sessions (default ~/.local/state/malyutka)

Exit codes: 0 answered, 1 failure, 2 usage, 3 confinement unavailable, 4 halted,
            5 journal unavailable, misplaced, or unknown outcomes pending,
            6 journal corrupt (journal command), 7 mandate log unavailable or corrupt
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

proc mandatePath(): string = defaultLatchPath(stateDir())

proc operatorId(): string = "operator:" & getEnv("USER", "unknown")

proc mandateCmd() =
  var grant = false
  var approve, revoke, resume, digest, tools, maxEffect, goal = ""
  var reason = "revoked by operator"
  var actions, ttl = 0
  # getopt(@[]) falls back to the real command line, so skip it when empty.
  let args = commandLineParams()[1 .. ^1]
  try:
    for kind, key, val in getopt(args):
      if args.len == 0: break
      if kind != cmdLongOption:
        stderr.writeLine("error: unexpected argument " & key); quit(2)
      case key
      of "grant": grant = true
      of "approve": approve = val
      of "revoke": revoke = val
      of "resume": resume = val
      of "digest": digest = val
      of "tools": tools = val
      of "max-effect": maxEffect = val
      of "actions": actions = parseInt(val)
      of "ttl": ttl = parseInt(val)
      of "goal": goal = val
      of "reason": reason = val
      else: stderr.writeLine("error: unknown option --" & key); quit(2)
  except ValueError as e:
    stderr.writeLine("error: " & e.msg); quit(2)
  let store = newLatchStore(mandatePath())
  try:
    if grant:
      var ts: seq[string]
      for t in tools.split(','):
        if t.strip.len > 0: ts.add t.strip
      let scope = scopeJson(goal, ts, parseEffect(if maxEffect.len > 0: maxEffect else: "?"),
                            actions, ttl)
      let m = store.grant(scope, operatorId())
      echo m.id, " -> LATCHED  tools=", m.tools.join(","), " max-effect=", $m.maxEffect,
           " actions=", m.maxActions, " ttl=", m.ttlSec, "s  digest=", m.digest
      quit(0)
    if approve.len > 0:
      let m = store.approve(approve, operatorId(), digest)
      echo m.id, " -> LATCHED  digest=", m.digest
      quit(0)
    if revoke.len > 0:
      store.revoke(revoke, reason, operatorId())
      echo revoke, " -> REVOKED"
      quit(0)
    if resume.len > 0:
      store.resume(resume, operatorId())
      echo resume, " -> LATCHED (resumed)"
      quit(0)
  except ValueError as e:
    stderr.writeLine("error: " & e.msg); quit(2)
  except LatchError as e:
    stderr.writeLine("error: " & e.msg); quit(7)
  let sc = try: store.scan()
           except LatchError as e: (stderr.writeLine("error: " & e.msg); quit(7))
  echo "mandates: ", store.path
  echo "health:   ", $sc.health
  for p in sc.problems: echo "  CORRUPT: ", p
  let now = store.clock()
  for m in sc.mandates:
    let st = m.effectiveState(now)
    var left = ""
    if st in {msLatched, msSuspended}:
      left = "  expires in " & $int(m.expiresAt - now) & "s"
    echo "  ", m.id, "  ", alignLeft($st, 10), " tools=", m.tools.join(","),
         " max-effect=", $m.maxEffect, " used=", m.used, "/", m.maxActions, left
    echo "      goal: ", m.goal
    if st == msProposed:
      echo "      proposed by ", m.proposedBy, "; approve with: malyutka mandate --approve:",
           m.id, " --digest:", m.digest
    if m.reason.len > 0: echo "      reason: ", m.reason
  if sc.health == lhCorrupt: quit(7)
  quit(0)

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
  let target = if ack.len > 0: ack else: reconcile
  if target.len > 0:
    if ack.len > 0 and reconcile.len > 0:
      stderr.writeLine("error: use either --ack or --reconcile"); quit(2)
    if reconcile.len > 0 and asState notin ["COMPLETED", "FAILED", "NOT_EXECUTED"]:
      stderr.writeLine("error: --reconcile needs --as:completed|failed|not-executed"); quit(2)
    let allowed = if ack.len > 0: {asUnknownOutcome} else: {asUnknownOutcome, asAckUnresolved}
    var refusal = ""
    try:
      let j = openJournal(path, writer = "operator-" & getEnv("USER", "unknown"))
      defer: j.close()
      # Check and append under one exclusive lock: no other writer can change
      # the action in between (0.3.2 scanned, released, then appended).
      discard j.transact(proc(scan: JournalScan): JsonNode =
        if scan.health == jhCorrupt:
          refusal = "journal is CORRUPT; run `malyutka journal` first"; return nil
        var current = ""
        for a in scan.actions:
          if a.action == target: current = $a.state
        var ok = false
        for st in allowed:
          if current == $st: ok = true
        if not ok:
          refusal = target & " is " & (if current.len > 0: current else: "not in the journal") &
            (if current == $asInProgress: " (its run is still alive)"
             elif current == $asOwnerUnknown: " (cannot establish whether its run is alive; " &
               "check <state>/runs/ and the process table)"
             else: "")
          return nil
        if ack.len > 0: %*{"rec": "ack", "action": ack, "by": getEnv("USER", "operator")}
        else: %*{"rec": "reconcile", "action": reconcile, "as": asState,
                 "by": getEnv("USER", "operator")})
    except JournalError as e:
      stderr.writeLine("error: " & e.msg); quit(5)
    if refusal.len > 0:
      stderr.writeLine("error: " & refusal); quit(2)
    if ack.len > 0: echo ack, " -> ACKNOWLEDGED_UNRESOLVED (outcome still unknown)"
    else: echo reconcile, " -> RECONCILED as ", asState
    quit(0)
  let scan = try: scanJournal(path)
             except JournalError as e: (stderr.writeLine("error: " & e.msg); quit(5))
  echo "journal: ", path
  echo "health:  ", $scan.health
  for p in scan.problems: echo "  CORRUPT: ", p
  if scan.tornLines.len > 0:
    echo "  torn line(s) ", scan.tornLines.join(", "),
         ": writes interrupted by a crash; the step each guarded never proceeded"
  var unresolved, running: seq[ActionSummary]
  for a in scan.actions:
    if a.state in {asUnknownOutcome, asAckUnresolved}: unresolved.add a
    if a.state == asInProgress: running.add a
  for a in running:
    echo "  in progress (run alive): ", a.action, "  ", a.tool, " ", $a.args
  let unknownOwner = ownerUnknown(scan)
  for a in unknownOwner:
    echo "  OWNER STATUS UNKNOWN: ", a.action, "  ", a.tool, " ", $a.args,
         "  (liveness lock missing or unreadable; not reconcilable until resolved)"
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
  var pending = unknownOwner.len > 0
  for a in unresolved:
    if a.state == asUnknownOutcome: pending = true
  quit(if pending: 5 else: 0)

proc sessionsCmd() =
  var asJson = false
  var show, search = ""
  var limit = 10
  for kind, key, val in getopt(commandLineParams()[1 .. ^1]):
    if kind == cmdLongOption:
      case key
      of "json": asJson = true
      of "show": show = val
      of "search": search = val
      of "limit": limit = parseInt(val)
      else: stderr.writeLine("error: unknown option --" & key); quit(2)
  let dir = stateDir() / "sessions"
  try:
    if show.len > 0:
      let s = loadSession(resolveSession(dir, show))
      echo "session ", s.runId, "  status=", s.meta.status, "  parent=", (if s.meta.parent.len > 0: s.meta.parent else: "-")
      for m in s.messages:
        if m.role == rSystem: continue
        echo "[", $m.role, (if m.name.len > 0: " " & m.name else: ""), "] ", m.content
        for c in m.toolCalls: echo "    -> ", c.name, " ", $c.args
      quit(0)
    if search.len > 0:
      let hits = rankedSearch(dir, search, limit)
      if asJson:
        var arr = newJArray()
        for h in hits:
          arr.add %*{"run": h.runId, "score": h.score, "title": h.title, "role": h.role, "snippet": h.snippet}
        echo $arr
      else:
        for h in hits: echo h.runId, "  score=", h.score, "  [", h.role, "]  ", h.snippet
        if hits.len == 0: echo "no matches"
      quit(0)
    let all = listSessions(dir)
    if asJson:
      var arr = newJArray()
      for i in all:
        arr.add %*{"run": i.runId, "parent": i.meta.parent, "title": i.meta.title, "status": i.meta.status,
                   "provider": i.meta.provider, "model": i.meta.model, "startedAt": i.meta.startedAt,
                   "updatedAt": i.meta.updatedAt, "messages": i.messages}
      echo $arr
    else:
      if all.len == 0: echo "no sessions"
      for i in all:
        echo i.runId, "  ", alignLeft(i.meta.status, 9), " ", alignLeft(i.meta.model, 22), " ",
             (if i.meta.title.len > 0: i.meta.title else: "(untitled)")
    quit(0)
  except SessionError as e:
    stderr.writeLine("error: " & e.msg); quit(2)

proc doctor() =
  echo "malyutka: ", Version
  echo "designation: 9M14"
  echo "platform: ", hostOS, "/", hostCPU
  echo "nim: ", NimVersion
  echo "cwd: ", getCurrentDir()
  let (ok, detail) = probeBwrap()
  echo "sandbox: ", (if ok: "bwrap OK (" & detail & ")" else: "UNAVAILABLE - " & detail)
  let (sok, sdetail) = probeScopes()
  echo "limits: ", (if sok: "systemd user scope OK (--cgroups:auto applies --limit-memory/--limit-pids)"
                    else: "UNAVAILABLE - " & sdetail & " (limits are not applied; --cgroups:require would refuse)")
  let (wok, wdetail) = probeWebHelper(false)
  echo "web: ", (if wok: "helper OK (" & wdetail & ")" else: "UNAVAILABLE - " & wdetail & " (--web will not register its tools)")
  echo "journal: ", journalPath()
  if not ok:
    echo "note: --allow-shell will refuse to run until the sandbox probe passes."
    quit(3)

proc main() =
  if paramCount() == 0: usage(); quit(0)
  let cmd = paramStr(1)
  if cmd == "doctor": doctor(); quit(0)
  if cmd == "journal": journalCmd()
  if cmd == "sessions": sessionsCmd()
  if cmd == "mandate": mandateCmd()
  if cmd in ["-h", "--help", "help"]: usage(); quit(0)
  if cmd != "run": usage(); quit(2)

  var cfg = defaultConfig()
  var words: seq[string]
  var configPath = ""
  var approvalsOffAck = false
  var resumeSpec, soulFlag = ""
  var resumeDespite = false
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
        of "allow-files": cfg.allowFiles = true
        of "allow-memory": cfg.allowMemory = true
        of "skills": cfg.allowSkills = true
        of "web": cfg.allowWeb = true
        of "mcp": cfg.allowMcp = true
        of "allow-process": cfg.allowProcess = true
        of "max-processes": cfg.maxProcesses = parseInt(val)
        of "cgroups": cfg.cgroupMode = parseCgroupMode(val)
        of "limit-memory": cfg.limitMemoryMb = parseInt(val)
        of "limit-pids": cfg.limitPids = parseInt(val)
        of "context-window": cfg.contextWindow = parseInt(val)
        of "compress": cfg.compressNow = true
        of "resume": resumeSpec = val
        of "resume-despite-unknown": resumeDespite = true
        of "soul": soulFlag = val
        of "personality": cfg.personality = val.toLowerAscii
        of "approvals": cfg.approvals = parseApprovalMode(val)
        of "approval-timeout": cfg.approvalTimeoutSec = parseInt(val)
        of "i-know-approvals-off": approvalsOffAck = true
        of "unconfined-host": cfg.unconfinedHost = true
        of "shell-timeout": cfg.shellTimeoutSec = parseInt(val)
        of "max-steps": cfg.maxSteps = parseInt(val)
        of "repeat-limit": cfg.repeatLimit = parseInt(val)
        of "request-timeout": cfg.requestTimeoutSec = parseInt(val)
        of "theme": cfg.theme = parseTheme(val)
        of "json": cfg.jsonEvents = true
        of "ask-from": (cfg.askEnabled = true; cfg.askFrom = parseEffect(val))
        of "mandates": cfg.mandates = true
        of "scope-miss-limit": cfg.scopeMissLimit = parseInt(val)
        of "config": discard
        else: stderr.writeLine("error: unknown option --" & key); quit(2)
      of cmdShortOption:
        stderr.writeLine("error: unknown option -" & key); quit(2)
      of cmdArgument: words.add(key)
      of cmdEnd: discard
  except ValueError, IOError:
    stderr.writeLine("error: " & getCurrentExceptionMsg()); quit(2)
  if words.len == 0: stderr.writeLine("error: task required"); quit(2)
  if cfg.approvals == amOff and not approvalsOffAck:
    stderr.writeLine("error: --approvals:off auto-approves every ASK; pass --i-know-approvals-off to confirm")
    quit(2)
  try: discard personalitySnippet(cfg.personality)
  except ValueError as e: stderr.writeLine("error: " & e.msg); quit(2)
  cfg.stateDir = stateDir()
  if cfg.allowWeb:
    for pr in applyWebConfig(cfg): stderr.writeLine("warning: web access disabled: " & pr)
  if cfg.allowMemory:
    let (txt, problem) = loadMemory(cfg.stateDir)
    if problem.len > 0: stderr.writeLine("warning: memory ignored: " & problem)
    else: cfg.memoryText = txt
  block soul:
    let path = if soulFlag.len > 0: soulFlag else: soulPath(cfg.stateDir)
    let (txt, problem) = loadSoul(path)
    if problem.len > 0: stderr.writeLine("warning: SOUL ignored: " & problem)
    elif soulFlag.len > 0 and txt.len == 0 and not fileExists(path):
      stderr.writeLine("error: --soul file not found: " & path); quit(2)
    else: cfg.soul = txt
  if cfg.approvalTimeoutSec < 1:
    stderr.writeLine("error: --approval-timeout must be >= 1"); quit(2)
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
    let grants = newGrantStore(stateDir() / "allowlist.json")
    for pr in grants.problems:
      stderr.writeLine("warning: allowlist ignored: " & pr)
    let approver = makeApprover(cfg.approvals, grants, cfg.approvalTimeoutSec)
    let sessDir = stateDir() / "sessions"
    var history: seq[Message]
    var parentId = ""
    if resumeSpec.len > 0:
      try:
        let loaded = loadSession(resolveSession(sessDir, resumeSpec))
        parentId = loaded.runId
        history = loaded.messages
        if not resumeDespite:
          # Catch-22 made explicit: an unresolved action in this session's lineage
          # means its transcript may not match reality.
          let chain = lineage(sessDir, parentId)
          let scan = scanJournal(journalPath())
          var open: seq[string]
          for a in scan.actions:
            if a.run in chain and a.state in {asUnknownOutcome, asOwnerUnknown, asInProgress}:
              open.add a.action & " (" & a.tool & ", " & $a.state & ")"
          if open.len > 0:
            stderr.writeLine("error: refusing to resume " & parentId & ": unresolved action(s): " &
              open.join(", ") & "\n  inspect with `malyutka journal`, reconcile/ack them, or pass --resume-despite-unknown")
            quit(5)
      except SessionError as e:
        stderr.writeLine("error: " & e.msg); quit(2)
    let meta0 = SessionMeta(parent: parentId, title: task.splitLines[0][0 ..< min(task.splitLines[0].len, 80)],
                            provider: cfg.providerName, model: cfg.model, startedAt: stamp())
    let checkpoint: Checkpoint = proc(messages: seq[Message]; status: string) =
      var m = meta0
      m.status = status
      m.updatedAt = stamp()
      saveSession(sessDir / (runId & ".json"), runId, messages, m)
    var store: LatchStore = nil
    var registry = toolsFor(cfg)
    if cfg.mandates:
      store = newLatchStore(mandatePath())
      registry["propose_mandate"] = proposeMandateSpec(store, runId)
    let archive: ArchiveProc = proc(dropped: seq[Message]) =
      appendArchive(sessDir / (runId & ".archive.jsonl"), runId, dropped)
    let res = waitFor runAgent(makeProvider(cfg), task, cfg, registry = registry, sink = sink,
                               runId = runId, journal = j, approver = approver, latch = store,
                               history = history, checkpoint = checkpoint, archive = archive)
    if cfg.jsonEvents: stderr.writeLine("FINAL: " & res.answer)
    else: stderr.writeLine("\n" & res.answer)
    if res.halt != hrFinal: quit(4)
  except JournalError as e:
    stderr.writeLine("malyutka: journal refused the run: " & headline(e.msg))
    quit(5)
  except ValueError as e:
    stderr.writeLine("malyutka: " & headline(e.msg))
    quit(2)
  except LatchError as e:
    stderr.writeLine("malyutka: mandate log refused the run: " & headline(e.msg))
    quit(7)
  except ConfinementError as e:
    stderr.writeLine("malyutka: confinement unavailable, refusing to run: " & headline(e.msg))
    stderr.writeLine("  fix: apt install bubblewrap, check `malyutka doctor`, or pass --unconfined-host")
    quit(3)
  except CatchableError as e:
    stderr.writeLine("malyutka: guidance failure: " & headline(e.msg))
    quit(1)

when isMainModule:
  main()
