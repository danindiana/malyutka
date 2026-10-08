## Sandbox broker. Confinement is requested by the tool's realm, never by the
## model. If confinement is requested and no working backend exists, execution
## fails (invariants 5 and 6): there is no code path from a sandbox failure to
## host execution.

import std/[os, osproc, streams, strtabs]

type ConfinementError* = object of CatchableError

proc bwrapPath*(): string = findExe("bwrap")

proc bwrapArgv*(workspace: string; command: string): seq[string] =
  ## Read-only root, writable workspace, private /tmp, no network, own PID/IPC
  ## namespaces. ORDER MATTERS: the /tmp tmpfs is mounted before the workspace
  ## bind, otherwise a workspace located under /tmp is hidden by the tmpfs.
  let ws = absolutePath(workspace)
  @["--ro-bind", "/", "/",
    "--dev", "/dev",
    "--proc", "/proc",
    "--tmpfs", "/tmp",
    "--bind", ws, ws,
    "--unshare-all",          # includes network
    "--die-with-parent",
    "--new-session",
    "--chdir", ws,
    "--", "/bin/sh", "-c", command]

proc probeBwrap*(): tuple[ok: bool, detail: string] =
  ## Functional probe, not just presence: Ubuntu 24.04 can restrict
  ## unprivileged user namespaces via AppArmor, so `which bwrap` is not enough.
  let exe = bwrapPath()
  if exe.len == 0: return (false, "bwrap not found in PATH (apt install bubblewrap)")
  try:
    let (output, code) = execCmdEx(quoteShellCommand(
      @[exe, "--ro-bind", "/", "/", "--unshare-all", "--die-with-parent", "--", "/bin/true"]))
    if code == 0: (true, exe)
    else: (false, "bwrap present but unusable (exit " & $code & "): " & output)
  except OSError as e:
    (false, "bwrap probe failed: " & e.msg)

proc scrubbedEnv*(home: string): StringTableRef =
  ## Invariant 9: child processes never inherit the harness environment, which
  ## holds provider credentials (MALYUTKA_API_KEY etc.). Only an allowlist of
  ## inert variables passes through.
  result = newStringTable(modeCaseSensitive)
  result["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  result["HOME"] = home
  result["LANG"] = getEnv("LANG", "C.UTF-8")
  result["TERM"] = "dumb"

proc runBounded*(argv: seq[string]; timeoutSec, maxBytes: int; workingDir = ""):
    tuple[output: string, exitCode: int, truncated, timedOut: bool] =
  ## Runs argv (no harness-side shell interpolation) under coreutils `timeout`,
  ## keeping at most maxBytes of combined output while draining the rest.
  let timeoutExe = findExe("timeout")
  if timeoutExe.len == 0:
    raise newException(ConfinementError, "coreutils `timeout` not found")
  var args = @["-k", "2", $timeoutSec]
  args.add argv
  let home = if workingDir.len > 0: absolutePath(workingDir) else: getCurrentDir()
  let p = startProcess(timeoutExe, workingDir = workingDir, args = args,
                       env = scrubbedEnv(home), options = {poStdErrToStdOut})
  defer: p.close()
  let s = p.outputStream
  var buf = newStringOfCap(min(maxBytes, 1 shl 16))
  var truncated = false
  while not s.atEnd:
    let chunk = s.readStr(4096)
    if chunk.len == 0: break
    if buf.len < maxBytes:
      let room = maxBytes - buf.len
      if chunk.len > room:
        buf.add chunk[0 ..< room]
        truncated = true
      else:
        buf.add chunk
    else:
      truncated = true
  let code = p.waitForExit()
  (buf, code, truncated, code == 124 or code == 137)
