## URL and address safety for web access (SPEC-011, invariant 18). Pure functions plus an
## injectable resolver: nothing here opens a socket except `systemResolver`. The same rules
## run in the policy layer (literal checks, no DNS) and in the helper (every DNS answer
## vetted, then the connection is made to a vetted address).

import std/[net, nativesockets, strutils, uri]

const
  MaxUrlLen* = 2048
  MaxHostLen = 253

type
  WebUrl* = object
    ok*: bool
    why*: string
    host*: string        ## lowercase, no brackets, no trailing dot
    port*: int
    https*: bool
    target*: string      ## path + "?" + query, as sent in the request line
    raw*: string

  Resolver* = proc(host: string): seq[string] {.closure.}

# ---- addresses ----------------------------------------------------------------

proc isIpLiteral*(host: string): bool =
  try:
    discard parseIpAddress(host)
    true
  except ValueError:
    false

proc v4Reason(b: array[4, uint8]): string =
  let a = int(b[0])
  let c = int(b[1])
  if a == 0: "this-network (0.0.0.0/8)"
  elif a == 10: "private (10.0.0.0/8)"
  elif a == 100 and c in 64 .. 127: "carrier-grade NAT (100.64.0.0/10)"
  elif a == 127: "loopback (127.0.0.0/8)"
  elif a == 169 and c == 254: "link-local (169.254.0.0/16)"
  elif a == 172 and c in 16 .. 31: "private (172.16.0.0/12)"
  elif a == 192 and c == 0 and b[2] == 0: "reserved (192.0.0.0/24)"
  elif a == 192 and c == 0 and b[2] == 2: "documentation (192.0.2.0/24)"
  elif a == 192 and c == 168: "private (192.168.0.0/16)"
  elif a == 198 and c in 18 .. 19: "benchmarking (198.18.0.0/15)"
  elif a == 198 and c == 51 and b[2] == 100: "documentation (198.51.100.0/24)"
  elif a == 203 and c == 0 and b[2] == 113: "documentation (203.0.113.0/24)"
  elif a >= 224: "multicast/reserved (224.0.0.0/3)"
  else: ""

proc embeddedV4(b: array[16, uint8]): tuple[has: bool, v4: array[4, uint8]] =
  ## IPv4 carried inside IPv6: ::ffff:a.b.c.d, 64:ff9b::/96 (NAT64), 2002::/16 (6to4).
  var zeros10 = true
  for i in 0 .. 9:
    if b[i] != 0: zeros10 = false
  if zeros10 and b[10] == 0xff and b[11] == 0xff:
    return (true, [b[12], b[13], b[14], b[15]])
  if b[0] == 0 and b[1] == 0x64 and b[2] == 0xff and b[3] == 0x9b:
    var zeros = true
    for i in 4 .. 11:
      if b[i] != 0: zeros = false
    if zeros: return (true, [b[12], b[13], b[14], b[15]])
  if b[0] == 0x20 and b[1] == 0x02:
    return (true, [b[2], b[3], b[4], b[5]])

proc v6Reason(b: array[16, uint8]): string =
  var allZero = true
  for i in 0 .. 15:
    if b[i] != 0: allZero = false
  if allZero: return "unspecified (::)"
  var loop = true
  for i in 0 .. 14:
    if b[i] != 0: loop = false
  if loop and b[15] == 1: return "loopback (::1)"
  let emb = embeddedV4(b)
  if emb.has:
    let r = v4Reason(emb.v4)
    return (if r.len > 0: "embedded IPv4: " & r else: "")
  if b[0] == 0xfe and (int(b[1]) and 0xc0) == 0x80: return "link-local (fe80::/10)"
  if b[0] == 0xfe and (int(b[1]) and 0xc0) == 0xc0: return "site-local (fec0::/10)"
  if (int(b[0]) and 0xfe) == 0xfc: return "unique-local (fc00::/7)"
  if b[0] == 0xff: return "multicast (ff00::/8)"
  if b[0] == 0x01 and b[1] == 0 and b[2] == 0 and b[3] == 0 and b[4] == 0 and b[5] == 0 and b[6] == 0 and b[7] == 0:
    return "discard-only (100::/64)"
  if b[0] == 0x20 and b[1] == 0x01 and b[2] == 0x0d and b[3] == 0xb8: return "documentation (2001:db8::/32)"
  if b[0] == 0x20 and b[1] == 0x01 and b[2] == 0 and b[3] == 0: return "Teredo (2001::/32)"
  ""

proc ipBlockReason*(ip: IpAddress): string =
  ## "" when the address is publicly routable; otherwise why it is not.
  case ip.family
  of IpAddressFamily.IPv4: v4Reason(ip.address_v4)
  of IpAddressFamily.IPv6: v6Reason(ip.address_v6)

proc floorV4(b: array[4, uint8]): bool =
  (b[0] == 169 and b[1] == 254) or (b[0] == 100 and b[1] == 100 and b[2] == 100 and b[3] == 200)

proc metadataFloor*(ip: IpAddress): bool =
  ## Cloud metadata and link-local addresses: never reachable, whatever the operator allows.
  case ip.family
  of IpAddressFamily.IPv4: floorV4(ip.address_v4)
  of IpAddressFamily.IPv6:
    let b = ip.address_v6
    if b[0] == 0xfe and (int(b[1]) and 0xc0) == 0x80: return true           # fe80::/10
    if b[0] == 0xfd and b[1] == 0 and b[2] == 0x0e and b[3] == 0xc2 and b[14] == 0x02 and b[15] == 0x54:
      return true                                                           # fd00:ec2::254
    let emb = embeddedV4(b)
    emb.has and floorV4(emb.v4)

const MetadataHosts = ["metadata.google.internal", "metadata.goog", "metadata", "instance-data", "instance-data.ec2.internal"]

proc metadataHost*(host: string): bool = host in MetadataHosts

# ---- URLs -----------------------------------------------------------------------

proc validHostChars(host: string): bool =
  for c in host:
    if c notin {'a'..'z', '0'..'9', '-', '.', '_'}: return false
  true

proc looksNumeric(host: string): bool =
  ## Decimal/hex/octal IP spellings such as 2130706433, 0x7f.1, 017700000001: classic SSRF bypasses.
  if host.len == 0 or host[0] notin {'0'..'9'}: return false
  for c in host:
    if c notin {'0'..'9', '.', 'a'..'f', 'x'}: return false
  true

proc parseWebUrl*(raw: string): WebUrl =
  result.raw = raw
  if raw.len == 0 or raw.len > MaxUrlLen:
    result.why = "URL must be 1-" & $MaxUrlLen & " characters"; return
  for c in raw:
    if c < ' ' or c == '\x7f' or c == ' ' or c == '\\':
      result.why = "URL contains control characters, spaces or backslashes"; return
  var u: Uri
  try: u = parseUri(raw)
  except CatchableError: result.why = "unparseable URL"; return
  let scheme = u.scheme.toLowerAscii
  if scheme notin ["http", "https"]:
    result.why = "only http and https URLs are allowed"; return
  if u.username.len > 0 or u.password.len > 0:
    result.why = "URLs with embedded credentials (user:pass@) are refused"; return
  var host = u.hostname.toLowerAscii
  if host.endsWith("."): host.setLen(host.len - 1)
  if host.len == 0 or host.len > MaxHostLen:
    result.why = "URL has no usable host"; return
  if ':' in host:
    # IPv6 literal (brackets already removed by the parser)
    if not isIpLiteral(host): result.why = "malformed IPv6 literal"; return
  elif isIpLiteral(host):
    discard                                        # canonical dotted quad
  elif looksNumeric(host):
    result.why = "non-canonical IP address spelling (" & host & ") is refused"; return
  else:
    if not validHostChars(host):
      result.why = "host contains characters outside a-z 0-9 - . _ (use punycode for international names)"; return
    for label in host.split('.'):
      if label.len == 0 or label.len > 63:
        result.why = "malformed host name"; return
  var port = if scheme == "https": 443 else: 80
  if u.port.len > 0:
    try: port = parseInt(u.port)
    except ValueError: result.why = "malformed port"; return
    if port < 1 or port > 65535: result.why = "port out of range"; return
  var target = if u.path.len > 0: u.path else: "/"
  if not target.startsWith("/"): target = "/" & target
  if u.query.len > 0: target.add "?" & u.query
  result.ok = true
  result.host = host
  result.port = port
  result.https = scheme == "https"
  result.target = target

proc allowedPrivate*(host: string; allowPrivate: seq[string]): bool =
  host.toLowerAscii in allowPrivate

proc literalReason*(w: WebUrl; allowPrivate: seq[string]): string =
  ## Checks that need no DNS: metadata names, localhost names, literal addresses.
  if metadataHost(w.host): return "cloud metadata host"
  if isIpLiteral(w.host):
    let ip = parseIpAddress(w.host)
    if metadataFloor(ip): return "address " & w.host & " is in the always-blocked metadata/link-local range"
    let r = ipBlockReason(ip)
    if r.len > 0 and not allowedPrivate(w.host, allowPrivate): return "address " & w.host & " is not public: " & r
  elif (w.host == "localhost" or w.host.endsWith(".localhost")) and not allowedPrivate(w.host, allowPrivate):
    return "localhost is not a public host"

# ---- secrets in URLs ----------------------------------------------------------------

const SecretNames = ["token", "access_token", "id_token", "refresh_token", "api_key", "apikey", "api-key",
  "secret", "client_secret", "password", "passwd", "pwd", "signature", "sig", "x-amz-signature",
  "x-amz-credential", "x-amz-security-token", "authorization", "auth", "bearer", "jwt", "session",
  "sessionid", "sid", "x-api-key"]

proc looksLikeSecretValue(v: string): bool =
  let t = v.strip
  if t.len >= 24 and t.startsWith("sk-"): return true
  if t.startsWith("ghp_") or t.startsWith("gho_") or t.startsWith("ghs_") or t.startsWith("github_pat_"): return t.len >= 20
  if t.len == 20 and t.startsWith("AKIA"): return true
  if t.startsWith("xoxb-") or t.startsWith("xoxp-") or t.startsWith("xapp-"): return true
  if t.startsWith("hf_") and t.len >= 20: return true
  if "BEGIN PRIVATE KEY" in t or "BEGIN RSA PRIVATE KEY" in t or "BEGIN OPENSSH PRIVATE KEY" in t: return true
  false

proc secretInUrl*(raw: string): string =
  ## "" if nothing looks like a credential; otherwise what was found. Parameter NAMES count only
  ## with a non-empty value; known secret FORMATS count anywhere in the query or path.
  var u: Uri
  try: u = parseUri(raw)
  except CatchableError: return ""
  for pair in u.query.split('&'):
    if pair.len == 0: continue
    let eq = pair.find('=')
    let name = (if eq >= 0: pair[0 ..< eq] else: pair).toLowerAscii
    let value = (if eq >= 0: decodeUrl(pair[eq + 1 .. ^1]) else: "")
    if value.len > 0:
      if name in SecretNames or name.endsWith("_token") or name.endsWith("-token") or name.endsWith("_secret") or
         name.endsWith("_key") or name.endsWith("-key") or name.endsWith("_password"):
        return "query parameter '" & name & "' looks like a credential"
    if looksLikeSecretValue(value): return "a query value has the format of a secret"
  for seg in decodeUrl(u.path).split('/'):
    if looksLikeSecretValue(seg): return "a path segment has the format of a secret"

# ---- domain denylist ---------------------------------------------------------------

proc domainDenied*(host: string; rules: seq[string]): string =
  ## "example.com" matches the host and its subdomains; "*.example.com" only subdomains.
  let h = host.toLowerAscii
  for r in rules:
    let rule = r.toLowerAscii.strip
    if rule.len == 0: continue
    if rule.startsWith("*."):
      if h.endsWith(rule[1 .. ^1]): return rule
    elif h == rule or h.endsWith("." & rule): return rule

proc urlPolicyReason*(raw: string; denyDomains, allowPrivate: seq[string]): string =
  ## Everything a policy layer can decide without DNS. "" = acceptable.
  let w = parseWebUrl(raw)
  if not w.ok: return w.why
  let s = secretInUrl(raw)
  if s.len > 0: return s
  let d = domainDenied(w.host, denyDomains)
  if d.len > 0: return "domain is on the denylist (" & d & ")"
  literalReason(w, allowPrivate)

# ---- resolution ----------------------------------------------------------------------

proc systemResolver*(host: string): seq[string] =
  ## All A/AAAA answers (blocking getaddrinfo). Raises OSError when resolution fails.
  let ais = getAddrInfo(host, Port(0), AF_UNSPEC)
  if ais == nil: raise newException(OSError, "no addresses")
  var p = ais
  while p != nil:
    let s = getAddrString(p.ai_addr)
    if s.len > 0 and s notin result: result.add s
    p = p.ai_next
  freeAddrInfo(ais)

proc resolveVetted*(host: string; resolver: Resolver; allowPrivate: seq[string]):
    tuple[ips: seq[IpAddress], why: string] =
  ## Fail closed: ANY unusable answer rejects the host. Called once per hop; the caller
  ## connects to one of the returned addresses and never resolves again.
  var names: seq[string]
  if isIpLiteral(host): names = @[host]
  else:
    try: names = resolver(host)
    except CatchableError as e: return (@[], "cannot resolve " & host & ": " & e.msg)
  if names.len == 0: return (@[], "no addresses for " & host)
  for n in names:
    var ip: IpAddress
    try: ip = parseIpAddress(n)
    except ValueError: return (@[], "resolver returned an unparseable address: " & n)
    if metadataFloor(ip):
      return (@[], host & " resolves to " & n & ", in the always-blocked metadata/link-local range")
    let r = ipBlockReason(ip)
    if r.len > 0 and not allowedPrivate(host, allowPrivate):
      return (@[], host & " resolves to " & n & " (" & r & ")")
    result.ips.add ip
