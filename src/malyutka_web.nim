## malyutka_web: the web helper (SPEC-011). A separate binary because Nim loads OpenSSL eagerly when
## compiled with -d:ssl, and so that everything touching the network and untrusted markup runs in its own
## process, inside a sandbox with no filesystem access. One JSON request line on stdin, one JSON response
## line on stdout. It never reads a file the harness did not bind in, and it dies on its own deadline.

import std/[json, net, strutils]
import malyutka/[httpfetch, htmltext, urlsafety, websearch]

const MaxRequestBytes = 512 * 1024

proc alarm(secs: cuint): cuint {.importc: "alarm", header: "<unistd.h>".}

proc respond(j: JsonNode) =
  stdout.write($j & "\n")
  stdout.flushFile

proc fail(msg: string; extra: JsonNode = nil) =
  var j = %*{"ok": false, "error": msg}
  if extra != nil:
    for k, v in extra: j[k] = v
  respond j

proc readRequest(): JsonNode =
  var line = ""
  try:
    while line.len <= MaxRequestBytes:
      let c = stdin.readChar
      if c == '\n': break
      line.add c
  except EOFError: discard
  if line.len > MaxRequestBytes: return nil
  try: result = parseJson(line)
  except CatchableError: result = nil

proc strOf(j: JsonNode; k: string; d = ""): string =
  if j.hasKey(k) and j[k].kind == JString: j[k].getStr else: d

proc intOf(j: JsonNode; k: string; d: int; lo, hi: int): int =
  if j.hasKey(k) and j[k].kind == JInt: clamp(j[k].getInt, lo, hi) else: d

proc strList(j: JsonNode; k: string): seq[string] =
  if j.hasKey(k) and j[k].kind == JArray:
    for e in j[k]:
      if e.kind == JString and result.len < 200: result.add e.getStr.toLowerAscii

proc main() =
  let req = readRequest()
  if req == nil or req.kind != JObject:
    fail("malformed request"); return
  let timeout = intOf(req, "timeoutSec", 20, 1, 60)
  # a hang in TLS or DNS must not outlive the request: SIGALRM terminates the process
  discard alarm(cuint(timeout + 5))
  case strOf(req, "op")
  of "probe":
    try:
      discard newContext(verifyMode = CVerifyPeer)
      respond %*{"ok": true, "tls": true}
    except CatchableError as e:
      fail("TLS unavailable: " & e.msg.splitLines()[0])
  of "fetch":
    var o = defaultOpts()
    o.timeoutSec = timeout
    o.maxBody = intOf(req, "maxBody", DefaultMaxBody, 1024, 4 * 1024 * 1024)
    o.denyDomains = strList(req, "denyDomains")
    o.allowPrivate = strList(req, "allowPrivate")
    o.caFile = strOf(req, "caFile")
    let r = fetch(strOf(req, "url"), o)
    if not r.ok:
      fail(r.error, %*{"status": r.status, "contentType": r.contentType})
      return
    let maxChars = intOf(req, "maxChars", 400_000, 1000, 1_000_000)
    var text = ""
    var title = ""
    var truncated = r.truncated
    let ct = r.contentType.toLowerAscii
    if "html" in ct or (r.body.len > 0 and r.body.strip.toLowerAscii.startsWith("<!doctype html")):
      let h = htmlToText(r.body, maxChars)
      text = h.text
      title = h.title
      truncated = truncated or h.truncated
    else:
      text = r.body
      if text.len > maxChars:
        var cut = maxChars
        while cut > 0 and (ord(text[cut]) and 0xC0) == 0x80: dec cut
        text.setLen(cut)
        truncated = true
    let w = parseWebUrl(r.finalUrl)
    respond %*{"ok": true, "status": r.status, "finalUrl": r.finalUrl, "host": w.host, "contentType": r.contentType,
               "title": title, "text": text, "bytes": r.body.len, "truncated": truncated, "redirects": r.redirects}
  of "search":
    let backend = strOf(req, "backend")
    if backend notin Backends:
      fail("unknown search backend"); return
    let rq = SearchReq(backend: backend, base: strOf(req, "base"), key: strOf(req, "apiKey"),
                       query: strOf(req, "query"), limit: intOf(req, "limit", 5, 1, MaxHits))
    let res = runSearch(rq, timeout, strOf(req, "caFile"), strList(req, "denyDomains"), strList(req, "allowPrivate"))
    if not res.ok:
      # a credential is never echoed, whatever an upstream error message contained
      var msg = res.error
      if rq.key.len > 0: msg = msg.replace(rq.key, "[key]")
      fail(msg); return
    var arr = newJArray()
    for h in res.hits:
      arr.add %*{"title": h.title, "url": h.url, "description": h.description, "position": h.position}
    respond %*{"ok": true, "backend": backend, "results": arr}
  else:
    fail("unknown op")

main()
