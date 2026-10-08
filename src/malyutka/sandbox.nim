## Sandbox broker. Confinement is requested by the tool's realm, never by the
## model. If confinement is requested and no working backend exists, execution
## fails (invariants 5 and 6): there is no code path from a sandbox failure to
## host execution.

import std/[monotimes, os, osproc, posix, strtabs, strutils, times]

proc exitnow(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}

type ConfinementError* = object of CatchableError

proc bwrapPath*(): string = findExe("bwrap")

const SystemDirs* = ["/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc", "/opt"]
  ## The ONLY host paths visible inside the sandbox (read-only), besides the
  ## workspace. Allowlist, not denylist: /home, /root, /run (docker.sock, the
  ## D-Bus and systemd user sockets), /var, /mnt, /media, /srv are absent.

proc checkWorkspace*(workspace: string) =
  ## The workspace becomes writable inside the sandbox, so it must not be (or
  ## contain) the operator's home, the filesystem root, or a system directory.
  let ws = absolutePath(workspace).normalizedPath
  let home = getHomeDir().normalizedPath
  if ws == "/" or ws == "":
    raise newException(ConfinementError, "refusing workspace '/'")
  if ws == home or home.isRelativeTo(ws):
    raise newException(ConfinementError,
      "refusing workspace '" & ws & "': it is or contains $HOME (" & home & ")")
  for d in SystemDirs:
    if ws == d or ws.isRelativeTo(d) or d.isRelativeTo(ws):
      raise newException(ConfinementError,
        "refusing workspace '" & ws & "': overlaps system directory " & d)
  for d in ["/run", "/proc", "/sys", "/dev"]:
    if ws == d or ws.isRelativeTo(d):
      raise newException(ConfinementError, "refusing workspace '" & ws & "' under " & d)

proc bwrapArgv*(workspace: string; command: string): seq[string] =
  ## Empty tmpfs root; allowlisted system dirs read-only; private /dev, /proc,
  ## /tmp; the workspace read-write; all namespaces unshared (network included).
  ## Merged-/usr symlinks (/bin -> usr/bin) are recreated as symlinks.
  ## ORDER MATTERS: /tmp is mounted before the workspace bind, otherwise a
  ## workspace located under /tmp is hidden by the tmpfs.
  let ws = absolutePath(workspace).normalizedPath
  for d in SystemDirs:
    if symlinkExists(d):
      result.add ["--symlink", expandSymlink(d), d]
    elif dirExists(d):
      result.add ["--ro-bind", d, d]
  result.add ["--dev", "/dev",
              "--proc", "/proc",
              "--tmpfs", "/tmp",
              "--bind", ws, ws,
              "--unshare-all",          # net, pid, ipc, uts, user, cgroup
              "--die-with-parent",
              "--new-session",
              "--chdir", ws,
              "--", "/bin/sh", "-c", command]

proc probeBwrap*(): tuple[ok: bool, detail: string] =
  ## Functional probe of the exact sandbox shape used for tools: Ubuntu 24.04
  ## can restrict unprivileged user namespaces via AppArmor, so `which bwrap`
  ## is not enough.
  let exe = bwrapPath()
  if exe.len == 0: return (false, "bwrap not found in PATH (apt install bubblewrap)")
  let probeWs = getTempDir() / "malyutka-probe-" & $getCurrentProcessId()
  try:
    createDir(probeWs)
    defer: removeDir(probeWs)
    let (output, code) = execCmdEx(quoteShellCommand(@[exe] & bwrapArgv(probeWs, "true")))
    if code == 0: (true, exe)
    else: (false, "bwrap present but unusable (exit " & $code & "): " & output.strip)
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

proc c_syscall(n: clong): clong {.importc: "syscall", header: "<unistd.h>", varargs.}
const SYS_close_range = 436   # same number on x86_64 and aarch64 (Linux >= 5.9)

proc spawnClean(argv: seq[string]; env: StringTableRef; workingDir: string):
    tuple[pid: Pid, outFd: cint] =
  ## fork + execve with fd hygiene that osproc.startProcess cannot provide:
  ## stdin is /dev/null, stdout+stderr share one pipe, and EVERY other fd is
  ## closed before exec, so no harness fd (files, sockets, pipes) can cross
  ## into the child and bypass the sandbox's mount namespace. Only
  ## async-signal-safe calls run between fork and exec.
  var pipeFds: array[2, cint]
  if pipe(pipeFds) != 0: raiseOSError(osLastError(), "pipe")
  var envSeq: seq[string]
  for k, v in env: envSeq.add k & "=" & v
  let cargv = allocCStringArray(argv)
  let cenv = allocCStringArray(envSeq)
  let devnull: cstring = "/dev/null"
  let cwd = workingDir.cstring
  let exe = argv[0].cstring
  let pid = fork()
  if pid < 0:
    deallocCStringArray(cargv); deallocCStringArray(cenv)
    raiseOSError(osLastError(), "fork")
  if pid == 0:
    # ---- child: async-signal-safe only ----
    let nul = posix.open(devnull, O_RDONLY)
    if nul < 0 or dup2(nul, 0) < 0 or dup2(pipeFds[1], 1) < 0 or dup2(pipeFds[1], 2) < 0:
      exitnow(126)
    if c_syscall(SYS_close_range, 3.cuint, high(cuint), 0.cuint) != 0:
      for fd in 3.cint .. 65535.cint: discard posix.close(fd)
    if workingDir.len > 0 and chdir(cwd) != 0: exitnow(126)
    discard execve(exe, cargv, cenv)
    exitnow(127)
  # ---- parent ----
  discard posix.close(pipeFds[1])
  discard fcntl(pipeFds[0], F_SETFD, FD_CLOEXEC)
  deallocCStringArray(cargv); deallocCStringArray(cenv)
  (pid, pipeFds[0])

proc decodeStatus(status: cint): int =
  if WIFEXITED(status): WEXITSTATUS(status).int
  elif WIFSIGNALED(status): 128 + WTERMSIG(status).int
  else: -1

proc runBounded*(argv: seq[string]; timeoutSec, maxBytes: int; workingDir = ""):
    tuple[output: string, exitCode: int, truncated, timedOut: bool] =
  ## Runs argv as a DIRECT child of the harness, so bwrap's --die-with-parent
  ## binds the sandbox's lifetime to Malyutka's (even across SIGKILL). The
  ## wall-clock limit is enforced here with poll(2); at most maxBytes of
  ## combined output are kept and the rest is drained.
  let home = if workingDir.len > 0: absolutePath(workingDir) else: getCurrentDir()
  let (pid, fd) = spawnClean(argv, scrubbedEnv(home), workingDir)
  defer: discard posix.close(fd)
  let deadline = getMonoTime() + initDuration(seconds = timeoutSec)
  var buf = newStringOfCap(min(maxBytes, 1 shl 16))
  var chunk: array[4096, char]
  var truncated, timedOut = false
  var status: cint
  var reaped = false

  proc msLeft(): int = int((deadline - getMonoTime()).inMilliseconds)

  while true:
    let left = msLeft()
    if left <= 0:
      timedOut = true
      break
    var pfd = TPollfd(fd: fd, events: POLLIN)
    let r = poll(addr pfd, 1, cint(min(left, 250)))
    if r < 0:
      if errno == EINTR: continue
      break
    if r == 0: continue
    let n = posix.read(fd, addr chunk[0], chunk.len)
    if n < 0:
      if errno == EINTR or errno == EAGAIN: continue
      break
    if n == 0: break                      # EOF: every writer closed stdout
    let room = maxBytes - buf.len
    if room <= 0:
      truncated = true
    elif n > room:
      for i in 0 ..< room: buf.add chunk[i]
      truncated = true
    else:
      for i in 0 ..< n: buf.add chunk[i]

  # Output closed (or deadline hit); the process may still be running.
  while not timedOut and not reaped:
    let w = waitpid(pid, status, WNOHANG)
    if w == pid: reaped = true
    elif w < 0 and errno != EINTR: break
    elif msLeft() <= 0: timedOut = true
    else: sleep(10)
  if not reaped:
    discard posix.kill(pid, SIGKILL)       # bwrap dies -> PDEATHSIG tears down the sandbox
    while waitpid(pid, status, 0) < 0 and errno == EINTR: discard
  (buf, decodeStatus(status), truncated, timedOut)
