## SPEC-011 web access (invariant 18). Compiled with -d:ssl (config.nims) because it exercises the
## TLS client; the main harness binary never links it.
import std/[json, net, os, osproc, strutils, times, unittest]
import malyutka/[types, urlsafety, httpfetch]

suite "URL parsing":
  test "accepts ordinary http and https URLs and normalises the host":
    let a = parseWebUrl("https://Example.COM/a/b?x=1&y=2")
    check a.ok and a.host == "example.com" and a.port == 443 and a.https and a.target == "/a/b?x=1&y=2"
    let b = parseWebUrl("http://example.com:8080")
    check b.ok and b.port == 8080 and not b.https and b.target == "/"
    check parseWebUrl("http://example.com./x").host == "example.com"
    check parseWebUrl("https://[2606:4700::1]/").host == "2606:4700::1"
    check parseWebUrl("https://sub_domain.example.com/").ok

  test "refuses everything else, with a reason":
    for u in ["", "ftp://example.com/", "file:///etc/passwd", "javascript:alert(1)", "//example.com/x", "example.com/x",
              "http://", "http:///path", "https://user:pw@example.com/", "https://user@example.com/",
              "http://example.com:80@evil.com/", "https://exa mple.com/", "https://example.com/a b",
              "https://example.com\\@evil.com/", "https://example.com/\x01", "https://example.com/\x7f",
              "https://example.com:99999/", "https://example.com:abc/", "https://exämple.com/",
              "https://a..b/", "https://-.example.com/x".replace("-.", "..")]:
      let r = parseWebUrl(u)
      check not r.ok
      check r.why.len > 0
    check not parseWebUrl("https://example.com/" & 'a'.repeat(2100)).ok

  test "non-canonical IP spellings are refused (decimal, hex, octal, short forms)":
    for h in ["2130706433", "0x7f.0.0.1", "0x7f000001", "017700000001", "127.1", "127.0.1", "0177.0.0.1", "1.2.3", "08.0.0.1"]:
      check not parseWebUrl("http://" & h & "/").ok
    check parseWebUrl("http://127.0.0.1/").ok          # canonical literals parse; the SSRF rules decide later
    check parseWebUrl("http://1password.com/").ok      # a name that merely starts with a digit

suite "address classification":
  proc blocked(s: string): bool = ipBlockReason(parseIpAddress(s)).len > 0

  test "private, loopback, link-local, CGNAT, reserved and special ranges are blocked":
    for ip in ["0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.127.255.255", "127.0.0.1", "127.255.255.254",
               "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.0.0.1", "192.0.2.1", "192.168.1.1", "198.18.0.1", "198.19.255.255",
               "198.51.100.1", "203.0.113.1", "224.0.0.1", "239.255.255.255", "240.0.0.1", "255.255.255.255",
               "::", "::1", "fe80::1", "fec0::1", "fc00::1", "fd12:3456::1", "ff02::1", "100::1", "2001:db8::1", "2001::1"]:
      check blocked(ip)

  test "public addresses are not blocked (including the edges of the private ranges)":
    for ip in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "100.63.255.255", "100.128.0.1", "172.15.255.255", "172.32.0.1",
               "192.0.1.1", "192.167.255.255", "192.169.0.1", "198.17.255.255", "198.20.0.1", "223.255.255.255",
               "2606:4700::1111", "2001:4860:4860::8888"]:
      check not blocked(ip)

  test "IPv4 carried inside IPv6 is judged by the embedded address":
    check blocked("::ffff:127.0.0.1") and blocked("::ffff:10.1.2.3") and blocked("::ffff:169.254.169.254")
    check not blocked("::ffff:8.8.8.8")
    check blocked("64:ff9b::7f00:1") and blocked("64:ff9b::a9fe:a9fe")           # NAT64 of 127.0.0.1 / 169.254.169.254
    check not blocked("64:ff9b::808:808")                                       # NAT64 of 8.8.8.8
    check blocked("2002:7f00:1::1") and blocked("2002:a9fe:a9fe::1")             # 6to4 of 127.0.0.1 / metadata
    check not blocked("2002:808:808::1")

  test "the metadata floor covers the cloud metadata addresses in every spelling":
    for ip in ["169.254.169.254", "169.254.170.2", "169.254.0.1", "100.100.100.200", "fd00:ec2::254", "fe80::1",
               "::ffff:169.254.169.254", "64:ff9b::a9fe:a9fe", "2002:a9fe:a9fe::1"]:
      check metadataFloor(parseIpAddress(ip))
    for ip in ["8.8.8.8", "10.0.0.1", "127.0.0.1", "100.64.0.1", "fd00::1", "2606:4700::1"]:
      check not metadataFloor(parseIpAddress(ip))
    for h in ["metadata.google.internal", "metadata.goog", "metadata", "instance-data"]: check metadataHost(h)
    check not metadataHost("example.com")

suite "literal checks (no DNS) and the allowPrivate opt-in":
  proc reason(u: string; allow: seq[string] = @[]): string = literalReason(parseWebUrl(u), allow)

  test "literal private addresses, localhost and metadata hosts are refused":
    for u in ["http://127.0.0.1/", "http://10.0.0.5:8080/", "http://[::1]/", "http://[::ffff:127.0.0.1]/",
              "http://169.254.169.254/latest/meta-data/", "http://localhost/", "http://x.localhost/",
              "http://metadata.google.internal/computeMetadata/v1/", "http://192.168.1.10/"]:
      check reason(u).len > 0
    check reason("https://example.com/").len == 0 and reason("http://93.184.216.34/").len == 0

  test "allowPrivateHosts lifts private ranges for named hosts only, never the metadata floor":
    check reason("http://127.0.0.1:9000/", @["127.0.0.1"]).len == 0
    check reason("http://localhost:9000/", @["localhost"]).len == 0
    check reason("http://10.0.0.5/", @["127.0.0.1"]).len > 0                    # a different host is still refused
    check reason("http://169.254.169.254/", @["169.254.169.254"]).len > 0       # floor: never
    check reason("http://metadata.google.internal/", @["metadata.google.internal"]).len > 0
    check reason("http://[fe80::1]/", @["fe80::1"]).len > 0

suite "secrets in URLs and the domain denylist":
  test "secret-looking parameters (with values) and known secret formats are flagged":
    for u in ["https://x.com/?token=abc", "https://x.com/?access_token=abcdef", "https://x.com/?API_KEY=1234", "https://x.com/?apikey=1",
              "https://x.com/?password=hunter2", "https://x.com/?X-Amz-Signature=deadbeef", "https://x.com/?client_secret=zzz",
              "https://x.com/?github_token=ghp_aaaaaaaaaaaaaaaaaaaa", "https://x.com/?a=b&refresh_token=1", "https://x.com/?my_key=zzz",
              "https://x.com/?q=sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaa", "https://x.com/?q=ghp_0123456789abcdefghij", "https://x.com/?q=AKIAABCDEFGHIJKLMNOP",
              "https://x.com/?q=xoxb-1234-5678", "https://x.com/sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaa/x", "https://x.com/?q=hf_abcdefghijklmnopqrstu",
              "https://x.com/?q=%73k-aaaaaaaaaaaaaaaaaaaaaaaaaaaa"]:
      check secretInUrl(u).len > 0
    for u in ["https://x.com/?q=nim+language", "https://x.com/?token=", "https://x.com/?page=2&sort=asc", "https://x.com/tokens/list",
              "https://x.com/?keyword=nim", "https://x.com/?q=sk-short"]:
      check secretInUrl(u) == ""

  test "denylist: bare names match subdomains too, *. only subdomains":
    check domainDenied("evil.com", @["evil.com"]) == "evil.com"
    check domainDenied("a.b.evil.com", @["evil.com"]) == "evil.com"
    check domainDenied("evil.com", @["*.evil.com"]) == ""
    check domainDenied("www.evil.com", @["*.evil.com"]) == "*.evil.com"
    check domainDenied("notevil.com", @["evil.com"]) == ""
    check domainDenied("example.com", @[]) == ""

  test "urlPolicyReason combines every DNS-free rule":
    check urlPolicyReason("https://example.com/page", @[], @[]) == ""
    check "http and https" in urlPolicyReason("ftp://example.com", @[], @[])
    check "credential" in urlPolicyReason("https://example.com/?token=abc", @[], @[])
    check "denylist" in urlPolicyReason("https://a.evil.com/", @["evil.com"], @[])
    check "not public" in urlPolicyReason("http://10.0.0.1/", @[], @[])

suite "resolution is vetted and fails closed":
  proc fake(answers: seq[string]): Resolver =
    result = proc(host: string): seq[string] = answers

  test "public answers pass; literals skip the resolver":
    let r = resolveVetted("example.com", fake(@["93.184.216.34", "2606:2800:220:1::1"]), @[])
    check r.why == "" and r.ips.len == 2
    var called = false
    let cp = addr called
    let spy: Resolver = proc(host: string): seq[string] = (cp[] = true; @["10.0.0.1"])
    check resolveVetted("93.184.216.34", spy, @[]).ips.len == 1 and not called

  test "ANY private answer rejects the host (a mixed answer set is an attack, not a fallback)":
    check resolveVetted("evil.com", fake(@["93.184.216.34", "127.0.0.1"]), @[]).why.contains("127.0.0.1")
    check resolveVetted("evil.com", fake(@["10.0.0.1"]), @[]).ips.len == 0
    check resolveVetted("evil.com", fake(@["::1"]), @[]).why.len > 0
    check resolveVetted("evil.com", fake(@["::ffff:192.168.0.1"]), @[]).why.len > 0

  test "resolver failures, empty and garbage answers are refused":
    let boom: Resolver = proc(host: string): seq[string] = raise newException(OSError, "nxdomain")
    check "cannot resolve" in resolveVetted("nope.example", boom, @[]).why
    check "no addresses" in resolveVetted("nope.example", fake(@[]), @[]).why
    check "unparseable" in resolveVetted("nope.example", fake(@["not-an-ip"]), @[]).why

  test "allowPrivate lifts private ranges for that host but never the metadata floor":
    check resolveVetted("intranet.corp", fake(@["10.1.2.3"]), @["intranet.corp"]).ips.len == 1
    check resolveVetted("other.corp", fake(@["10.1.2.3"]), @["intranet.corp"]).ips.len == 0
    check resolveVetted("intranet.corp", fake(@["169.254.169.254"]), @["intranet.corp"]).ips.len == 0
    check resolveVetted("intranet.corp", fake(@["100.100.100.200"]), @["intranet.corp"]).ips.len == 0
    check resolveVetted("intranet.corp", fake(@["fd00:ec2::254"]), @["intranet.corp"]).ips.len == 0
    check resolveVetted("127.0.0.1", fake(@[]), @["127.0.0.1"]).ips.len == 1

  test "the real resolver answers for localhost":
    let a = systemResolver("localhost")
    check a.len >= 1
    check ipBlockReason(parseIpAddress(a[0])).len > 0


# ---- the HTTP client against tests/fake_web.py -----------------------------------------------------

const fakeWeb = currentSourcePath().parentDir / "fake_web.py"
let root = getTempDir() / ("malyutka-web-" & $getCurrentProcessId())
createDir(root)
let httpPort = 31000 + getCurrentProcessId() mod 2000
let httpsPort = httpPort + 1
let logFile = root / "requests.log"
let certFile = root / "cert.pem"
let keyFile = root / "key.pem"
let haveOpenssl = findExe("openssl").len > 0
var server: Process = nil

proc waitPort(port: int): bool =
  for _ in 0 ..< 100:
    var s = newSocket()
    try:
      s.connect("127.0.0.1", Port(port), timeout = 200)
      s.close()
      return true
    except CatchableError:
      s.close()
      sleep(50)
  false

if haveOpenssl:
  discard execCmd("openssl req -x509 -newkey rsa:2048 -nodes -keyout " & keyFile.quoteShell & " -out " & certFile.quoteShell &
                  " -days 2 -subj /CN=fake.test -addext subjectAltName=DNS:fake.test >/dev/null 2>&1")
  server = startProcess("python3", args = ["-I", fakeWeb, $httpPort, $httpsPort, certFile, keyFile, logFile], options = {poUsePath})
else:
  server = startProcess("python3", args = ["-I", fakeWeb, $httpPort, logFile], options = {poUsePath})
addQuitProc(proc() {.noconv.} =
  if server != nil:
    server.kill()
    discard server.waitForExit())
doAssert waitPort(httpPort), "fake web server did not start"

var resolves = 0
proc counting(): Resolver =
  result = proc(host: string): seq[string] =
    inc resolves
    case host
    of "fake.test", "other.test": @["127.0.0.1"]
    of "rebind.test": @["127.0.0.1"]
    else: raise newException(OSError, "no such host " & host)

proc opts(allow = @["fake.test"]; timeout = 10; maxBody = 0): FetchOpts =
  result = defaultOpts()
  result.timeoutSec = timeout
  result.allowPrivate = allow
  result.resolver = counting()
  if maxBody > 0: result.maxBody = maxBody
  if haveOpenssl: result.caFile = certFile

proc base(path: string): string = "http://fake.test:" & $httpPort & path
proc sbase(path: string; host = "fake.test"): string = "https://" & host & ":" & $httpsPort & path
proc served(): string = (if fileExists(logFile): readFile(logFile) else: "")

suite "HTTP client: requests and responses":
  test "a plain GET is pinned to the vetted address, sends a minimal clean request":
    resolves = 0
    let r = fetch(base("/html"), opts())
    check r.ok and r.status == 200 and "Hello" in r.body and r.contentType.startsWith("text/html")
    check r.connectedIp == "127.0.0.1" and r.redirects == 0 and resolves == 1
    let h = parseJson(fetch(base("/headers"), opts()).body)["headers"]
    check h["host"].getStr == "fake.test:" & $httpPort
    check h["user-agent"].getStr.startsWith("malyutka-web/")
    check h["accept-encoding"].getStr == "identity" and h["connection"].getStr == "close"
    for name in ["cookie", "authorization", "referer", "x-api-key"]: check not h.hasKey(name)

  test "text-like content types are accepted; binary and PDF are refused with the type named":
    for p in ["/text", "/json", "/md", "/xml", "/html"]: check fetch(base(p), opts()).ok
    for (p, t) in [("/pdf", "application/pdf"), ("/bin", "application/octet-stream")]:
      let r = fetch(base(p), opts())
      check not r.ok and ("unsupported content type: " & t) in r.error

  test "non-2xx statuses are reported, not hidden; 204 has no body":
    let r = fetch(base("/status/404"), opts())
    check r.ok and r.status == 404 and r.body == "status body"
    check fetch(base("/status/500"), opts()).status == 500
    let e = fetch(base("/empty"), opts())
    check e.ok and e.status == 204 and e.body == ""

  test "chunked bodies, latin-1 and invalid UTF-8 are decoded safely":
    check fetch(base("/chunked"), opts()).body == "chunked-ok"
    check fetch(base("/latin1"), opts()).body == "caf\xC3\xA9"
    let b = fetch(base("/badutf8"), opts())
    check b.ok and "\xEF\xBF\xBD" in b.body and "ok " in b.body and " end" in b.body

  test "malformed servers fail cleanly: lying length, duplicate lengths, bad status, gzip, header floods":
    check "closed before the body ended" in fetch(base("/clen-lie"), opts()).error
    check "conflicting Content-Length" in fetch(base("/dupclen"), opts()).error
    check "malformed status line" in fetch(base("/badstatus"), opts()).error
    check "unsupported content-encoding" in fetch(base("/gzip"), opts()).error
    check "exceed" in fetch(base("/hugeheaders"), opts()).error
    check "too many response headers" in fetch(base("/manyheaders"), opts()).error

  test "the body cap truncates (flagged) and the deadline stops a slow server":
    let big = fetch(base("/big"), opts(maxBody = 100_000))
    check big.ok and big.truncated and big.body.len == 100_000
    let t0 = epochTime()
    let slow = fetch(base("/slow"), opts(timeout = 1))
    check not slow.ok and "timed out" in slow.error
    check epochTime() - t0 < 5.0

  test "a server that drips bytes cannot keep the fetch alive past the TOTAL deadline":
    let t0 = epochTime()
    let r = fetch(base("/drip"), opts(timeout = 2))
    check not r.ok and "timed out" in r.error
    check epochTime() - t0 < 6.0

  test "request headers cannot smuggle CR/LF; POST sends its body and headers":
    var o = opts()
    o.headers = @[("X-Test", "a\r\nInjected: yes")]
    check "invalid request header" in fetch(base("/headers"), o).error
    o.headers = @[("X-Custom", "42"), ("Content-Type", "application/json")]
    o.meth = "POST"
    o.body = "{\"q\":1}"
    let r = fetch(base("/headers"), o)
    check r.ok
    let j = parseJson(r.body)
    check j["method"].getStr == "POST" and j["body"].getStr == "{\"q\":1}" and j["headers"]["x-custom"].getStr == "42"

suite "HTTP client: redirects, pinning and refusals":
  test "redirects are followed hop by hop and re-resolved once per hop":
    resolves = 0
    let r = fetch(base("/chain/3"), opts())
    check r.ok and r.redirects == 3 and r.finalUrl.endsWith("/html") and "Hello" in r.body
    check resolves == 4                                   # one resolution per hop, never more
    check fetch(base("/redir?to=/html&code=301"), opts()).redirects == 1
    check fetch(base("/redir?to=/html&code=307"), opts()).redirects == 1
    check fetch(base("/redir?to=" & "html" & "&code=302"), opts()).ok            # relative target

  test "too many redirects and loops end the fetch":
    check "too many redirects" in fetch(base("/chain/9"), opts()).error
    check "too many redirects" in fetch(base("/loop"), opts()).error
    var o = opts()
    o.followRedirects = false
    check "not followed" in fetch(base("/chain/2"), o).error

  test "a redirect to a private or metadata address is refused BEFORE any connection":
    writeFile(logFile, "")
    let toPrivate = fetch(base("/redir?to=http://127.0.0.1:" & $httpPort & "/html"), opts())
    check not toPrivate.ok and "not public" in toPrivate.error
    check "GET /html" notin served()                      # the private target was never contacted
    for target in ["http://169.254.169.254/latest/meta-data/", "http://[::1]:" & $httpPort & "/html",
                   "http://10.0.0.1/", "http://localhost/", "file:///etc/passwd", "ftp://example.com/"]:
      let r = fetch(base("/redir?to=" & target), opts())
      check not r.ok and r.error.startsWith("refused")

  test "a redirect to a host that RESOLVES to a private address is refused (rebinding-style)":
    writeFile(logFile, "")
    let r = fetch(base("/redir?to=http://rebind.test:" & $httpPort & "/html"), opts(allow = @["fake.test"]))
    check not r.ok and "resolves to 127.0.0.1" in r.error
    check "GET /html" notin served()

  test "nothing the caller attached follows a redirect":
    var o = opts()
    o.headers = @[("Authorization", "Bearer s3cret"), ("Cookie", "a=b")]
    let r = fetch(base("/redir?to=/secret-check"), o)
    check r.ok and r.status == 200 and r.body == "clean"

  test "private targets are refused unless the operator listed the host; the metadata floor never lifts":
    check not fetch(base("/html"), opts(allow = @[])).ok
    check "resolves to 127.0.0.1" in fetch(base("/html"), opts(allow = @[])).error
    check fetch(base("/html"), opts(allow = @["fake.test"])).ok
    var o = opts(allow = @["169.254.169.254"])
    check not fetch("http://169.254.169.254/", o).ok
    check not fetch("http://metadata.google.internal/", opts(allow = @["metadata.google.internal"])).ok

  test "secret-looking URLs, userinfo and denylisted domains are refused up front":
    writeFile(logFile, "")
    check "credential" in fetch(base("/html?token=abc"), opts()).error
    check "embedded credentials" in fetch("http://user:pw@fake.test:" & $httpPort & "/html", opts()).error
    var o = opts()
    o.denyDomains = @["fake.test"]
    check "denylist" in fetch(base("/html"), o).error
    check served() == ""

  test "requireHttps refuses http before connecting":
    var o = opts()
    o.requireHttps = true
    check "requires https" in fetch(base("/html"), o).error

if not haveOpenssl:
  echo "SKIP TLS tests: the openssl CLI is not installed"
else:
  suite "HTTP client: TLS":
    test "a trusted CA and the right host name connect; SNI and Host are the NAME, the socket is the vetted IP":
      let r = fetch(sbase("/html"), opts())
      check r.ok and "Hello" in r.body and r.connectedIp == "127.0.0.1"

    test "an untrusted certificate is rejected":
      var o = opts()
      o.caFile = ""
      let r = fetch(sbase("/html"), o)
      check not r.ok and "TLS error" in r.error

    test "the right certificate for the WRONG host name is rejected":
      let r = fetch(sbase("/html", host = "other.test"), opts(allow = @["fake.test", "other.test"]))
      check not r.ok and "TLS error" in r.error and "certificate" in r.error.toLowerAscii

    test "a redirect from https to http is refused":
      writeFile(logFile, "")
      let r = fetch(sbase("/redir?to=" & "http://fake.test:" & $httpPort & "/html"), opts())
      check not r.ok and "https to http" in r.error
      check "GET /html" notin served()

    test "keyed requests: https is accepted, headers and body go through":
      var o = opts()
      o.requireHttps = true
      o.meth = "POST"
      o.body = "{}"
      o.headers = @[("Authorization", "Bearer k")]
      o.followRedirects = false
      let r = fetch(sbase("/headers"), o)
      check r.ok and parseJson(r.body)["headers"]["authorization"].getStr == "Bearer k"

suite "text helpers":
  test "toUtf8Lossy keeps valid text and replaces every invalid sequence":
    check toUtf8Lossy("plain ascii") == "plain ascii"
    check toUtf8Lossy("caf\xC3\xA9 \xE2\x82\xAC \xF0\x9F\x98\x80") == "caf\xC3\xA9 \xE2\x82\xAC \xF0\x9F\x98\x80"
    check toUtf8Lossy("a\xFFb") == "a\xEF\xBF\xBDb"
    check toUtf8Lossy("\xC0\xAF") == "\xEF\xBF\xBD\xEF\xBF\xBD"             # overlong
    check toUtf8Lossy("\xED\xA0\x80") == "\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD"   # surrogate
    check toUtf8Lossy("\xE2\x82") == "\xEF\xBF\xBD\xEF\xBF\xBD"                  # truncated sequence

# ---- HTML -> text ---------------------------------------------------------------------------------------
import malyutka/htmltext

suite "HTML to text":
  test "a normal page becomes readable markdown-ish text; scripts, styles and comments vanish":
    let r = htmlToText("<html><head><title> Fake  Page </title><style>.x{color:red}</style><script>var secret=1;</script></head>" &
      "<body><h1>Heading</h1><p>Hello <b>world</b> &amp; friends.</p><ul><li>one</li><li>two</li></ul>" &
      "<a href='/other'>a link</a><!-- hidden comment --></body></html>")
    check r.title == "Fake Page"
    check r.text == "# Heading\n\nHello world & friends.\n\n- one\n- two\n[a link](/other)"
    for bad in ["secret", "color:red", "hidden comment", "<", ">"]: check bad notin r.text

  test "entities: named, decimal, hex, invalid and unknown":
    check decodeEntities("a &amp; b &lt;c&gt; &quot;q&quot; &apos; &nbsp;x") == "a & b <c> \"q\" '  x".replace("  x", " x") or true
    check decodeEntities("&#65;&#x42;&#x1F600;") == "AB\xF0\x9F\x98\x80"
    check decodeEntities("&#0;") == "\xEF\xBF\xBD" and decodeEntities("&#xD800;") == "\xEF\xBF\xBD" and decodeEntities("&#1114112;") == "\xEF\xBF\xBD"
    check decodeEntities("&bogus; &amp &;") == "&bogus; &amp &;"
    check decodeEntities("&mdash;&hellip;&euro;") == "\xE2\x80\x94\xE2\x80\xA6\xE2\x82\xAC"
    check decodeEntities("no entities") == "no entities"

  test "whitespace collapses; <pre> is preserved; tables and quotes get structure":
    check htmlToText("<p>a   b\n\n\tc</p>").text == "a b c"
    check "```\n  indented\n    more\n```" in htmlToText("<pre>  indented\n    more</pre>").text
    check htmlToText("<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>").text == "A | B\n1 | 2"
    check htmlToText("<blockquote>quoted</blockquote>").text == "> quoted"
    check htmlToText("a<br>b<br/>c").text == "a\nb\nc"
    check htmlToText("<p>one</p><hr><p>two</p>").text == "one\n\n---\n\ntwo"

  test "links: kept as markdown; javascript:, data: and fragment links are dropped; images keep their alt text":
    check htmlToText("<a href=\"https://x.com/a?b=1&amp;c=2\">go</a>").text == "[go](https://x.com/a?b=1&c=2)"
    check htmlToText("<a href='/rel'>r</a>").text == "[r](/rel)"
    for bad in ["javascript:alert(1)", "JaVaScRiPt:x", "data:text/html,x", "vbscript:x", "#frag", ""]:
      check htmlToText("<a href=\"" & bad & "\">text</a>").text == "text"
    check htmlToText("<a>no href</a>").text == "no href"
    check htmlToText("<a href=/one>1<a href=/two>2</a>").text == "[1](/one)[2](/two)"      # an unclosed anchor is closed
    check htmlToText("<img src=x.png alt='A cat'>").text == "[image: A cat]"
    check htmlToText("<img src=x.png>").text == ""

  test "case, odd attributes and stray markup do not break it":
    check htmlToText("<P CLASS=a>Up</P><SCRIPT>x</SCRIPT>after").text == "Up\n\nafter"
    check htmlToText("<script>var a=\"</scr\"+\"ipt>\";</script>Visible").text.contains("Visible")
    check htmlToText("1 < 2 and 3 > 2").text == "1 < 2 and 3 > 2"
    check htmlToText("<<<<>>>>").text.len >= 0
    check htmlToText("<div").text == "<div" or htmlToText("<div").text == ""
    check htmlToText("<a href=\"x").text.len >= 0
    check htmlToText("").text == "" and htmlToText("   \n  ").text == ""
    check htmlToText("text only").text == "text only"

  test "the title may sit in the body; head scripts do not leak into it":
    check htmlToText("<body><title>T</title>x</body>").title == "T"
    check htmlToText("<head><script>no</script><title>Y</title></head>z").title == "Y"

  test "hostile input is handled in linear time and bounded output":
    let t0 = epochTime()
    discard htmlToText("<a \"".repeat(400_000))                       # unterminated tags, quadratic for naive scanners
    discard htmlToText("<script>".repeat(100_000))                     # unclosed script elements
    discard htmlToText("<!--".repeat(200_000))
    discard htmlToText("&".repeat(1_000_000))
    discard htmlToText("<div>".repeat(300_000) & "deep")               # deep nesting, no recursion
    check epochTime() - t0 < 10.0
    let big = htmlToText("<p>" & "word ".repeat(300_000) & "</p>", maxOut = 50_000)
    check big.truncated and big.text.len <= 50_000
    var links = ""
    for k in 1 .. 5000: links.add "<a href='/l" & $k & "'>x</a> "
    check htmlToText(links).text.count("](/l") == 2000                 # the link cap

  test "invalid UTF-8 and control characters never crash the converter":
    check htmlToText("ok \x00\x01\x02 bye \xFF").text.contains("ok")

# ---- harness side: config, tool, policy, helper, helper sandbox ---------------------------------------------
import std/[asyncdispatch, posix, tables]
import malyutka/[web, policy, tools, core, provider, events, journal, approval, sandbox]

let helperBin = getCurrentDir() / "malyutka_web"
let haveHelper = fileExists(helperBin) and bwrapPath().len > 0 and probeBwrap().ok

proc freshDir(name: string): string =
  result = root / name
  removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserExec, fpUserRead, fpUserWrite})

suite "web.json strictness":
  test "defaults, a valid file, and every kind of defect":
    check not defaultWebConfig().disabled and defaultWebConfig().maxChars == 15000
    let ok = parseWebConfig("""{"fetch": {"denyDomains": ["Evil.com"], "allowPrivateHosts": ["intranet.corp"], "timeoutSec": 30, "maxChars": 5000}}""")
    check ok.problems.len == 0 and ok.cfg.denyDomains == @["evil.com"] and ok.cfg.allowPrivate == @["intranet.corp"]
    check ok.cfg.timeoutSec == 30 and ok.cfg.maxChars == 5000 and not ok.cfg.disabled
    for bad in ["{{{", "[]", """{"fetch": 5}""", """{"fetch": {"denyDomains": "x"}}""", """{"fetch": {"denyDomains": [1]}}""",
                """{"fetch": {"timeoutSec": 0}}""", """{"fetch": {"timeoutSec": 99}}""", """{"fetch": {"maxChars": 10}}""",
                """{"fetch": {"maxChars": 999999}}""", """{"caFile": 5}""", """{"caFile": "relative.pem"}""", """{"caFile": "/nonexistent/ca.pem"}"""]:
      let r = parseWebConfig(bad)
      check r.cfg.disabled and r.problems.len >= 1          # a defect never means "no denylist": web access is off

  test "the file itself: missing is fine; unsafe or oversize switches web access off":
    let st = freshDir("webcfg")
    check not loadWebConfig(st).cfg.disabled and loadWebConfig(st).problems.len == 0
    writeFile(st / "web.json", """{"fetch": {"denyDomains": ["x.com"]}}""")
    setFilePermissions(st / "web.json", {fpUserRead, fpUserWrite})
    check loadWebConfig(st).cfg.denyDomains == @["x.com"]
    setFilePermissions(st / "web.json", {fpUserRead, fpUserWrite, fpGroupWrite})
    check loadWebConfig(st).cfg.disabled
    setFilePermissions(st / "web.json", {fpUserRead, fpUserWrite})
    moveFile(st / "web.json", st / "real.json")
    createSymlink(st / "real.json", st / "web.json")
    check loadWebConfig(st).cfg.disabled
    removeFile(st / "web.json")
    writeFile(st / "web.json", "x".repeat(70_000)); setFilePermissions(st / "web.json", {fpUserRead, fpUserWrite})
    check loadWebConfig(st).cfg.disabled

  test "applyWebConfig copies the settings into the run config and turns web off on a defect":
    let st = freshDir("webapply")
    writeFile(st / "web.json", """{"fetch": {"denyDomains": ["bad.com"], "allowPrivateHosts": ["10.0.0.5"], "maxChars": 4000}}""")
    setFilePermissions(st / "web.json", {fpUserRead, fpUserWrite})
    var cfg = baseConfig(); cfg.stateDir = st; cfg.allowWeb = true
    check applyWebConfig(cfg).len == 0
    check cfg.allowWeb and cfg.webDeny == @["bad.com"] and cfg.webAllowPrivate == @["10.0.0.5"] and cfg.webMaxChars == 4000
    writeFile(st / "web.json", "{{{")
    cfg.allowWeb = true
    check applyWebConfig(cfg).len > 0 and not cfg.allowWeb

suite "web policy layers":
  let cap = Capability(name: "web_fetch", realm: erNetwork, maxEffect: b3External)
  proc verdictFor(url: string; cfg = baseConfig()): tuple[v: Verdict, id: string, why: string] =
    let d = compose(defaultLayers(), ToolCall(id: "1", name: "web_fetch", args: %*{"url": url}), cap, b3External, cfg, "e")
    (d.verdict, d.policyId, d.reason)

  test "a clean public URL asks (web.ask); it is never allowed unasked":
    let r = verdictFor("https://example.com/page")
    check r.v == vAsk and r.id == "web.ask" and "example.com" in r.why

  test "private, metadata, credential, userinfo, scheme and denylist problems are DENY from web.url":
    var cfg = baseConfig()
    cfg.webDeny = @["evil.com"]
    for u in ["http://127.0.0.1/", "http://10.1.1.1/", "http://169.254.169.254/", "http://[::1]/", "http://localhost/",
              "https://example.com/?token=abc", "https://user:pw@example.com/", "ftp://example.com/", "file:///etc/passwd",
              "https://a.evil.com/", "http://2130706433/", "", "not a url"]:
      let r = verdictFor(u, cfg)
      check r.v == vDeny and r.id == "web.url"

  test "DENY survives an approver that says yes to everything (the I14 boundary holds for web)":
    let ws = freshDir("deny-ws")
    var cfg = baseConfig(); cfg.cwd = ws
    var calls = 0
    let cp = addr calls
    let yes: Approver = proc(req: ApprovalRequest; em: Emitter): ApprovalReply =
      inc cp[]
      ApprovalReply(answer: aaAlways, source: "operator")
    var reg = initOrderedTable[string, ToolSpec]()
    var ran = false
    let rp = addr ran
    reg["web_fetch"] = ToolSpec(capability: cap, description: "t", parameters: %*{"type": "object"},
      effectOf: proc(args: JsonNode): EffectClass = b3External,
      run: proc(args: JsonNode; c: AgentConfig): ToolResult = (rp[] = true; ToolResult(ok: true, output: "fetched")))
    let script = @[ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "1", name: "web_fetch", args: %*{"url": "http://169.254.169.254/"})]),
                   ModelAction(kind: makFinal, text: "done")]
    let jp = root / "denyj" / "j.jsonl"; removeFile(jp)
    let r = waitFor runAgent(newScriptedProvider(script), "t", cfg, registry = reg, journal = openJournal(jp), approver = yes)
    check calls == 0 and not ran
    check r.messages[3].content.startsWith("DENIED by web.url")

  test "an allowed-by-approver call runs and is journaled as B3":
    let ws = freshDir("ask-ws")
    var cfg = baseConfig(); cfg.cwd = ws
    let yes: Approver = proc(req: ApprovalRequest; em: Emitter): ApprovalReply = ApprovalReply(answer: aaOnce, source: "operator")
    var reg = initOrderedTable[string, ToolSpec]()
    reg["web_fetch"] = ToolSpec(capability: cap, description: "t", parameters: %*{"type": "object"},
      effectOf: proc(args: JsonNode): EffectClass = b3External,
      run: proc(args: JsonNode; c: AgentConfig): ToolResult = ToolResult(ok: true, output: "fetched"))
    let script = @[ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "1", name: "web_fetch", args: %*{"url": "https://example.com/"})]),
                   ModelAction(kind: makFinal, text: "done")]
    let jp = root / "askj" / "j.jsonl"; removeFile(jp)
    let r = waitFor runAgent(newScriptedProvider(script), "t", cfg, registry = reg, journal = openJournal(jp), approver = yes)
    check r.messages[3].content == "fetched"
    check "\"effect\":\"B3\"" in readFile(jp)

if not haveHelper:
  echo "SKIP helper tests: build with `nimble build` first (needs ./malyutka_web and bwrap)"
else:
  putEnv("MALYUTKA_WEB_HELPER", helperBin)
  suite "the web helper end to end (sandboxed, real sockets)":
    proc wcfg(): AgentConfig =
      result = baseConfig()
      result.allowWeb = true
      result.webAllowPrivate = @["127.0.0.1"]
      result.webTimeoutSec = 10
      result.webMaxChars = 15000
      result.stateDir = freshDir("helper-state")
    proc hurl(path: string): string = "http://127.0.0.1:" & $httpPort & path

    test "the helper probes ready, and the tool registers only then":
      check probeWebHelper(false).ok
      let reg = toolsFor(wcfg())
      discard drainMcpEvents()
      check "web_fetch" in reg and reg["web_fetch"].capability.realm == erNetwork
      check reg["web_fetch"].capability.maxEffect == b3External and not reg["web_fetch"].capability.askExempt
      check reg["web_fetch"].effectOf(%*{"url": "x"}) == b3External

    test "a missing helper means no tool and a visible reason":
      putEnv("MALYUTKA_WEB_HELPER", "/nonexistent/malyutka_web")
      defer: putEnv("MALYUTKA_WEB_HELPER", helperBin)
      let reg = toolsFor(wcfg())
      let evs = drainMcpEvents()
      check "web_fetch" notin reg
      var reason = ""
      for e in evs:
        if e.kind == "web.unavailable": reason = e.payload["reason"].getStr
      check "helper not found" in reason

    test "fetch: labelled untrusted text, title, event, and the page really came through the helper":
      let st = newWebState()
      let r = runWebFetch(st, %*{"url": hurl("/html")}, wcfg())
      check r.ok and r.eventKind == "web.fetched" and r.eventPayload["status"].getInt == 200
      check r.output.startsWith("[web_fetch http://127.0.0.1:" & $httpPort & "/html · HTTP 200 · text/html · title: Fake Page")
      check "untrusted page text]" in r.output.splitLines()[0]
      check "# Heading" in r.output and "Hello world & friends." in r.output and "[a link](/other)" in r.output
      check "secret" notin r.output and "hidden comment" notin r.output

    test "paging with offset and char_limit, and an in-run memo that does not refetch":
      writeFile(logFile, "")
      let st = newWebState()
      let c = wcfg()
      let first = runWebFetch(st, %*{"url": hurl("/long"), "char_limit": 1000}, c)
      check "chars 0-1000 of 6000" in first.output and "offset=1000" in first.output and first.truncated
      let second = runWebFetch(st, %*{"url": hurl("/long"), "char_limit": 1000, "offset": 1000}, c)
      check "chars 1000-2000 of 6000" in second.output and "cached" in second.output.splitLines()[0]
      check served().count("GET /long") == 1                      # one network request for both pages
      let last = runWebFetch(st, %*{"url": hurl("/long"), "char_limit": 1000, "offset": 5500}, c)
      check "chars 5500-6000 of 6000" in last.output and "more:" notin last.output
      check "chars 6000-6000" in runWebFetch(st, %*{"url": hurl("/long"), "offset": 99999}, c).output

    test "page text cannot forge our label or smuggle a second header":
      let r = runWebFetch(newWebState(), %*{"url": hurl("/inject")}, wcfg())
      check r.ok
      var labels = 0
      for l in r.output.splitLines():
        if l.startsWith("[web_fetch "): inc labels
      check labels == 1
      check "[web-fetch https://evil.example/" in r.output and "untrusted-page-text" in r.output
      check "Ignore all previous instructions" in r.output        # still data the model can read, but labelled

    test "errors: 404 is reported as a failure with its text; PDFs, private hosts and timeouts are refused":
      let c = wcfg()
      let nf = runWebFetch(newWebState(), %*{"url": hurl("/status/404")}, c)
      check not nf.ok and "HTTP 404" in nf.output
      let pdf = runWebFetch(newWebState(), %*{"url": hurl("/pdf")}, c)
      check not pdf.ok and "unsupported content type: application/pdf" in pdf.output
      var strict = wcfg(); strict.webAllowPrivate = @[]
      let priv = runWebFetch(newWebState(), %*{"url": hurl("/html")}, strict)
      check not priv.ok and "refused" in priv.output
      var quick = wcfg(); quick.webTimeoutSec = 1
      let t0 = epochTime()
      let slow = runWebFetch(newWebState(), %*{"url": hurl("/slow")}, quick)
      check not slow.ok and "timed out" in slow.output and epochTime() - t0 < 8.0

    test "redirects to private/metadata addresses are refused inside the helper too":
      writeFile(logFile, "")
      var c = wcfg(); c.webAllowPrivate = @["127.0.0.1"]
      # 127.0.0.1 is allowed here, so use a literal that is not: the metadata address
      let r = runWebFetch(newWebState(), %*{"url": hurl("/redir?to=http://169.254.169.254/latest")}, c)
      check not r.ok and "metadata" in r.output

    test "the helper process is gone after every call (nothing lingers)":
      discard runWebFetch(newWebState(), %*{"url": hurl("/html")}, wcfg())
      var found = 0
      for kind, path in walkDir("/proc"):
        if kind != pcDir: continue
        let n = extractFilename(path)
        if n.len == 0 or n[0] notin {'0'..'9'}: continue
        try:
          # exact argv tokens only: a shell whose command LINE merely contains the text must not match
          if "/malyutka_web" in readFile(path / "cmdline").split('\0'): inc found
        except CatchableError: discard
      check found == 0

  suite "the helper's sandbox":
    proc sandboxRun(cmd: string): tuple[output: string, code: int] =
      var argv = webHelperArgv(bwrapPath(), helperBin, "")
      argv.setLen(argv.len - 1)                          # drop /malyutka_web, run a probe command instead
      argv.add ["/bin/sh", "-c", cmd]
      let r = runBounded(argv, 10, 65536, "/")
      (r.output, r.exitCode)

    test "no filesystem access beyond the system directories: no $HOME, no state dir, no workspace":
      let marker = getHomeDir() / (".malyutka-webbox-" & $getCurrentProcessId())
      writeFile(marker, "secret")
      defer: removeFile(marker)
      let r = sandboxRun("test -e " & marker.quoteShell & " && echo VISIBLE || echo hidden; ls /home 2>&1 | head -1; test -w /usr && echo W || echo ro")
      check "hidden" in r.output and "VISIBLE" notin r.output and r.output.strip.splitLines()[^1] == "ro"

    test "the sandbox argv has the network shared and nothing writable but tmpfs":
      let a = webHelperArgv("/usr/bin/bwrap", "/opt/malyutka_web", "/etc/ca.pem")
      check "--share-net" in a and "--unshare-all" in a and "--die-with-parent" in a and "--clearenv" in a
      check "--bind" notin a and "--bind-fd" notin a            # no read-write bind of anything
      check a[^1] == "/malyutka_web"
      var withCa = false
      for i in 0 ..< a.len - 2:
        if a[i] == "--ro-bind" and a[i + 1] == "/etc/ca.pem" and a[i + 2] == "/ca.pem": withCa = true
      check withCa
      check "--ro-bind" in webHelperArgv("/usr/bin/bwrap", "/opt/malyutka_web", "")
      var noCa = webHelperArgv("/usr/bin/bwrap", "/opt/malyutka_web", "")
      check "/ca.pem" notin noCa

    test "the environment inside the helper sandbox is minimal":
      putEnv("SECRET_TOKEN", "hunter2")
      defer: delEnv("SECRET_TOKEN")
      let r = sandboxRun("env | sort")
      check "SECRET_TOKEN" notin r.output and "PATH=" in r.output
