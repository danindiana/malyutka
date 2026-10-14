# Web access extras

**Priority:** P2 · **Size:** M · **Depends on:** SPEC-011

## What
Things deliberately left out of the first web release:
- **Disk cache** for fetched pages (today only an in-run memo exists). Needs a place that is not the workspace, a
  size cap and an expiry, and must keep the "untrusted data" label with the cached copy.
- **PDF and office text extraction.** `web_fetch` refuses `application/pdf` with a clear message. An extractor is
  more untrusted-format parsing, so it belongs inside the helper sandbox, not in the harness.
- **More backends:** Exa, Firecrawl, DuckDuckGo-style scrapers. Each must follow the rules in SPEC-011: explicit
  selection, no fallback, https plus key from a named variable, no redirects.
- **HTTP(S) proxy support** for hosts that reach the internet only through one. The proxy must be vetted like any
  other address (no silent route to a private proxy that then reaches private targets) and TLS must still verify
  the origin, so this needs CONNECT tunnelling in `httpfetch.nim`.
- **JavaScript rendering** is a non-goal (see NON-GOALS).

## Invariant and design notes
Everything stays under I18: nothing here may weaken vetting, asking or the no-filesystem helper sandbox.
