## Sandbox broker. Confinement is requested by the tool's realm, never by the
## model. If confinement is requested and no working backend exists, execution
## fails (invariants 5 and 6): there is no code path from a sandbox failure to
## host execution.

import std/[monotimes, os, posix, strtabs, strutils, times]

proc exitnow(code: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc c_syscall(n: clong): clong {.importc: "syscall", header: "<unistd.h>", varargs.}
proc c_prctl(option: cint): cint {.importc: "prctl", header: "<sys/prctl.h>", varargs.}
const
  SYS_close_range = 436    # same number on x86_64 and aarch64 (Linux >= 5.9)
  PR_SET_PDEATHSIG = 1.cint
# Taken from the C headers: their values differ between x86_64 and aarch64,
# and Nim 1.6's posix module does not define them.
{.passC: "-D_GNU_SOURCE".}
var
  lO_PATH {.importc: "O_PATH", header: "<fcntl.h>".}: cint
  lO_DIRECTORY {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  lO_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

type
  ConfinementError* = object of CatchableError
  WorkspaceHandle* = object
    fd*: cint      ## O_PATH directory fd: what is actually bound
    path*: string  ## canonical path of that same directory

proc bwrapPath*(): string = findExe("bwrap")

const SystemDirs* = ["/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc", "/opt"]
  ## The ONLY host paths visible inside the sandbox (read-only), besides the
  ## workspace. Allowlist, not denylist: /home, /root, /run (docker.sock, the
  ## D-Bus and systemd user sockets), /var, /mnt, /media, /srv are absent.

proc canonical*(p: string): string =
  ## realpath(3): absolute, normalized, every symlink resolved. Lexical
  ## normalization is not enough: /tmp/ws -> $HOME passes a lexical check.
  try: expandFilename(p)
  except OSError as e:
    raise newException(ConfinementError, "cannot resolve path '" & p & "': " & e.msg)

proc overlaps(a, b: string): bool =
  ## a == b, or one contains the other (both canonical).
  a == b or a.isRelativeTo(b) or b.isRelativeTo(a)

proc checkWorkspace*(workspace: string): string =
  ## Validates the RESOLVED workspace and returns its canonical path. The
  ## workspace becomes writable inside the sandbox, so it must not be or
  ## contain the operator's home, the root, or a system directory.
  let ws = canonical(workspace)
  let homeRaw = getHomeDir().normalizedPath
  let home = (if dirExists(homeRaw): canonical(homeRaw) else: homeRaw)
  if ws == "/":
    raise newException(ConfinementError, "refusing workspace '/'")
  if ws == home or home.isRelativeTo(ws):
    raise newException(ConfinementError,
      "refusing workspace '" & ws & "': it is or contains $HOME (" & home & ")")
  for d in SystemDirs:
    let cd = (if dirExists(d) or symlinkExists(d): canonical(d) else: d)
    if overlaps(ws, d) or overlaps(ws, cd):
      raise newException(ConfinementError,
        "refusing workspace '" & ws & "': overlaps system directory " & d)
  for d in ["/run", "/proc", "/sys", "/dev"]:
    if ws == d or ws.isRelativeTo(d):
      raise newException(ConfinementError, "refusing workspace '" & ws & "' under " & d)
  ws

proc fdPath(fd: cint): string =
  try: expandSymlink("/proc/self/fd/" & $fd)
  except OSError as e:
    raise newException(ConfinementError, "cannot read back workspace fd: " & e.msg)

proc openWorkspace*(workspace: string): WorkspaceHandle =
  ## Opens the workspace as an O_PATH fd and validates WHAT WAS OPENED (via
  ## /proc/self/fd), not the path string. The same fd is handed to bwrap
  ## (--bind-fd), so no path is resolved twice: a symlink swapped in after the
  ## check cannot redirect the bind.
  let canon = checkWorkspace(workspace)
  let fd = posix.open(cstring(canon), lO_PATH or lO_DIRECTORY or O_CLOEXEC or lO_NOFOLLOW)
  if fd < 0:
    raise newException(ConfinementError,
      "cannot open workspace '" & canon & "': " & $strerror(errno))
  let opened = fdPath(fd)
  try:
    if checkWorkspace(opened) != canon:
      raise newException(ConfinementError,
        "workspace changed while opening: '" & canon & "' is now '" & opened & "'")
  except ConfinementError:
    discard posix.close(fd)
    raise
  WorkspaceHandle(fd: fd, path: canon)

proc close*(h: WorkspaceHandle) =
  if h.fd >= 0: discard posix.close(h.fd)

proc bwrapArgv*(wsPath: string; command: string): seq[string] =
  ## Empty tmpfs root; allowlisted system dirs read-only; private /dev, /proc,
  ## /tmp; the workspace read-write FROM FD 3 (see openWorkspace); all
  ## namespaces unshared (network included). Merged-/usr symlinks
  ## (/bin -> usr/bin) are recreated as symlinks.
  ## ORDER MATTERS: /tmp is mounted before the workspace bind, otherwise a
  ## workspace located under /tmp is hidden by the tmpfs.
  for d in SystemDirs:
    if symlinkExists(d):
      result.add ["--symlink", expandSymlink(d), d]
    elif dirExists(d):
      result.add ["--ro-bind", d, d]
  result.add ["--dev", "/dev",
              "--proc", "/proc",
              "--tmpfs", "/tmp",
              "--bind-fd", "3", wsPath,
              "--unshare-all",          # net, pid, ipc, uts, user, cgroup
              "--die-with-parent",
              "--new-session",
              "--chdir", wsPath,
              "--", "/bin/sh", "-c", command]

proc scrubbedEnv*(home: string): StringTableRef =
  ## Invariant 9: child processes never inherit the harness environment, which
  ## holds provider credentials (MALYUTKA_API_KEY etc.). Only an allowlist of
  ## inert variables passes through.
  result = newStringTable(modeCaseSensitive)
  result["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  result["HOME"] = home
  result["LANG"] = getEnv("LANG", "C.UTF-8")
  result["TERM"] = "dumb"

proc spawnClean(argv: seq[string]; env: StringTableRef; workingDir: string;
                keepFd: cint; hostTree: bool): tuple[pid: Pid, outFd: cint] =
  ## fork + execve with fd hygiene that osproc.startProcess cannot provide:
  ## stdin is /dev/null, stdout+stderr share one pipe, and EVERY other fd is
  ## closed before exec, except `keepFd`, which is moved to fd 3 (the
  ## workspace for bwrap --bind-fd). With hostTree, the child leads a new
  ## session/process group (so the whole tree can be killed) and dies if the
  ## harness dies. Only async-signal-safe calls run between fork and exec.
  var pipeFds: array[2, cint]
  if pipe(pipeFds) != 0: raiseOSError(osLastError(), "pipe")
  discard fcntl(pipeFds[0], F_SETFD, FD_CLOEXEC)
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
    if hostTree:
      if setsid() < 0: exitnow(126)
      if c_prctl(PR_SET_PDEATHSIG, SIGKILL.culong) != 0: exitnow(126)
    let nul = posix.open(devnull, O_RDONLY)
    if nul < 0 or dup2(nul, 0) < 0 or dup2(pipeFds[1], 1) < 0 or dup2(pipeFds[1], 2) < 0:
      exitnow(126)
    var firstToClose = 3.cuint
    if keepFd >= 0:
      if keepFd == 3:
        if fcntl(3, F_SETFD, 0) < 0: exitnow(126)    # clear CLOEXEC
      elif dup2(keepFd, 3) < 0: exitnow(126)         # dup2 clears CLOEXEC
      firstToClose = 4
    if c_syscall(SYS_close_range, firstToClose, high(cuint), 0.cuint) != 0:
      for fd in firstToClose.cint .. 65535.cint: discard posix.close(fd)
    if workingDir.len > 0 and chdir(cwd) != 0: exitnow(126)
    discard execve(exe, cargv, cenv)
    exitnow(127)
  # ---- parent ----
  discard posix.close(pipeFds[1])
  deallocCStringArray(cargv); deallocCStringArray(cenv)
  (pid, pipeFds[0])

proc decodeStatus(status: cint): int =
  if WIFEXITED(status): WEXITSTATUS(status).int
  elif WIFSIGNALED(status): 128 + WTERMSIG(status).int
  else: -1

proc runBounded*(argv: seq[string]; timeoutSec, maxBytes: int; workingDir = "";
                 keepFd: cint = -1; hostTree = false):
    tuple[output: string, exitCode: int, truncated, timedOut: bool] =
  ## Runs argv as a DIRECT child of the harness, so bwrap's --die-with-parent
  ## binds the sandbox's lifetime to Malyutka's (even across SIGKILL). The
  ## wall-clock limit is enforced here with poll(2); at most maxBytes of
  ## combined output are kept and the rest is drained.
  ## hostTree (host realm): when the command exits or times out, its whole
  ## process group is killed, so background children do not outlive it.
  let home = if workingDir.len > 0: absolutePath(workingDir) else: getCurrentDir()
  let (pid, fd) = spawnClean(argv, scrubbedEnv(home), workingDir, keepFd, hostTree)
  defer: discard posix.close(fd)
  let deadline = getMonoTime() + initDuration(seconds = timeoutSec)
  var buf = newStringOfCap(min(maxBytes, 1 shl 16))
  var chunk: array[4096, char]
  var truncated, timedOut, reaped = false
  var status: cint

  proc msLeft(): int = int((deadline - getMonoTime()).inMilliseconds)
  proc reap(block_ok: bool): bool =
    while true:
      let w = waitpid(pid, status, (if block_ok: 0.cint else: WNOHANG))
      if w == pid: return true
      if w < 0 and errno == EINTR: continue
      return false

  while true:
    let left = msLeft()
    if left <= 0:
      timedOut = true
      break
    var pfd = TPollfd(fd: fd, events: POLLIN)
    let r = poll(addr pfd, 1, cint(min(left, 100)))
    if r < 0:
      if errno == EINTR: continue
      break
    if r == 0:
      # Host realm: a background child may hold the pipe open after the
      # command itself exits; reap the leader, then kill the rest of its group.
      if hostTree and not reaped and reap(false):
        reaped = true
        discard posix.kill(-pid, SIGKILL)
      continue
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

  # Output closed (or deadline hit); the leader may still be running.
  while not timedOut and not reaped:
    if reap(false): reaped = true
    elif msLeft() <= 0: timedOut = true
    else: sleep(10)
  if not reaped:
    # Sandbox: SIGKILL bwrap -> PDEATHSIG tears down the PID namespace.
    # Host: SIGKILL the whole process group.
    discard posix.kill((if hostTree: -pid else: pid), SIGKILL)
    discard reap(true)
  if hostTree:
    discard posix.kill(-pid, SIGKILL)     # stragglers left in the group
  (buf, decodeStatus(status), truncated, timedOut)

proc probeBwrap*(): tuple[ok: bool, detail: string] =
  ## Functional probe of the exact sandbox shape used for tools, including
  ## --bind-fd: Ubuntu 24.04 can restrict unprivileged user namespaces via
  ## AppArmor, so `which bwrap` is not enough.
  let exe = bwrapPath()
  if exe.len == 0: return (false, "bwrap not found in PATH (apt install bubblewrap)")
  let probeWs = getTempDir() / "malyutka-probe-" & $getCurrentProcessId()
  try:
    createDir(probeWs)
    defer: removeDir(probeWs)
    let h = openWorkspace(probeWs)
    defer: h.close()
    let r = runBounded(@[exe] & bwrapArgv(h.path, "true"), 10, 4096, "", h.fd)
    if r.exitCode == 0: (true, exe)
    else: (false, "bwrap present but unusable (exit " & $r.exitCode & "): " & r.output.strip)
  except CatchableError as e:
    (false, "bwrap probe failed: " & e.msg)
