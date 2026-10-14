## Search backends for the web helper (SPEC-011, invariant 18): SearXNG, Brave Search and Tavily.
## Runs inside `malyutka_web` only (it needs the TLS client). A backend is chosen explicitly by the
## operator; there is NO fallback from one to another (a query silently going to a different third
## party is a leak). A credential is attached to exactly one request, to the configured https host,
## redirects are not followed for it, and it appears in no error text.

import std/[json, strutils, uri]
import ./[urlsafety, httpfetch, htmltext]

const
  MaxHits* = 20
  MaxTitle = 200
  MaxHitUrl = 500
  MaxDescription = 600
  SearchBodyCap = 1024 * 1024
  Backends* = ["searxng", "brave", "tavily"]

type
  SearchHit* = object
    title*, url*, description*: string
    position*: int

  SearchReq* = object
    backend*, base*, key*, query*: string
    limit*: int

  SearchOutcome* = object
    ok*: bool
    error*: string
    hits*: seq[SearchHit]

proc keyed*(backend: string): bool = backend in ["brave", "tavily"]

proc clip(s: string; n: int): string =
  if s.len <= n: return s
  var cut = n
  while cut > 0 and (ord(s[cut]) and 0xC0) == 0x80: dec cut
  s[0 ..< cut] & "…"

proc tidy(s: string; n: int): string =
  ## Titles and snippets are untrusted markup-ish text: tags and entities out, one line, bounded.
  var t = s
  if '<' in t or '&' in t: t = htmlToText(t, 4 * n).text
  clip(t.splitWhitespace.join(" "), n)

# ---- building the request ------------------------------------------------------------

proc buildRequest*(r: SearchReq): tuple[url: string, opts: FetchOpts, err: string] =
  if r.backend notin Backends: result.err = "unknown search backend"; return
  let q = r.query.strip
  let why = queryProblem(q)
  if why.len > 0: result.err = why; return
  let limit = clamp(r.limit, 1, MaxHits)
  var base = r.base.strip
  while base.endsWith("/"): base.setLen(base.len - 1)
  if base.len == 0: result.err = "no endpoint configured for " & r.backend; return
  if '?' in base or '#' in base: result.err = "the configured endpoint must not carry a query string"; return
  var o = defaultOpts()
  o.maxBody = SearchBodyCap
  o.followRedirects = false                  # a key or a query is never replayed to a redirect target
  o.requireHttps = keyed(r.backend)          # a credential never travels in clear
  case r.backend
  of "searxng":
    result.url = base & "/search?q=" & encodeUrl(q, usePlus = false) & "&format=json"
  of "brave":
    if r.key.len == 0: result.err = "no API key"; return
    result.url = base & "?q=" & encodeUrl(q, usePlus = false) & "&count=" & $limit
    o.headers = @[("X-Subscription-Token", r.key)]
  else: # tavily
    if r.key.len == 0: result.err = "no API key"; return
    result.url = base
    o.meth = "POST"
    o.headers = @[("Authorization", "Bearer " & r.key), ("Content-Type", "application/json")]
    o.body = $(%*{"query": q, "max_results": limit, "search_depth": "basic", "include_answer": false})
  result.opts = o

# ---- reading the answer --------------------------------------------------------------

proc hitsFrom(arr: JsonNode; descKey: string; limit: int): seq[SearchHit] =
  if arr == nil or arr.kind != JArray: return
  for e in arr:
    if result.len >= limit: break
    if e.kind != JObject: continue
    let u = e{"url"}.getStr.strip
    let lu = u.toLowerAscii
    if u.len == 0 or u.len > MaxHitUrl or not (lu.startsWith("http://") or lu.startsWith("https://")): continue
    var bad = false
    for c in u:
      if c <= ' ' or c == '\x7f': bad = true
    if bad: continue
    result.add SearchHit(title: tidy(e{"title"}.getStr, MaxTitle), url: u,
                         description: tidy(e{descKey}.getStr, MaxDescription), position: result.len + 1)

proc parseHits*(backend, body: string; limit: int): SearchOutcome =
  var j: JsonNode
  try: j = parseJson(body)
  except CatchableError:
    result.error = "the search service did not answer with JSON"
    return
  if j.kind != JObject:
    result.error = "unexpected search answer"
    return
  let lim = clamp(limit, 1, MaxHits)
  case backend
  of "searxng": result.hits = hitsFrom(j{"results"}, "content", lim)
  of "brave": result.hits = hitsFrom(j{"web"}{"results"}, "description", lim)
  of "tavily": result.hits = hitsFrom(j{"results"}, "content", lim)
  else:
    result.error = "unknown search backend"
    return
  result.ok = true

proc runSearch*(r: SearchReq; timeoutSec: int; caFile: string; denyDomains, allowPrivate: seq[string];
                resolver: Resolver = nil): SearchOutcome =
  var (url, opts, err) = buildRequest(r)
  if err.len > 0:
    result.error = err
    return
  opts.timeoutSec = timeoutSec
  opts.caFile = caFile
  opts.denyDomains = denyDomains
  opts.allowPrivate = allowPrivate
  opts.resolver = resolver
  let f = fetch(url, opts)
  if not f.ok:
    result.error = f.error
    return
  if f.status < 200 or f.status >= 300:
    case f.status
    of 401, 403:
      result.error = "the search service refused the request (HTTP " & $f.status & ")" &
        (if r.backend == "searxng": "; SearXNG answers 403 when `json` is missing from search.formats in settings.yml"
         else: "; check the API key")
    of 429: result.error = "the search service is rate limiting (HTTP 429)"
    else: result.error = "the search service answered HTTP " & $f.status
    return
  parseHits(r.backend, f.body, r.limit)
