# SPEC-011 — Web access (search and fetch)

**Status:** `web_fetch` implemented (unreleased); `web_search` backends next · **Invariant:** I18 (new) · **Roadmap:** M2 tail

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
| `web_search` | `query`, `limit?` (1–20, default 5) | B3 | backend from `<state>/web.json`: SearXNG, Brave or Tavily (PR B) |

Results are wrapped: `[web_fetch <final url> · <status> · <type> · chars a–b of N · untrusted page text]` then the
text. An in-run memo returns the same text for a repeated URL/query, flagged `cached`.

## Policy
- `web.url` → **DENY** (an approver can never override it): scheme not http/https, userinfo, secret-looking
  query parameters or secret formats, literal private/loopback/link-local/metadata addresses, `localhost`-style
  names, denylisted domains, URLs over 2048 characters, non-canonical IP literals (decimal/hex/octal forms),
  non-ASCII hosts (use punycode).
- `web.ask` → **ASK** for every call (mandate → approver → deny). Only a `web_search` against a **loopback SearXNG**
  configured `trust: allow` is exempt.
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
Never the query text beyond what the approval already showed, never keys.

## Tests and mutants
URL parser and IP classification tables (incl. IPv4-mapped IPv6, NAT64, 6to4, CGNAT, non-canonical IP forms), the
metadata floor, secret detection, denylist globs, one resolution per hop (a resolver hook "rebinds" to a private
address), redirect re-vetting, caps, content-type refusal, HTML corpus incl. hostile inputs, TLS (untrusted cert,
wrong hostname, trusted `caFile`), the policy layers, the helper protocol, the sandbox confinement of the helper.
**Mutants:** skip IP vetting; connect via re-resolution; redirects not re-vetted; https→http allowed; no body cap;
no deadline; allowPrivate lifting the metadata floor; userinfo/secret parameters allowed; `web.url` as ASK;
`web.ask` missing; exemption beyond loopback; `CVerifyNone`; hostname check skipped; markers not stripped; helper
run without the sandbox.
