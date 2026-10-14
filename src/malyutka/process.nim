## Background processes (SPEC-008, invariant 16). One `process` tool with actions
## start/poll/log/kill/list. Processes run in the same bwrap sandbox as `shell`,
## are DIRECT children of the harness (so --die-with-parent ties them to its
## life), and are all killed when the run ends.

import std/[json, posix, strutils, times]
import ./[types, sandbox]

const
  MaxKeep = 64 * 1024        ## ring of the last bytes kept per process
  MaxPollBytes = 8 * 1024    ## returned per poll; the rest stays pending
  MaxCommand = 8 * 1024

type
  BgProc = ref object
    id, command: string
    h: BgHandle
    buf: string
    total: int               ## bytes ever read
    cursor: int              ## total at the last poll
    eof: bool
    exited, announced: bool
    code: int
    started: float
  ProcManager* = ref object
    procs: seq[BgProc]
    counter: int
    maxRunning: int

proc newProcManager*(maxRunning: int): ProcManager =
  ProcManager(maxRunning: max(1, maxRunning))

proc refresh(p: BgProc) =
  if not p.eof:
    var got = ""
    p.eof = not drainBackground(p.h, got)
    if got.len > 0:
      p.buf.add got
      p.total += got.len
      if p.buf.len > MaxKeep: p.buf.delete(0 .. p.buf.len - MaxKeep - 1)
  if not p.exited:
    let (ex, code) = pollExit(p.h.pid)
    if ex:
      p.exited = true
      p.code = code
      # the last bytes may arrive just after the exit
      var tail = ""
      discard drainBackground(p.h, tail)
      if tail.len > 0:
        p.buf.add tail
        p.total += tail.len
        if p.buf.len > MaxKeep: p.buf.delete(0 .. p.buf.len - MaxKeep - 1)

proc running(m: ProcManager): int =
  for p in m.procs:
    refresh(p)
    if not p.exited: inc result

proc find(m: ProcManager; id: string): BgProc =
  for p in m.procs:
    if p.id == id: return p
  nil

proc state(p: BgProc): string =
  if p.exited: "exited " & $p.code else: "running"

proc effectOfProcess*(args: JsonNode): EffectClass =
  ## Per call: only `start` creates anything (B2); `kill` touches our own children
  ## (B1); the rest only read.
  let a = if args.kind == JObject and args.hasKey("action") and args["action"].kind == JString: args["action"].getStr else: ""
  case a
  of "start": b2BroadWorkspace
  of "kill": b1LocalReversible
  else: b0ReadOnly

proc fail(msg: string): ToolResult = ToolResult(ok: false, output: "ERROR: " & msg, exitCode: 1)

proc strArg(args: JsonNode; k: string): string =
  if args.kind == JObject and args.hasKey(k) and args[k].kind == JString: args[k].getStr else: ""

proc takeOutput(p: BgProc; fromPos: int; limit: int): tuple[text: string, next: int, dropped: int] =
  let start = p.total - p.buf.len
  var pos = fromPos
  if pos < start:
    result.dropped = start - pos
    pos = start
  let avail = p.total - pos
  let n = min(avail, limit)
  result.text = p.buf[(pos - start) ..< (pos - start + n)]
  result.next = pos + n

proc runProcess*(m: ProcManager; args: JsonNode; cfg: AgentConfig): ToolResult =
  let action = strArg(args, "action")
  case action
  of "start":
    let cmd = strArg(args, "command")
    if cmd.len == 0: return fail("missing string argument: command")
    if cmd.len > MaxCommand: return fail("command is longer than " & $MaxCommand & " bytes")
    if m.running >= m.maxRunning:
      return fail("already " & $m.maxRunning & " processes running; kill one first")
    let exe = bwrapPath()
    if exe.len == 0: raise newException(ConfinementError, "sandbox requested but bwrap unavailable")
    let ws = openWorkspace(cfg.cwd)
    defer: ws.close()
    let (argv, extra) = sandboxCommand(exe, ws.path, cmd, cfg.scopeActive, cfg.unitPrefix,
                                       "ps", cfg.limitMemoryMb, cfg.limitPids)
    let h = startBackground(argv, ws.path, ws.fd, extra)
    inc m.counter
    let p = BgProc(id: "p" & $m.counter, command: cmd, h: h, started: epochTime())
    m.procs.add p
    return ToolResult(ok: true, exitCode: 0, output: "started " & p.id & " (pid " & $int(h.pid) & ")",
      eventKind: "process.started",
      eventPayload: %*{"process": p.id, "command": cmd, "pid": int(h.pid)})
  of "poll", "log":
    let p = m.find(strArg(args, "id"))
    if p == nil: return fail("no such process: " & strArg(args, "id"))
    let wasExited = p.exited
    refresh(p)
    var o: tuple[text: string, next: int, dropped: int]
    if action == "poll":
      o = takeOutput(p, p.cursor, MaxPollBytes)
      p.cursor = o.next
    else:
      let tail = if args.kind == JObject and args.hasKey("tail") and args["tail"].kind == JInt: clamp(args["tail"].getInt, 1, MaxKeep) else: 2000
      o = takeOutput(p, max(0, p.total - tail), MaxPollBytes)
    var text = p.id & " " & p.state & "\n" & o.text
    if o.dropped > 0: text.add "\n[malyutka: " & $o.dropped & " earlier bytes were dropped from the output ring]"
    if action == "poll" and p.total > p.cursor: text.add "\n[malyutka: " & $(p.total - p.cursor) & " more bytes pending; poll again]"
    result = ToolResult(ok: true, exitCode: 0, output: text)
    if p.exited and not wasExited and not p.announced:
      p.announced = true
      result.eventKind = "process.exited"
      result.eventPayload = %*{"process": p.id, "exitCode": p.code}
  of "kill":
    let p = m.find(strArg(args, "id"))
    if p == nil: return fail("no such process: " & strArg(args, "id"))
    refresh(p)
    if not p.exited:
      p.code = killBackground(p.h)
      p.exited = true
      refresh(p)
    p.announced = true
    result = ToolResult(ok: true, exitCode: 0, output: p.id & " " & p.state,
      eventKind: "process.exited", eventPayload: %*{"process": p.id, "exitCode": p.code, "killed": true})
  of "list":
    var lines: seq[string]
    for p in m.procs:
      refresh(p)
      let cmd = if p.command.len > 60: p.command[0 ..< 60] & "…" else: p.command
      lines.add p.id & "  " & p.state & "  " & $int(epochTime() - p.started) & "s  " & cmd
    return ToolResult(ok: true, exitCode: 0, output: (if lines.len == 0: "no processes" else: lines.join("\n")))
  else:
    return fail("action must be start, poll, log, kill or list")

proc shutdown*(m: ProcManager): int =
  ## Kills everything still running; returns how many. Idempotent.
  for p in m.procs:
    refresh(p)
    if not p.exited:
      p.code = killBackground(p.h)
      p.exited = true
      inc result
    closeBackground(p.h)
  m.procs.setLen(0)

proc pids*(m: ProcManager): seq[Pid] =
  for p in m.procs: result.add p.h.pid
