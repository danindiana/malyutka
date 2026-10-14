## `malyutka web-setup`: start a local SearXNG (docker, bound to loopback only) with the json format
## enabled and write the matching <state>/web.json, so web_search works with no account and no key.
## The pure parts (settings text, web.json text) are testable; the docker part is a thin wrapper.

import std/[httpclient, json, os, osproc, strutils, streams, times]
import ./memory

const
  DefaultSearxPort* = 18888
  ContainerName* = "malyutka-searx"
  Image* = "searxng/searxng:latest"

proc defaultSearxUrl*(port = DefaultSearxPort): string = "http://127.0.0.1:" & $port

proc searxSettings*(secret: string): string =
  ## Minimal settings: defaults plus the json format (SearXNG answers 403 without it) and no rate
  ## limiter (the instance is reachable from loopback only).
  "use_default_settings: true\n" &
  "server:\n  secret_key: \"" & secret & "\"\n  limiter: false\n  bind_address: \"0.0.0.0\"\n" &
  "search:\n  formats:\n    - html\n    - json\n"

proc webJsonFor*(url: string; trustAllow: bool): string =
  $(%*{"search": {"backend": "searxng", "searxng": {"url": url, "trust": (if trustAllow: "allow" else: "ask")}}}) & "\n"

proc randomSecret(): string =
  var b: array[16, byte]
  let f = open("/dev/urandom")
  defer: close(f)
  if f.readBytes(b, 0, 16) != 16: raise newException(IOError, "cannot read /dev/urandom")
  for x in b: result.add toHex(int(x), 2).toLowerAscii

proc run(args: seq[string]): tuple[output: string, code: int] =
  let p = startProcess(args[0], args = args[1 .. ^1], options = {poUsePath, poStdErrToStdout})
  result.output = p.outputStream.readAll
  result.code = p.waitForExit
  p.close

proc ready(url: string): bool =
  let c = newHttpClient(timeout = 3000)
  defer: c.close
  try:
    let r = c.get(url & "/search?q=test&format=json")
    r.code.int == 200
  except CatchableError: false

proc webSetup*(stateDir: string; port: int; trustAllow: bool): int =
  ## Returns the process exit code. Never overwrites an existing web.json.
  if findExe("docker").len == 0:
    stderr.writeLine "web-setup needs docker. Without it, run your own SearXNG with `json` in search.formats and point"
    stderr.writeLine "search.searxng.url in " & (stateDir / "web.json") & " at it (see spec/SPEC-011-web-access.md)."
    return 2
  let dir = stateDir / "searxng"
  let settings = dir / "settings.yml"
  try:
    if not fileExists(settings): writePrivate(settings, searxSettings(randomSecret()))
    setFilePermissions(dir, {fpUserExec, fpUserRead, fpUserWrite})
    setFilePermissions(settings, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})   # the container user must read it
  except CatchableError as e:
    stderr.writeLine "cannot write " & settings & ": " & e.msg
    return 1
  discard run(@["docker", "rm", "-f", ContainerName])
  let (outp, code) = run(@["docker", "run", "-d", "--restart", "unless-stopped", "--name", ContainerName,
                           "-p", "127.0.0.1:" & $port & ":8080", "-v", settings & ":/etc/searxng/settings.yml:ro", Image])
  if code != 0:
    stderr.writeLine "docker run failed:\n" & outp
    return 1
  let url = defaultSearxUrl(port)
  echo "started ", ContainerName, " (", Image, ") on ", url, "; waiting for it to answer..."
  let deadline = epochTime() + 90
  var up = false
  while epochTime() < deadline:
    if ready(url):
      up = true
      break
    sleep(2000)
  if not up:
    stderr.writeLine "SearXNG did not answer JSON within 90 s; see `docker logs " & ContainerName & "`"
    return 1
  let wj = stateDir / "web.json"
  if fileExists(wj) or symlinkExists(wj):
    echo "SearXNG is up. ", wj, " already exists and was left alone; to use it add:"
    echo "  ", webJsonFor(url, trustAllow).strip
  else:
    writePrivate(wj, webJsonFor(url, trustAllow))
    echo "wrote ", wj, (if trustAllow: " (searches on this loopback instance run unasked; use --ask to be asked)" else: " (every search asks)")
  echo "done. Use: malyutka run --web ...   (check with `malyutka doctor`)"
  0
