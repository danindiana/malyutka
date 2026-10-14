## Context compaction (SPEC-006, invariant 10) and ranked session search (SPEC-007).
import std/[asyncdispatch, json, os, posix, sequtils, strutils, tables, times, unittest]
import malyutka/[types, provider, core, events, compact, session]

let root = getTempDir() / ("malyutka-compact-" & $getCurrentProcessId())
createDir(root)

proc m(role: Role; content: string): Message =
  Message(role: role, content: content, createdAt: now())

proc step(i: int; outBytes = 40): seq[Message] =
  ## One agent step: assistant tool call + its reply.
  var a = m(rAssistant, "")
  a.toolCalls = @[ToolCall(id: "c" & $i, name: "shell", args: %*{"command": "echo " & $i})]
  var t = m(rTool, 'x'.repeat(outBytes))
  t.toolCallId = "c" & $i
  t.name = "shell"
  @[a, t]

proc transcript(turns, stepsPerTurn: int; outBytes = 40): seq[Message] =
  result = @[m(rSystem, "system prompt")]
  var n = 0
  for t in 1 .. turns:
    result.add m(rUser, "task " & $t)
    for s in 1 .. stepsPerTurn:
      inc n
      result.add step(n, outBytes)
    result.add m(rAssistant, "answer " & $t)

type Spy = ref object of Provider
  script: seq[ModelAction]
  calls: int
  seen: seq[seq[Message]]
  failFirst: bool

method next(p: Spy; messages: seq[Message]; tools: JsonNode): Future[ModelAction] {.async.} =
  inc p.calls
  p.seen.add messages
  if p.failFirst and p.calls == 1: raise newException(IOError, "summariser down")
  let i = (if p.failFirst: p.calls - 2 else: p.calls - 1)
  if i < p.script.len: return p.script[i]
  return ModelAction(kind: makFinal, text: "ok")

proc fin(t: string): ModelAction = ModelAction(kind: makFinal, text: t)

proc collect(kinds: var seq[string]; ps: var seq[JsonNode]): EventSink =
  let kp = addr kinds
  let pp = addr ps
  result = proc(k: string; p: JsonNode) = (kp[].add k; pp[].add p)

suite "SPEC-006 planning":
  test "estimates grow with content and tool calls":
    check estimateTokens(m(rUser, "hi")) < estimateTokens(m(rUser, 'x'.repeat(400)))
    check estimateTokens(step(1)[0]) > estimateTokens(m(rAssistant, ""))

  test "cut points never split a call from its reply (fuzzed shapes)":
    for turns in 1 .. 6:
      for steps in 0 .. 5:
        for sizeA in [10, 400]:
          let ms = transcript(turns, steps, sizeA)
          for c in cutPoints(ms):
            check validateTranscript(ms[0 ..< c]) == ""
            check validateTranscript(@[ms[0]] & ms[c .. ^1]) == ""
            check ms[c].role == rUser or (ms[c].role == rAssistant and ms[c - 1].role == rTool)
    # a cut between a call and its reply would leave the reply orphaned: never offered
    let ms = transcript(1, 3)
    for c in cutPoints(ms): check ms[c].role != rTool

  test "no plan below threshold or when disabled; one with force":
    let ms = transcript(3, 2)
    check not plan(ms, 0).ok
    check not plan(ms, 100000).ok
    check plan(ms, 100000).why == "below threshold"
    check plan(ms, 100000, force = true).ok

  test "plan picks the earliest cut whose kept suffix fits the target":
    let ms = transcript(8, 3, 800)                       # large
    let window = estimateTokens(ms) div 2                # over the 75% mark
    let pl = plan(ms, window)
    check pl.ok
    let kept = ms[pl.p.cut .. ^1]
    check estimateTokens(kept) <= int(LowWater * float(window))
    check pl.p.dropped.len == pl.p.cut - 1
    check pl.p.start == 1

  test "no safe cut point in a transcript with a single exchange":
    check plan(@[m(rSystem, "s"), m(rUser, "u" & 'x'.repeat(4000))], 100).why == "no safe cut point"

  test "apply keeps the system prompt, marks the summary untrusted, stays valid and shrinks":
    let ms = transcript(6, 3, 800)
    let pl = plan(ms, estimateTokens(ms) div 2)
    let res = apply(ms, pl.p, "the user wanted X; file a.txt created")
    check res[0].role == rSystem and res[0].content == "system prompt"
    check res[1].role == rUser and res[1].content.startsWith(SummaryMarker)
    check "untrusted" in res[1].content.toLowerAscii
    check validateTranscript(res) == ""
    check estimateTokens(res) < estimateTokens(ms)
    check res[2 .. ^1] == ms[pl.p.cut .. ^1]

  test "render caps the summariser input and truncates tool output":
    let ms = transcript(40, 4, 5000)
    let r = renderForSummary(ms[1 .. ^1])
    check r.len <= MaxRenderChars + 200
    check "omitted from this summary input" in r
    check "more chars]" in renderForSummary(step(1, 9000))

suite "I10 compaction in the loop":
  proc cfgW(window: int; force = false): AgentConfig =
    result = baseConfig()
    result.contextWindow = window
    result.compressNow = force

  proc bigHistory(): seq[Message] = transcript(6, 3, 1500)

  test "I10 compacts over the threshold: summary swapped in, dropped messages archived first, event emitted":
    let hist = bigHistory()
    let spy = Spy(name: "spy", script: @[fin("SUMMARY: user ran 6 tasks"), fin("final answer")])
    var archived: seq[Message]
    var order: seq[string]
    let ap = addr archived
    let op = addr order
    let archive: ArchiveProc = proc(d: seq[Message]) = (ap[] = d; op[].add "archive")
    var kinds: seq[string]; var ps: seq[JsonNode]
    let base = collect(kinds, ps)
    let kp = addr order
    let sink: EventSink = proc(k: string; p: JsonNode) =
      if k == "context.compacted": kp[].add "event"
      base(k, p)
    let r = waitFor runAgent(spy, "next task", cfgW(estimateTokens(hist) div 2), history = hist,
                             sink = sink, archive = archive)
    check "context.compacted" in kinds
    check order == @["archive", "event"]                       # archived BEFORE the event / swap
    check spy.calls == 2                                       # summariser + the real call
    check spy.seen[0][0].content.startsWith("You compress")    # summariser prompt
    check spy.seen[1][1].content.startsWith(SummaryMarker)
    check archived.len > 0 and archived[0].content == hist[1].content
    check r.answer == "final answer"
    var comp: JsonNode
    for i, k in kinds:
      if k == "context.compacted": comp = ps[i]
    check comp["tokensAfter"].getInt < comp["tokensBefore"].getInt
    check comp["dropped"].getInt == archived.len
    check validateTranscript(r.messages) == ""

  test "below the threshold nothing happens and the summariser is never called":
    let hist = transcript(2, 1, 20)
    let spy = Spy(name: "spy", script: @[fin("only call")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    let r = waitFor runAgent(spy, "t", cfgW(100000), history = hist, sink = collect(kinds, ps))
    check spy.calls == 1 and "context.compacted" notin kinds
    check r.answer == "only call"

  test "disabled with contextWindow 0":
    let hist = bigHistory()
    let spy = Spy(name: "spy", script: @[fin("only call")])
    discard waitFor runAgent(spy, "t", cfgW(0), history = hist)
    check spy.calls == 1

  test "I10 summariser failure: reported, run continues uncompacted":
    let hist = bigHistory()
    let spy = Spy(name: "spy", failFirst: true, script: @[fin("went on")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    var archived = 0
    let ap = addr archived
    let archive: ArchiveProc = proc(d: seq[Message]) = inc ap[]
    let r = waitFor runAgent(spy, "t", cfgW(estimateTokens(hist) * 4 div 3), history = hist,
                             sink = collect(kinds, ps), archive = archive)
    check "context.compaction_failed" in kinds and "context.compacted" notin kinds
    check archived == 0
    check r.answer == "went on"
    check r.messages.len == hist.len + 2                       # untouched + task + answer

  test "I10 an archive that cannot be written blocks compaction (loss must be observable)":
    let hist = bigHistory()
    let spy = Spy(name: "spy", script: @[fin("SUMMARY"), fin("went on")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    let archive: ArchiveProc = proc(d: seq[Message]) = raise newException(IOError, "disk full")
    let r = waitFor runAgent(spy, "t", cfgW(estimateTokens(hist) * 4 div 3), history = hist,
                             sink = collect(kinds, ps), archive = archive)
    check "context.compacted" notin kinds
    var reason = ""
    for i, k in kinds:
      if k == "context.compaction_failed": reason = ps[i]["reason"].getStr
    check reason.startsWith("archive:")
    check r.messages.len == hist.len + 2

  test "no archive attached also blocks compaction":
    let hist = bigHistory()
    let spy = Spy(name: "spy", script: @[fin("SUMMARY"), fin("x")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    discard waitFor runAgent(spy, "t", cfgW(estimateTokens(hist) * 4 div 3), history = hist, sink = collect(kinds, ps))
    check "context.compacted" notin kinds

  test "I10 still over 100% after compaction fails: halt, never silent truncation":
    let spy = Spy(name: "spy", script: @[fin("never reached")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    # one huge task: [system, user] has no cut point, so nothing can be compacted
    let r = waitFor runAgent(spy, 'x'.repeat(8000), cfgW(500), sink = collect(kinds, ps))
    check r.halt == hrContext
    check spy.calls == 0
    check "agent.halt" in kinds
    check r.answer.startsWith("Halted:")

  test "forced compression (--compress) acts below the threshold; a tiny history reports why not":
    let hist = transcript(4, 1, 100)
    let spy = Spy(name: "spy", script: @[fin("SUMMARY"), fin("done")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    let archive: ArchiveProc = proc(d: seq[Message]) = discard
    discard waitFor runAgent(spy, "t", cfgW(100000, force = true), history = hist, sink = collect(kinds, ps), archive = archive)
    check "context.compacted" in kinds
    var kinds2: seq[string]; var ps2: seq[JsonNode]
    let spy2 = Spy(name: "spy", script: @[fin("x")])
    discard waitFor runAgent(spy2, "t", cfgW(100000, force = true), sink = collect(kinds2, ps2), archive = archive)
    check "context.compaction_failed" in kinds2

  test "a summary that would not shrink the transcript is rejected (no progress)":
    let hist = transcript(3, 1, 10)
    let spy = Spy(name: "spy", script: @[fin('y'.repeat(3000)), fin("done")])
    var kinds: seq[string]; var ps: seq[JsonNode]
    let archive: ArchiveProc = proc(d: seq[Message]) = discard
    let r = waitFor runAgent(spy, "t", cfgW(100000, force = true), history = hist, sink = collect(kinds, ps), archive = archive)
    var reason = ""
    for i, k in kinds:
      if k == "context.compaction_failed": reason = ps[i]["reason"].getStr
    check reason == "no progress" and "context.compacted" notin kinds
    check r.messages.len == hist.len + 2

  test "monotone shrink: a compacted transcript does not immediately compact again":
    let hist = bigHistory()
    let window = estimateTokens(hist) div 2
    let spy = Spy(name: "spy", script: @[fin("SUMMARY"), fin("a1"), fin("a2")])
    var n = 0
    let np = addr n
    let archive: ArchiveProc = proc(d: seq[Message]) = inc np[]
    let r1 = waitFor runAgent(spy, "t1", cfgW(window), history = hist, archive = archive)
    check n == 1
    let spy2 = Spy(name: "spy", script: @[fin("a2")])
    discard waitFor runAgent(spy2, "t2", cfgW(window), history = r1.messages, archive = archive)
    check n == 1 and spy2.calls == 1

suite "SPEC-006 archive file":
  test "appendArchive writes 0600 JSONL, appends, refuses symlinks, and sessions ignore it":
    let dir = root / "arch"
    removeDir(dir); createDir(dir)
    let p = dir / "9M14-aa.archive.jsonl"
    appendArchive(p, "9M14-aa", @[m(rUser, "one"), m(rAssistant, "two")])
    appendArchive(p, "9M14-aa", @[m(rUser, "three")])
    var st: Stat
    doAssert stat(cstring(p), st) == 0
    check (int(st.st_mode) and 0o777) == 0o600
    var n = 0
    for l in lines(p):
      if l.strip.len > 0:
        inc n
        check parseJson(l)["run"].getStr == "9M14-aa"
    check n == 3
    check listSessions(dir).len == 0                            # not mistaken for a session
    createSymlink(p, dir / "link.archive.jsonl")
    expect SessionError: appendArchive(dir / "link.archive.jsonl", "9M14-aa", @[m(rUser, "x")])

suite "SPEC-007 ranked session search":
  proc mk(dir, id, text: string; age = 0) =
    saveSession(dir / (id & ".json"), id, @[m(rSystem, "system secret"), m(rUser, text)],
                SessionMeta(title: id))
    let t = getTime() - initDuration(seconds = age)
    setLastModificationTime(dir / (id & ".json"), t)

  proc fresh(name: string): string =
    result = root / name
    removeDir(result)
    createDir(result)

  test "tokens: lowercase words of length >= 2":
    let t = tokens("Hello, hello WORLD a x_1")
    check t["hello"] == 2 and t["world"] == 1 and t["x_1"] == 1
    check "a" notin t

  test "ranked by score, ties to the newer session, limit applies":
    let d = fresh("rank")
    mk(d, "s-low", "needle once", age = 50)
    mk(d, "s-high", "needle needle needle needle", age = 40)
    mk(d, "s-tie-old", "needle needle", age = 30)
    mk(d, "s-tie-new", "needle needle", age = 5)
    mk(d, "s-none", "nothing relevant")
    let hits = rankedSearch(d, "needle")
    check hits.mapIt(it.runId) == @["s-high", "s-tie-new", "s-tie-old", "s-low"]
    check hits[0].score == 4 and "needle" in hits[0].snippet and hits[0].role == "user"
    check rankedSearch(d, "needle", limit = 2).len == 2

  test "multi-word queries add scores; short or empty queries match nothing; system text is invisible":
    let d = fresh("multi")
    mk(d, "a", "alpha beta")
    mk(d, "b", "alpha")
    check rankedSearch(d, "alpha beta").mapIt(it.runId) == @["a", "b"]
    check rankedSearch(d, "").len == 0
    check rankedSearch(d, "a").len == 0
    check rankedSearch(d, "secret").len == 0

  test "per-word counts are capped so one spammy session cannot dominate forever":
    let d = fresh("cap")
    mk(d, "spam", "needle ".repeat(500))
    mk(d, "ok", "needle needle needle")
    let hits = rankedSearch(d, "needle")
    check hits[0].runId == "spam" and hits[0].score == 20

  test "index is 0600, reused, and an edited session is re-read (stale entry ignored)":
    let d = fresh("idx")
    mk(d, "s1", "apple")
    check rankedSearch(d, "apple").len == 1
    let ip = d / ".index.json"
    var st: Stat
    doAssert stat(cstring(ip), st) == 0
    check (int(st.st_mode) and 0o777) == 0o600
    mk(d, "s1", "banana banana banana")        # same run id, different content and size
    check rankedSearch(d, "apple").len == 0
    check rankedSearch(d, "banana")[0].score == 3

  test "garbled or wrongly shaped index is ignored and rebuilt; entries for deleted sessions vanish":
    let d = fresh("poison")
    mk(d, "s1", "apple"); mk(d, "s2", "apple apple")
    check rankedSearch(d, "apple").len == 2
    let ip = d / ".index.json"
    for bad in ["{{{", "[]", """{"v":2,"sessions":{}}""", """{"v":1,"sessions":{"s1":{"mtime":"x","size":1,"words":{}}}}""",
                """{"v":1,"sessions":{"s1":{"mtime":1,"size":1,"words":{"apple":"lots"}}}}"""]:
      writeFile(ip, bad)
      check rankedSearch(d, "apple").mapIt(it.runId) == @["s2", "s1"]
    # an entry with a stale stamp but inflated counts must not be believed
    let ownStamp = parseJson(readFile(ip))
    check ownStamp["v"].getInt == 1
    var forged = ownStamp
    forged["sessions"]["s1"]["words"]["apple"] = %9999
    forged["sessions"]["s1"]["mtime"] = %1
    writeFile(ip, $forged)
    check rankedSearch(d, "apple")[1].score == 1
    removeFile(d / "s2.json")
    check rankedSearch(d, "apple").len == 1
    check not parseJson(readFile(ip))["sessions"].hasKey("s2")

  test "a symlinked index is never read or overwritten; undecodable sessions and archives are skipped":
    let d = fresh("link")
    mk(d, "s1", "apple")
    check rankedSearch(d, "apple")[0].score == 1             # builds a valid index
    let real = root / "link-real-index.json"
    removeFile(real)
    moveFile(d / ".index.json", real)
    var forged = parseJson(readFile(real))
    forged["sessions"]["s1"]["words"]["apple"] = %999        # matching stamp, inflated count
    writeFile(real, $forged)
    createSymlink(real, d / ".index.json")
    check rankedSearch(d, "apple")[0].score == 1             # the symlinked index is not believed
    check symlinkExists(d / ".index.json") and readFile(real) == $forged
    writeFile(d / "broken.json", "{{{")
    appendArchive(d / "s1.archive.jsonl", "s1", @[m(rUser, "apple apple apple")])
    check rankedSearch(d, "apple").mapIt(it.runId) == @["s1"]
