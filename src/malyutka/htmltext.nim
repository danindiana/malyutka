## HTML -> text/markdown for the web helper (SPEC-011). A tolerant single-pass scanner, NOT an HTML5
## parser: it never builds a tree, never recurses, and does linear work on any input (an unterminated
## tag scan is remembered so repeated `<a "` junk cannot make it quadratic). The page text it returns is
## untrusted data and is labelled that way by the caller.

import std/[strutils]

const
  MaxTagScan = 2048
  MaxLinks = 2000
  SkipElements = ["script", "style", "template", "noscript", "iframe", "object", "embed", "svg", "math", "canvas", "select"]

type HtmlText* = object
  title*: string
  text*: string
  truncated*: bool

proc utf8(cp: int): string =
  if cp < 0 or cp > 0x10FFFF or (cp in 0xD800 .. 0xDFFF): return "\xEF\xBF\xBD"
  if cp < 0x80: return $chr(cp)
  if cp < 0x800: return $chr(0xC0 or (cp shr 6)) & $chr(0x80 or (cp and 0x3F))
  if cp < 0x10000:
    return $chr(0xE0 or (cp shr 12)) & $chr(0x80 or ((cp shr 6) and 0x3F)) & $chr(0x80 or (cp and 0x3F))
  $chr(0xF0 or (cp shr 18)) & $chr(0x80 or ((cp shr 12) and 0x3F)) & $chr(0x80 or ((cp shr 6) and 0x3F)) & $chr(0x80 or (cp and 0x3F))

proc namedEntity(name: string): string =
  case name
  of "amp": "&"
  of "lt": "<"
  of "gt": ">"
  of "quot": "\""
  of "apos": "'"
  of "nbsp": " "
  of "ndash": "\xE2\x80\x93"
  of "mdash": "\xE2\x80\x94"
  of "hellip": "\xE2\x80\xA6"
  of "copy": "\xC2\xA9"
  of "reg": "\xC2\xAE"
  of "trade": "\xE2\x84\xA2"
  of "laquo": "\xC2\xAB"
  of "raquo": "\xC2\xBB"
  of "lsquo": "\xE2\x80\x98"
  of "rsquo": "\xE2\x80\x99"
  of "ldquo": "\xE2\x80\x9C"
  of "rdquo": "\xE2\x80\x9D"
  of "bull": "\xE2\x80\xA2"
  of "middot": "\xC2\xB7"
  of "euro": "\xE2\x82\xAC"
  of "pound": "\xC2\xA3"
  of "yen": "\xC2\xA5"
  of "cent": "\xC2\xA2"
  of "deg": "\xC2\xB0"
  of "times": "\xC3\x97"
  of "divide": "\xC3\xB7"
  else: ""

proc decodeEntities*(s: string): string =
  if '&' notin s: return s
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let semi = s.find(';', i + 1)
      if semi > i + 1 and semi - i <= 10:
        let name = s[i + 1 ..< semi]
        var rep = ""
        if name[0] == '#':
          try:
            let cp = if name.len > 1 and name[1] in {'x', 'X'}: parseHexInt(name[2 .. ^1]) else: parseInt(name[1 .. ^1])
            rep = if cp == 0: "\xEF\xBF\xBD" else: utf8(cp)
          except ValueError: discard
        else:
          rep = namedEntity(name)
        if rep.len > 0:
          result.add rep
          i = semi + 1
          continue
    result.add s[i]
    inc i

proc isTagStart(c: char): bool = c in {'a'..'z', 'A'..'Z'}

proc htmlToText*(html: string; maxOut = 400_000): HtmlText =
  var o = newStringOfCap(min(html.len, maxOut) + 16)
  var inPre = false
  var openHref = ""           # anchor currently open ("" = none)
  var anchorOpen = false
  var links = 0
  var failUntil = -1          # a tag scan starting before this index is known to fail
  var i = 0
  let n = html.len
  let low = html.toLowerAscii  # one pass; lets closing-tag searches ignore case

  proc full(): bool = o.len >= maxOut
  proc newline(count: int) =
    if o.len == 0: return
    var have = 0
    var j = o.len - 1
    while j >= 0 and o[j] == '\n' and have < 3:
      inc have
      dec j
    for _ in have ..< count: o.add '\n'
  proc addText(t: string) =
    if t.len == 0: return
    if inPre:
      o.add t
      return
    var pendingSpace = false
    for c in t:
      if c in {' ', '\t', '\n', '\r', '\f'}:
        pendingSpace = true
      elif c < ' ' or c == '\x7f':
        discard
      else:
        if pendingSpace and o.len > 0 and o[^1] notin {'\n', ' '}: o.add ' '
        pendingSpace = false
        o.add c
    if pendingSpace and o.len > 0 and o[^1] notin {'\n', ' '}: o.add ' '
  proc closeAnchor() =
    if anchorOpen:
      if openHref.len > 0: o.add "](" & openHref & ")"
      anchorOpen = false
      openHref = ""

  proc attr(tagBody, name: string): string =
    ## Value of attribute `name` in the text after the tag name; quotes optional.
    let lb = tagBody.toLowerAscii
    var p = 0
    while true:
      let k = lb.find(name, p)
      if k < 0: return ""
      let before = if k == 0: ' ' else: lb[k - 1]
      var j = k + name.len
      while j < lb.len and lb[j] == ' ': inc j
      if before in {' ', '\t', '\n', '/', '"', '\''} and j < lb.len and lb[j] == '=':
        inc j
        while j < tagBody.len and tagBody[j] == ' ': inc j
        if j >= tagBody.len: return ""
        if tagBody[j] in {'"', '\''}:
          let q = tagBody[j]
          let e = tagBody.find(q, j + 1)
          return decodeEntities(tagBody[j + 1 ..< (if e < 0: tagBody.len else: e)])
        var e = j
        while e < tagBody.len and tagBody[e] notin {' ', '\t', '\n', '>'}: inc e
        return decodeEntities(tagBody[j ..< e])
      p = k + 1

  while i < n and not full():
    let c = html[i]
    if c != '<':
      let e = html.find('<', i)
      let stop = if e < 0: n else: e
      # in slices, so one enormous text node cannot overshoot the output cap
      while i < stop and not full():
        let sliceEnd = min(stop, i + 65536)
        addText(decodeEntities(html[i ..< sliceEnd]))
        i = sliceEnd
      if full(): i = min(i, n)
      continue
    if i + 1 >= n:
      addText("<")
      inc i
      continue
    if html.continuesWith("<!--", i):
      let e = html.find("-->", i + 4)
      i = if e < 0: n else: e + 3
      continue
    let nx = html[i + 1]
    if nx == '!' or nx == '?':
      let e = html.find('>', i + 2)
      i = if e < 0: n else: e + 1
      continue
    let closing = nx == '/'
    let nameStart = if closing: i + 2 else: i + 1
    if nameStart >= n or not isTagStart(html[nameStart]) or i < failUntil:
      addText("<")
      inc i
      continue
    # find the end of the tag (quote-aware, bounded; failures are remembered)
    var j = nameStart
    var quote = '\0'
    var endPos = -1
    let limit = min(n, i + MaxTagScan)
    while j < limit:
      let ch = html[j]
      if quote != '\0':
        if ch == quote: quote = '\0'
      elif ch == '"' or ch == '\'': quote = ch
      elif ch == '>':
        endPos = j
        break
      inc j
    if endPos < 0:
      # unterminated quote or no '>' in range: fall back to the first '>' ignoring quotes, else give up
      let g = html.find('>', i + 1)
      if g < 0 or g >= limit:
        failUntil = limit
        addText("<")
        inc i
        continue
      endPos = g
    var nameEnd = nameStart
    while nameEnd < endPos and html[nameEnd] notin {' ', '\t', '\n', '\r', '/', '>'}: inc nameEnd
    let name = low[nameStart ..< nameEnd]
    let body = html[nameEnd ..< endPos]
    i = endPos + 1

    if name in SkipElements and not closing:
      let e = low.find("</" & name, i)
      if e < 0: i = n
      else:
        let g = html.find('>', e)
        i = if g < 0: n else: g + 1
      continue
    if name == "head" and not closing:
      let e = low.find("</head", i)
      if e >= 0:
        let t = low.find("<title", i)
        if t >= 0 and t < e:
          let ts = html.find('>', t)
          let te = low.find("</title", t)
          if ts >= 0 and te > ts and result.title.len == 0:
            result.title = decodeEntities(html[ts + 1 ..< te]).strip.splitWhitespace.join(" ")
        let g = html.find('>', e)
        i = if g < 0: n else: g + 1
        continue
    if name == "title":
      if not closing:
        let e = low.find("</title", i)
        if e > 0:
          if result.title.len == 0:
            result.title = decodeEntities(html[i ..< e]).strip.splitWhitespace.join(" ")
          let g = html.find('>', e)
          i = if g < 0: n else: g + 1
      continue

    case name
    of "br":
      if not closing: o.add '\n'
    of "hr":
      if not closing:
        newline(2)
        o.add "---"
        newline(2)
    of "p", "div", "section", "article", "main", "header", "footer", "aside", "nav", "form", "figure", "figcaption",
       "address", "details", "summary", "fieldset", "dl", "dt", "dd", "table", "thead", "tbody", "tfoot", "tr":
      newline(if name in ["p", "table"]: 2 else: 1)
    of "ul", "ol":
      newline(1)
    of "li":
      if not closing:
        newline(1)
        o.add "- "
    of "td", "th":
      if not closing and o.len > 0 and o[^1] notin {'\n', ' '}: o.add " | "
    of "h1", "h2", "h3", "h4", "h5", "h6":
      newline(2)
      if not closing:
        o.add repeat('#', ord(name[1]) - ord('0')) & " "
    of "blockquote":
      newline(1)
      if not closing: o.add "> "
    of "pre":
      if not closing:
        newline(2)
        inPre = true
        o.add "```\n"
      else:
        inPre = false
        if o.len > 0 and o[^1] != '\n': o.add '\n'
        o.add "```"
        newline(2)
    of "code":
      if not inPre: o.add '`'
    of "a":
      if closing: closeAnchor()
      else:
        closeAnchor()
        var href = attr(body, "href").strip
        let h = href.toLowerAscii
        if href.len == 0 or h.startsWith("javascript:") or h.startsWith("data:") or h.startsWith("vbscript:") or
           h.startsWith("#") or links >= MaxLinks:
          href = ""
        else:
          inc links
        if href.len > 0:
          o.add "["
          openHref = href
          anchorOpen = true
    of "img":
      if not closing:
        let alt = attr(body, "alt").strip.splitWhitespace.join(" ")
        if alt.len > 0: o.add "[image: " & (if alt.len > 100: alt[0 ..< 100] else: alt) & "]"
    else:
      discard

  closeAnchor()
  result.truncated = o.len >= maxOut and i < n
  if o.len > maxOut:
    var cut = maxOut
    while cut > 0 and (ord(o[cut]) and 0xC0) == 0x80: dec cut     # never cut inside a UTF-8 sequence
    o.setLen(cut)
    result.truncated = true
  # tidy: trailing spaces per line, at most one blank line, trimmed ends
  var cleaned = newStringOfCap(o.len)
  for line in o.splitLines:
    let t = line.strip(leading = false)
    if t.len == 0 and cleaned.endsWith("\n\n"): continue
    if t.len == 0 and cleaned.len == 0: continue
    cleaned.add t & "\n"
  result.text = cleaned.strip(chars = {'\n', ' '})
