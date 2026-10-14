# SPEC-011 — Web access (search and fetch)

**Status:** `web_fetch` and `web_search` (SearXNG, Brave, Tavily) implemented (unreleased, planned 0.9.0) · **Invariant:** I18 (new) · **Roadmap:** M2 tail

## Goals
Let the agent search the web and read pages without giving up the gates: every web call is an external effect
that asks, never reaches a non-public address, never leaks a credential, and returns bounded, labelled-untrusted
text.

## Non-goals
JavaScript rendering or a browser, PDF/office extraction, cookies or logins, uploads, a disk cache (all in `todo/`).

## Threat model
| Threat | Defence |
|---|---|
| Exfiltration: the model puts a secret into a query or URL | every call is B3 and **asks**; URLs with userinfo, secret-looking parameters or known secret formats are **denied**; the approval shows the exact query/URL |
| SSRF: fetch `127.0.0.1`, intranet, cloud metadata | scheme allow-list; literal-IP and name checks in the policy layer; **every DNS answer vetted** and the connection made to the vetted IP; metadata floor that no setting lifts |
| DNS rebinding / redirects | one resolution per hop, connect to that IP; redirects followed manually, every hop re-vetted, https→http refused |
| Prompt injection in page text | text is data (I1): bounded, labelled `untrusted page text`, our own markers stripped; it can neither add a tool nor change a verdict |
| Credential leakage (search API keys) | key read from the *environment variable named in config*, sent only to its configured https host, never in argv, events, journal or errors |
| Parser / TLS bugs in untrusted-network code | all of it runs in a **separate helper binary** inside bwrap with network but **no filesystem access** (no workspace, no state dir, no `$HOME`) |
| Resource exhaustion | header cap 64 KiB, body cap 2 MiB, text cap, overall deadline, redirect cap, helper killed on timeout |

## Architecture
`malyutka` (no TLS, no libssl dependency) → spawns `malyutka_web` (compiled with `-d:ssl`; OpenSSL is loaded
eagerly at startup by Nim, which is why it is a separate binary) → one JSON request line on stdin, one JSON response
line on stdout. The helper runs in bwrap with `--unshare-all --share-net`, read-only system dirs and CA store,
a read-only bind of itself and (optionally) the configured CA file, a private tmpfs `/tmp`, and nothing else.
If the helper is missing, cannot load libssl, or bwrap is unavailable (and `--unconfined-host` was not given), the
web tools are **not registered** and `web.unavailable {reason}` is emitted; the harness itself is unaffected.

## Tools (`--web`)
| Tool | Args | Effect | Notes |
|---|---|---|---|
| `web_fetch` | `url`, `offset?`, `char_limit?` | B3 | text of one page (HTML→text/markdown, plain text, JSON, XML); default 15 000 chars (1 000–60 000); `offset` pages through it |
| `web_search` | `query`, `limit?` (1–20, default 5) | B3 | the ONE backend selected in `<state>/web.json` (or `--web-backend:NAME`): SearXNG, Brave or Tavily; registered when a backend is configured, or by default against the local SearXNG (below) |

Results are wrapped: `[web_fetch <final url> · <status> · <type> · chars a–b of N · untrusted page text]` then the
text. Search results are `[web_search <backend> · N results · untrusted search results]` then a numbered list of
title, URL and snippet (markup stripped, URLs limited to http/https, every field bounded). Our own label strings are
defanged inside page and result text. An in-run memo returns the same text for a repeated URL/query, flagged `cached`.

### Keyless default: `malyutka web-setup`
With no `search` section in `web.json` (or no file), the backend is a **local SearXNG at `http://127.0.0.1:18888`** with
`trust: ask` (every search asks). `malyutka web-setup [--port:N] [--ask]` starts it: a docker container
(`searxng/searxng:latest`, `--restart unless-stopped`) published on **127.0.0.1 only**, with a generated
`<state>/searxng/settings.yml` (json format enabled, limiter off, random secret), waits until it answers JSON, and writes
`<state>/web.json` with `trust: "allow"` (or `ask` with `--ask`) unless a `web.json` already exists, which it never
overwrites. A `search` section without a backend means "no search"; a missing section for an explicitly selected backend,
a bad `--web-backend`, or a broken file is an error, never replaced by the default. If nothing listens on the default
address the tool error says to run `malyutka web-setup`. DuckDuckGo was considered and rejected: it has no API and its HTML
endpoints answer bots with a challenge page (tested from this host).

### Search backends
| Backend | Request | Credential |
|---|---|---|
| `searxng` | `GET {url}/search?q=…&format=json` (the instance must list `json` under `search.formats` in `settings.yml`; otherwise it answers 403 and the error says so) | none |
| `brave` | `GET {url}?q=…&count=N`, default `https://api.search.brave.com/res/v1/web/search` | header `X-Subscription-Token` |
| `tavily` | `POST {url}` with `{"query","max_results","search_depth":"basic"}`, default `https://api.tavily.com/search` | header `Authorization: Bearer` |

All of it happens in the helper (`websearch.nim`): the harness sends one JSON line (backend, endpoint, query, limit,
key) over the helper's stdin, so a key is never on a command line. **No fallback**: when the selected backend
fails the tool returns the error; the query is not sent anywhere else. Keyed backends require **https** (checked in
the config and again before connecting), redirects are **not followed** for any search request, and the key is
read from the environment variable *named* in the config at call time, validated (no whitespace or newlines,
≤ 512 bytes) and never written to events, the journal, errors or results. A rejected key is reported as "check the
API key" without the key.

## Policy
- `web.url` → **DENY** (an approver can never override it): scheme not http/https, userinfo, secret-looking
  query parameters or secret formats, literal private/loopback/link-local/metadata addresses, `localhost`-style
  names, denylisted domains, URLs over 2048 characters, non-canonical IP literals (decimal/hex/octal forms),
  non-ASCII hosts (use punycode).
  A `web_search` query that is empty, over 400 characters, contains control characters or has the **shape of a
  credential** (`sk-…`, `ghp_…`, `AKIA…`, `xox…`, private-key blocks, …) is also **DENY** from `web.url`.
- `web.ask` → **ASK** for every call (mandate → approver → deny); the reason names the backend and the exact query
  (first 120 characters). Only a `web_search` against a **loopback SearXNG** configured `trust: allow` is exempt, and
  the exemption is **re-derived from the live configuration at every decision** (`searchExempt`: backend is
  `searxng`, `trust` is `allow`, host is `localhost`, `127.0.0.0/8` or `::1`); the flag on the capability alone is
  not enough, and it never applies to `web_fetch`.
- DNS-dependent checks happen in the helper at connect time and return a tool error.

## Config `<state>/web.json` (strict file: real, operator-owned, not group/world-writable)
```json
{"search": {"backend": "searxng",
            "searxng": {"url": "http://127.0.0.1:8888", "trust": "allow"},
            "brave":   {"apiKeyEnv": "BRAVE_API_KEY"},
            "tavily":  {"apiKeyEnv": "TAVILY_API_KEY"}},
 "fetch":  {"denyDomains": ["*.corp.example"], "allowPrivateHosts": [], "timeoutSec": 20, "maxChars": 15000},
 "caFile": ""}
```
Validation (a defect of any kind switches web access off, like the rest of the file): `search.backend` is one of the
three; each present section may contain only `url`, `apiKeyEnv` (keyed) or `trust` (SearXNG); `url` must parse as an
http(s) URL with no userinfo, query string or credential-looking part; keyed URLs must be https; `trust: "allow"`
is accepted only for a loopback SearXNG host; `apiKeyEnv` must be an environment variable *name*; selecting a
backend whose section is missing is an error (no silent substitute). The SearXNG host the operator names is allowed
on a private address for **search only**; it does not open `web_fetch` to that host.

`allowPrivateHosts` is an explicit operator opt-in (intranet docs, local test servers); the metadata floor and
link-local range are never allowed. No automatic fallback between search backends (a query silently going to another
third party is a leak).

## Invariant I18
Web access never connects to a non-public address (unless the operator listed the host in `allowPrivateHosts`, and
never to the metadata floor), never runs unasked (except the operator-trusted loopback-SearXNG search), never sends
a credential to any host but its configured one, runs its parsers and TLS stack with no filesystem access, and
returns only bounded, labelled, untrusted data.

## Events
`web.fetched {host, status, bytes, redirects}`, `web.searched {backend, results}`, `web.unavailable {reason}`.
`web.searched` also carries `cached`. Never the query text beyond what the approval already showed, never keys.

## Tests and mutants
URL parser and IP classification tables (incl. IPv4-mapped IPv6, NAT64, 6to4, CGNAT, non-canonical IP forms), the
metadata floor, secret detection, denylist globs, one resolution per hop (a resolver hook "rebinds" to a private
address), redirect re-vetting, caps, content-type refusal, HTML corpus incl. hostile inputs, TLS (untrusted cert,
wrong hostname, trusted `caFile`), the policy layers, the helper protocol, the sandbox confinement of the helper.
Search: request building for each backend (URL, headers, body, limit clamp), answer parsing and cleaning (hostile
markup, forged labels, `javascript:`/`ftp:` URLs, oversize fields), real sockets against fake SearXNG/Brave/Tavily
(http and https), key handling (rejected key never echoed, keyed http refused before connecting, redirect not
followed, wrong certificate name ⇒ nothing sent, no fallback), configuration strictness, the policy exemption table
(including a forged capability flag), and the helper end to end. **Brave and Tavily are verified against local fakes
only** (no accounts were available); SearXNG is also verified against a real instance (see the certification record).

**Mutants (search):** keyed backend over http; Tavily not treated as keyed; redirects followed; fallback to another
backend; key echoed in an error; limit not clamped; non-http result URLs kept; result markup kept; exemption widened
(any host, any backend, without `trust`, capability flag alone, applied to `web_fetch`); `loopbackHost` accepting
10/8; credential-shaped query asked instead of denied; credential detection removed; config accepting `trust: allow`
for a non-loopback host, `trust` on keyed backends or an http keyed URL; a missing backend section silently replaced
by another; search label not defanged; memo ignoring the limit; key looked up for SearXNG; capability always
claiming the exemption; backend-less search registered; key value unchecked.
Equivalent (documented, not killable): the harness-side query check and key scrubbing are second layers behind the
same checks in the helper.

**Mutants (fetch):** skip IP vetting; connect via re-resolution; redirects not re-vetted; https→http allowed; no body cap;
no deadline; allowPrivate lifting the metadata floor; userinfo/secret parameters allowed; `web.url` as ASK;
`web.ask` missing; exemption beyond loopback; `CVerifyNone`; hostname check skipped; markers not stripped; helper
run without the sandbox.
