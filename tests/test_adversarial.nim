## Adversarial containment tests: each test is an escape attempt a
## prompt-injected model could make with the shell tool. The tests set up the
## host-side bait themselves and clean it up. Skipped if bwrap is unusable.

import std/[json, os, osproc, posix, strutils, tables, unittest]
import malyutka/[types, tools, sandbox]

# Private per-process scratch dir: never fixed names in shared /tmp.
let testTmp = getTempDir() / ("malyutka-t-" & $getCurrentProcessId())
createDir(testTmp)

let (bwOk, bwDetail) = probeBwrap()
let baitDir = getHomeDir() / ".malyutka-bait"
let ws = testTmp / "malyutka-adv-ws"

proc cfgFor(dir: string): AgentConfig =
  result = baseConfig()
  result.allowShell = true
  result.cwd = dir
  result.shellTimeoutSec = 5

proc sh(cmd: string; dir = ws): ToolResult =
  let c = cfgFor(dir)
  toolsFor(c)["shell"].run(%*{"command": cmd}, c)

if not bwOk:
  echo "  [SKIP] adversarial suite: ", bwDetail
else:
  createDir(ws)
  createDir(baitDir)
  writeFile(baitDir / "id_secret", "SECRET-KEY-MATERIAL")

  suite "containment: confidentiality":
    test "operator home is not visible":
      let r = sh("cat " & quoteShell(baitDir / "id_secret") & "; ls " & quoteShell(getHomeDir()))
      check "SECRET-KEY-MATERIAL" notin r.output

    test "/root, /run, /var, /mnt, /media, /srv are not mounted":
      let r = sh("for d in /root /run /var /mnt /media /srv; do [ -e $d ] && ls -A $d | head -1 && echo \"VISIBLE $d\"; done; true")
      check "VISIBLE" notin r.output

    test "symlink in the workspace cannot reach outside files":
      removeFile(ws / "lnk")
      createSymlink(baitDir / "id_secret", ws / "lnk")
      let r = sh("cat lnk")
      check "SECRET-KEY-MATERIAL" notin r.output
      removeFile(ws / "lnk")

    test "inherited file descriptors do not cross into the sandbox":
      # A non-CLOEXEC fd open in the harness would bypass the mount namespace.
      let fd = posix.open(cstring(baitDir / "id_secret"), O_RDONLY)
      check fd >= 0
      defer: discard posix.close(fd)
      # NB: an earlier version of this test passed vacuously: `cat` on fd 0
      # blocked on the harness's stdin pipe until the timeout. Now we list fds
      # without reading them, then read only regular files.
      let r = sh("ls /proc/self/fd | tr '\\n' ' '; echo; " &
                 "for f in /proc/self/fd/*; do [ -f \"$f\" ] && cat \"$f\"; done; echo END")
      check "SECRET-KEY-MATERIAL" notin r.output
      check "END" in r.output
      checkpoint "fds inside: " & r.output.splitLines[0]
      check r.output.splitLines[0].strip.split(' ').len <= 4   # 0 1 2 + ls's own dirfd

    test "stdin is /dev/null, so stdin readers do not hang":
      var c = cfgFor(ws); c.shellTimeoutSec = 3
      let r = toolsFor(c)["shell"].run(%*{"command": "cat; wc -c < /dev/stdin; echo ok"}, c)
      check not r.timedOut
      check "ok" in r.output

  suite "containment: integrity":
    test "system directories are read-only":
      let r = sh("touch /etc/malyutka-x /usr/malyutka-x 2>&1; echo done")
      check "done" in r.output
      check not fileExists("/etc/malyutka-x")
      check not fileExists("/usr/malyutka-x")

    test "symlink in the workspace cannot write outside":
      let target = baitDir / "written-through-symlink"
      removeFile(ws / "wl")
      createSymlink(target, ws / "wl")
      discard sh("echo pwned > wl")
      check not fileExists(target)
      removeFile(ws / "wl")

    test "hard link from outside into the workspace fails":
      discard sh("ln /etc/hostname hl 2>&1; ln /usr/bin/env hl2 2>&1; true")
      check not fileExists(ws / "hl")
      check not fileExists(ws / "hl2")

    test "workspace must not be or contain $HOME, /, or a system dir":
      for bad in [getHomeDir(), "/", "/etc", "/usr/local", "/run/x", parentDir(getHomeDir())]:
        expect ConfinementError: checkWorkspace(bad)
      checkWorkspace(ws)   # fine

  suite "containment: communication":
    test "host unix sockets are unreachable":
      # A listening socket in the operator's home stands in for docker.sock,
      # the D-Bus session bus or an ssh-agent socket.
      let sockPath = baitDir / "agent.sock"
      removeFile(sockPath)
      let srv = startProcess("/usr/bin/python3", args = ["-I", "-c",
        "import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.listen(1);" &
        "s.settimeout(4)\ntry:\n c,_=s.accept();c.sendall(b'HOST-SOCKET-REACHED')\nexcept Exception: pass",
        sockPath], options = {})
      sleep(400)
      let r = sh("python3 -I -c \"import socket;s=socket.socket(socket.AF_UNIX);s.connect('" &
        sockPath & "');print(s.recv(64).decode())\" 2>&1; true")
      check "HOST-SOCKET-REACHED" notin r.output
      srv.terminate(); discard srv.waitForExit(); srv.close()
      removeFile(sockPath)

    test "no network interfaces besides loopback":
      let r = sh("cat /proc/net/dev")
      for line in r.output.splitLines:
        if ":" in line: check line.strip.startsWith("lo:")

  suite "containment: lifetime":
    test "background processes die with the command":
      discard sh("(sleep 30; touch late-bg) >/dev/null 2>&1 & echo started")
      sleep(300)
      let (o, _) = execCmdEx("pgrep -af '[s]leep 30; touch late-bg'")
      checkpoint "survivors: " & o
      check o.strip.len == 0

    test "timeout kills the whole sandbox, including detached children":
      var c = cfgFor(ws); c.shellTimeoutSec = 1
      let r = toolsFor(c)["shell"].run(%*{"command":
        "setsid sh -c 'sleep 20; touch late-setsid' & sleep 20"}, c)
      check r.timedOut
      sleep(300)
      let (o, _) = execCmdEx("pgrep -af '[s]leep 20; touch late-setsid'")
      checkpoint "survivors: " & o
      check o.strip.len == 0

    test "privilege: no new privileges, no host uid 0 capabilities":
      let r = sh("grep -E '^(NoNewPrivs|CapEff)' /proc/self/status")
      check "NoNewPrivs:\t1" in r.output

  removeDir(ws)
  removeDir(baitDir)

removeDir(testTmp)
