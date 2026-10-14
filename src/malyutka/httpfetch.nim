## A deliberately small HTTP/1.1 client for the web helper (SPEC-011, invariant 18). It exists
## because std/httpclient re-resolves DNS at connect time (rebinding), follows redirects without
## vetting them, and cannot bound an async request in time. Here:
##   * one resolution per hop, every answer vetted (urlsafety), and the socket is connected to a
##     vetted ADDRESS; the host NAME is used only for SNI, certificate checking and the Host header
##   * redirects are followed by hand, every hop re-checked from scratch; https -> http is refused;
##     nothing (no header, no body) is forwarded
##   * header block, body, redirect count and total time are all bounded
## Compiled only into malyutka_web (and test_web): it needs -d:ssl.

import std/[net, nativesockets, strutils, times, uri]
import ./urlsafety

const
  MaxHeaderBytes = 64 * 1024
  MaxHeaders = 100
  DefaultMaxBody* = 2 * 1024 * 1024
  MaxRedirects = 5
  UserAgent* = "malyutka-web/0.9 (+https://github.com/danindiana/malyutka)"

type
  FetchOpts* = object
    timeoutSec*: int
    maxBody*: int
    denyDomains*, allowPrivate*: seq[string]
    caFile*: string
    resolver*: Resolver               ## nil = the system resolver; tests inject one
    meth*: string                     ## "GET" (default) or "POST"
    headers*: seq[tuple[k, v: string]]
    body*: string
    requireHttps*: bool               ## keyed APIs: a credential never travels in clear
    followRedirects*: bool
    acceptTypes*: seq[string]         ## media types accepted for a 2xx body (empty = text-like defaults)

  FetchResult* = object
    ok*: bool
    error*: string
    status*: int
    finalUrl*: string
    contentType*: string
    body*: string                     ## decoded to UTF-8 (lossy)
    truncated*: bool
    redirects*: int
    connectedIp*: string              ## the address the last hop actually used

proc defaultOpts*(): FetchOpts =
  FetchOpts(timeoutSec: 20, maxBody: DefaultMaxBody, meth: "GET", followRedirects: true)

proc fail(r: var FetchResult; msg: string): FetchResult =
  r.ok = false
  r.error = msg
  r

# ---- bytes and text ---------------------------------------------------------------

proc toUtf8Lossy*(s: string): string =
  ## Replaces invalid UTF-8 sequences with U+FFFD; never raises, linear time.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    var n = 0
    if c < 0x80: n = 1
    elif c in 0xC2 .. 0xDF: n = 2
    elif c in 0xE0 .. 0xEF: n = 3
    elif c in 0xF0 .. 0xF4: n = 4
    var ok = n > 0 and i + n <= s.len
    if ok:
      for k in 1 ..< n:
        if (ord(s[i + k]) and 0xC0) != 0x80: ok = false
      if ok and n == 3 and c == 0xE0 and ord(s[i + 1]) < 0xA0: ok = false          # overlong
      if ok and n == 3 and c == 0xED and ord(s[i + 1]) >= 0xA0: ok = false         # surrogate
      if ok and n == 4 and c == 0xF0 and ord(s[i + 1]) < 0x90: ok = false          # overlong
      if ok and n == 4 and c == 0xF4 and ord(s[i + 1]) >= 0x90: ok = false         # > U+10FFFF
    if ok:
      result.add s[i ..< i + n]
      i += n
    else:
      result.add "\xEF\xBF\xBD"
      inc i

proc latin1ToUtf8(s: string): string =
  for ch in s:
    let c = ord(ch)
    if c < 0x80: result.add ch
    else:
      result.add chr(0xC0 or (c shr 6))
      result.add chr(0x80 or (c and 0x3F))

proc mediaType(contentType: string): string =
  let semi = contentType.find(';')
  (if semi >= 0: contentType[0 ..< semi] else: contentType).strip.toLowerAscii

proc charsetOf(contentType: string): string =
  for part in contentType.split(';')[1 .. ^1]:
    let p = part.strip
    if p.toLowerAscii.startsWith("charset="):
      return p[8 .. ^1].strip(chars = {'"', '\'', ' '}).toLowerAscii

proc acceptable*(mt: string; accept: seq[string]): bool =
  if accept.len > 0: return mt in accept
  mt.startsWith("text/") or mt in ["application/xhtml+xml", "application/xml", "application/json"] or
    mt.endsWith("+json") or mt.endsWith("+xml")

# ---- socket helpers ------------------------------------------------------------------

type Deadline = object
  at: float

proc msLeft(d: Deadline): int = int((d.at - epochTime()) * 1000.0)

proc recvSome(s: Socket; d: Deadline; buf: var string; maxRead: int): int =
  ## Reads at least 1 byte (or returns 0 at EOF); raises TimeoutError at the deadline.
  let left = d.msLeft
  if left <= 0: raise newException(TimeoutError, "deadline")
  var tmp = newString(min(maxRead, 16384))
  let n = s.recv(addr tmp[0], tmp.len, left)
  if n > 0: buf.add tmp[0 ..< n]
  n

proc readHeaderBlock(s: Socket; d: Deadline; leftover: var string): string =
  ## Everything up to the blank line; bytes already read past it stay in `leftover`.
  var buf = ""
  while true:
    let idx = buf.find("\r\n\r\n")
    if idx >= 0:
      leftover = buf[idx + 4 .. ^1]
      return buf[0 ..< idx]
    if buf.len > MaxHeaderBytes: raise newException(IOError, "response headers exceed " & $MaxHeaderBytes & " bytes")
    if recvSome(s, d, buf, MaxHeaderBytes + 4 - buf.len) == 0:
      raise newException(IOError, "connection closed before the headers ended")

proc readBody(s: Socket; d: Deadline; lead: string; contentLength: int; chunked: bool; maxBody: int;
              truncated: var bool): string =
  var data = lead
  template full(): bool = result.len >= maxBody
  if chunked:
    var buf = data
    var done = false
    while not done:
      var nl = buf.find("\r\n")
      while nl < 0:
        if buf.len > 4096: raise newException(IOError, "chunk size line too long")
        if recvSome(s, d, buf, 4096) == 0: raise newException(IOError, "truncated chunked body")
        nl = buf.find("\r\n")
      var sizeStr = buf[0 ..< nl]
      let semi = sizeStr.find(';')
      if semi >= 0: sizeStr = sizeStr[0 ..< semi]
      sizeStr = sizeStr.strip
      if sizeStr.len == 0 or sizeStr.len > 8: raise newException(IOError, "bad chunk size")
      var size = 0
      try: size = parseHexInt(sizeStr)
      except ValueError: raise newException(IOError, "bad chunk size")
      buf = buf[nl + 2 .. ^1]
      if size == 0: done = true; break
      var need = size
      while need > 0:
        if buf.len == 0 and recvSome(s, d, buf, 16384) == 0: raise newException(IOError, "truncated chunk")
        let take = min(need, buf.len)
        let room = maxBody - result.len
        if room > 0: result.add buf[0 ..< min(take, room)]
        if take > room: truncated = true
        buf = buf[take .. ^1]
        need -= take
      while buf.len < 2:
        if recvSome(s, d, buf, 2) == 0: raise newException(IOError, "truncated chunk terminator")
      buf = buf[2 .. ^1]
      if full(): truncated = true; break
  else:
    var remaining = contentLength            # -1 = until the server closes
    if data.len > 0:
      let take = if remaining >= 0: min(remaining, data.len) else: data.len
      result.add data[0 ..< min(take, maxBody)]
      if take > maxBody: truncated = true
      if remaining >= 0: remaining -= take
    while remaining != 0 and not full():
      var buf = ""
      let n = recvSome(s, d, buf, 16384)
      if n == 0:
        if remaining > 0: raise newException(IOError, "connection closed before the body ended")
        break
      let room = maxBody - result.len
      result.add buf[0 ..< min(n, room)]
      if n > room: truncated = true
      if remaining >= 0: remaining -= n
    if full() and remaining != 0: truncated = true

# ---- one request ---------------------------------------------------------------------

type Hop = object
  status: int
  headers: seq[tuple[k, v: string]]
  body: string
  truncated: bool
  ip: string

proc header(h: Hop; name: string): string =
  for (k, v) in h.headers:
    if k == name: return v

proc newTlsContext(caFile: string): SslContext =
  if caFile.len > 0: newContext(verifyMode = CVerifyPeer, caFile = caFile)
  else: newContext(verifyMode = CVerifyPeer)

proc doHop(w: WebUrl; opts: FetchOpts; d: Deadline; ips: seq[IpAddress]; maxBody: int): Hop =
  var s: Socket = nil
  var lastErr = "no address could be reached"
  for ip in ips:
    let dom = if ip.family == IpAddressFamily.IPv6: AF_INET6 else: AF_INET
    let sock = newSocket(dom, SOCK_STREAM, IPPROTO_TCP)
    try:
      sock.connect($ip, Port(w.port), timeout = max(1, min(10_000, d.msLeft)))
      s = sock
      result.ip = $ip
      break
    except CatchableError as e:
      lastErr = "connect to " & $ip & ":" & $w.port & " failed: " & e.msg.splitLines()[0]
      sock.close()
  if s == nil: raise newException(IOError, lastErr)
  try:
    if w.https:
      let ctx = newTlsContext(opts.caFile)
      # SNI and the certificate-name check use the HOST NAME even though the socket is already
      # connected to a vetted address.
      wrapConnectedSocket(ctx, s, handshakeAsClient, w.host)
    var req = opts.meth & " " & w.target & " HTTP/1.1\r\n"
    let defaultPort = (w.https and w.port == 443) or (not w.https and w.port == 80)
    let hostName = if ':' in w.host: "[" & w.host & "]" else: w.host
    req.add "Host: " & hostName & (if defaultPort: "" else: ":" & $w.port) & "\r\n"
    req.add "User-Agent: " & UserAgent & "\r\n"
    req.add "Accept: text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.1\r\n"
    req.add "Accept-Encoding: identity\r\nConnection: close\r\n"
    for (k, v) in opts.headers:
      if k.len == 0 or '\r' in k or '\n' in k or ':' in k or '\r' in v or '\n' in v:
        raise newException(IOError, "invalid request header")
      req.add k & ": " & v & "\r\n"
    if opts.meth == "POST": req.add "Content-Length: " & $opts.body.len & "\r\n"
    req.add "\r\n"
    if opts.meth == "POST": req.add opts.body
    s.send(req)
    var leftover = ""
    var head = readHeaderBlock(s, d, leftover)
    # skip informational responses
    while head.startsWith("HTTP/1.") and head.len > 9 and head[9] == '1':
      head = readHeaderBlock(s, d, leftover)
    let lines = head.split("\r\n")
    let sl = lines[0]
    if not (sl.startsWith("HTTP/1.0 ") or sl.startsWith("HTTP/1.1 ")) or sl.len < 12:
      raise newException(IOError, "malformed status line")
    try: result.status = parseInt(sl[9 ..< 12])
    except ValueError: raise newException(IOError, "malformed status code")
    if lines.len - 1 > MaxHeaders: raise newException(IOError, "too many response headers")
    for l in lines[1 .. ^1]:
      let c = l.find(':')
      if c <= 0: raise newException(IOError, "malformed response header")
      result.headers.add (l[0 ..< c].strip.toLowerAscii, l[c + 1 .. ^1].strip)
    let ce = result.header("content-encoding").toLowerAscii
    if ce.len > 0 and ce != "identity":
      raise newException(IOError, "unsupported content-encoding: " & ce)
    var clen = -1
    var lens: seq[string]
    for (k, v) in result.headers:
      if k == "content-length": lens.add v
    if lens.len > 0:
      for v in lens:
        if v != lens[0]: raise newException(IOError, "conflicting Content-Length headers")
      try: clen = parseInt(lens[0])
      except ValueError: raise newException(IOError, "malformed Content-Length")
      if clen < 0: raise newException(IOError, "malformed Content-Length")
    let chunked = "chunked" in result.header("transfer-encoding").toLowerAscii
    if chunked and clen >= 0: clen = -1        # RFC 7230: chunked wins
    let noBody = opts.meth == "HEAD" or result.status in [204, 304] or result.status < 200
    if not noBody:
      result.body = readBody(s, d, leftover, clen, chunked, maxBody, result.truncated)
  finally:
    s.close()

# ---- the public entry point -------------------------------------------------------------

proc fetch*(url: string; optsIn: FetchOpts): FetchResult =
  var opts = optsIn
  if opts.timeoutSec <= 0: opts.timeoutSec = 20
  if opts.maxBody <= 0: opts.maxBody = DefaultMaxBody
  if opts.meth.len == 0: opts.meth = "GET"
  let resolver: Resolver = if opts.resolver == nil: systemResolver else: opts.resolver
  let d = Deadline(at: epochTime() + opts.timeoutSec.float)
  var cur = url
  var r = FetchResult()
  var wasHttps = false
  while true:
    let w = parseWebUrl(cur)
    if not w.ok: return r.fail("refused URL: " & w.why)
    if opts.requireHttps and not w.https: return r.fail("refused: this request requires https")
    if wasHttps and not w.https: return r.fail("refused: redirect from https to http")
    let why = urlPolicyReason(cur, opts.denyDomains, opts.allowPrivate)
    if why.len > 0: return r.fail("refused URL: " & why)
    let (ips, rwhy) = resolveVetted(w.host, resolver, opts.allowPrivate)
    if ips.len == 0: return r.fail("refused: " & rwhy)
    var hop: Hop
    var hopOpts = opts
    if r.redirects > 0:
      hopOpts.headers = @[]          # nothing the caller attached (credentials!) follows a redirect
      hopOpts.body = ""
    try:
      hop = doHop(w, hopOpts, d, ips, opts.maxBody)
    except TimeoutError:
      return r.fail("timed out after " & $opts.timeoutSec & "s")
    except SslError as e:
      return r.fail("TLS error: " & e.msg.splitLines()[0])
    except CatchableError as e:
      return r.fail(e.msg.splitLines()[0])
    r.connectedIp = hop.ip
    r.finalUrl = cur
    r.status = hop.status
    if opts.followRedirects and hop.status in [301, 302, 303, 307, 308]:
      let loc = hop.header("location")
      if loc.len == 0: return r.fail("redirect without a Location header")
      if r.redirects >= MaxRedirects: return r.fail("too many redirects (> " & $MaxRedirects & ")")
      var nextUrl = ""
      try: nextUrl = $combine(parseUri(cur), parseUri(loc))
      except CatchableError: return r.fail("unparseable redirect target")
      wasHttps = w.https
      cur = nextUrl
      inc r.redirects
      continue
    if hop.status in [301, 302, 303, 307, 308] and not opts.followRedirects:
      return r.fail("redirects are not followed for this request (HTTP " & $hop.status & ")")
    r.contentType = hop.header("content-type")
    r.truncated = hop.truncated
    let mt = mediaType(r.contentType)
    if hop.status >= 200 and hop.status < 300 and hop.body.len > 0 and not acceptable(mt, opts.acceptTypes):
      r.status = hop.status
      return r.fail("unsupported content type: " & (if mt.len > 0: mt else: "(none)"))
    let cs = charsetOf(r.contentType)
    r.body = if cs in ["iso-8859-1", "latin1", "iso8859-1", "windows-1252", "cp1252"]: latin1ToUtf8(hop.body)
             else: toUtf8Lossy(hop.body)
    r.ok = true
    return r
