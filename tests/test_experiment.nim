## SPEC-012 experiment layer: randomizer (E1), eligibility and symmetric
## lockout (E2), write-ahead decisions (E3), strict replay of the log (E4).
## No model, provider or agent loop is involved anywhere in this file.

import std/[json, options, os, strutils, unittest]
import malyutka/journal
import malyutka/experiment/[randomizer, eligibility, event_recorder, trial]

let scratch = getTempDir() / ("malyutka-exp-test-" & $getCurrentProcessId())
removeDir(scratch)
createDir(scratch)
var logNo = 0

proc freshLog(): string =
  inc logNo
  scratch / ("log" & $logNo) / "experiment.jsonl"

const Seed = 0x0123456789abcdef'u64
let design = Design(q: 0.5, k0: 2, windowLen: 3, intervention: "REDIRECT-v1")
let alwaysAlive: Liveness = proc(w: string): WriterLiveness = lvAlive

proc records(path: string): seq[string] =
  for l in readFile(path).splitLines:
    if l.strip.len > 0: result.add l

proc reseal(r: JsonNode): string =
  ## Re-computes the CRC after an edit, so only replay can catch the forgery.
  var body = r.copy
  body.delete("crc")
  r["crc"] = %crc32($body)
  $r

proc rewrite(path: string; edit: proc(r: JsonNode): bool) =
  ## Applies `edit` to every record; re-seals the ones it changed.
  var outp = ""
  for l in records(path):
    let r = parseJson(l)
    outp.add "\n" & (if edit(r): reseal(r) else: l) & "\n"
  writeFile(path, outp)

proc scan(path: string): ExpScan = scanExperimentContent(readFile(path), alwaysAlive)

proc problemsMention(s: ExpScan; needle: string): bool =
  for p in s.problems:
    if needle in p: return true

proc standardEpisode(path, episode: string; seed = Seed; d = design): Trial =
  ## warm-up turns, then alternating decide / turn / actions, then finish.
  let rec = openRecorder(path)
  let t = startTrial(rec, episode, "bugsinpy:example-1", "example", seed, d,
                     %*{"model": "test-model", "harness": "0.9.0"})
  for step in 0 ..< 8:
    discard t.decide(%*{"step": step})
    t.turnCompleted(%*{"step": step})
    for a in 0 ..< 2: t.toolAction(%*{"tool": "read_file", "ok": true, "a": a})
  t.finish("answered")
  t

suite "E1 randomizer: assignment is a pure function of (seed, episode, k, q)":
  test "golden vectors pin the mixer (cross-checked against an independent Python implementation)":
    let want = ["d53525fb0eb88c5d", "4eb41fab7137a88a", "6d0cdfbdebea0a91", "6056668264dc6777", "05c3797b23686049"]
    for k in 0 ..< want.len:
      check seedHex(mix(Seed, "ep-A", k)) == want[k]
    check seedHex(mix(0'u64, "", 0)) == "2609bf7269e6ad79"
    check assign(Seed, "ep-A", 0, 0.5).arm == armContinue    # u = 0.8328...
    check assign(Seed, "ep-A", 1, 0.5).arm == armRedirect    # u = 0.3074...

  test "draws do not depend on order or on other draws":
    let late = assign(Seed, "ep-B", 7, 0.3)
    for k in 0 ..< 7: discard assign(Seed, "ep-B", k, 0.3)
    let again = assign(Seed, "ep-B", 7, 0.3)
    check late.x == again.x and late.arm == again.arm

  test "episode and seed both change the stream":
    check mix(Seed, "ep-A", 0) != mix(Seed, "ep-B", 0)
    check mix(Seed, "ep-A", 0) != mix(Seed + 1, "ep-A", 0)

  test "assigned probability is q for REDIRECT and 1-q for CONTINUE":
    for k in 0 ..< 50:
      let a = assign(Seed, "ep-p", k, 0.3)
      check a.p == (if a.arm == armRedirect: 0.3 else: 0.7)
      check (a.u < 0.3) == (a.arm == armRedirect)

  test "REDIRECT frequency matches q":
    var hits = 0
    const n = 20000
    for i in 0 ..< n:
      if assign(Seed, "ep-" & $(i div 100), i mod 100, 0.3).arm == armRedirect: inc hits
    check abs(hits / n - 0.3) < 0.015

  test "positivity: q outside (0, 1) is refused":
    for q in [0.0, 1.0, -0.1, 1.5, NaN]:
      expect RandomizerError: discard assign(Seed, "e", 0, q)
    expect RandomizerError: discard mix(Seed, "e", -1)

  test "seeds round-trip as 16 hex digits":
    for s in [0'u64, 1'u64, Seed, high(uint64)]:
      check parseSeed(seedHex(s)) == s
    check seedHex(high(uint64)) == "ffffffffffffffff"
    for bad in ["", "0123", "0123456789ABCDEF", "0123456789abcdeg", "0123456789abcdef0"]:
      expect RandomizerError: discard parseSeed(bad)

suite "E2 eligibility: warm-up and a symmetric outcome-window lockout":
  test "ineligible until k0 turns, then eligible":
    var e = initEligibility(EligibilityCfg(k0: 2, windowLen: 3))
    check e.check == inWarmup
    e.onTurnCompleted()
    check e.check == inWarmup
    e.onTurnCompleted()
    check e.check == inNone

  test "a window locks out every point until windowLen tool actions complete":
    var e = initEligibility(EligibilityCfg(k0: 0, windowLen: 3))
    check e.openWindow() == 0
    check e.check == inWindowOpen
    e.onTurnCompleted()                     # turns never close a window
    check e.check == inWindowOpen
    check e.onToolAction().isNone
    check e.onToolAction().isNone
    check e.check == inWindowOpen
    let c = e.onToolAction()
    check c.isSome and c.get.k == 0 and c.get.actions == 3 and c.get.reason == crLength
    check e.check == inNone
    check e.openWindow() == 1

  test "ending the episode censors an open window":
    var e = initEligibility(EligibilityCfg(k0: 0, windowLen: 5))
    discard e.openWindow()
    discard e.onToolAction()
    let c = e.endEpisode()
    check c.isSome and c.get.reason == crEpisodeEnd and c.get.actions == 1
    check e.check == inEnded
    expect EligibilityError: e.onTurnCompleted()
    expect EligibilityError: discard e.onToolAction()
    expect EligibilityError: discard e.endEpisode()

  test "openWindow at an ineligible point is a harness bug":
    var e = initEligibility(EligibilityCfg(k0: 1, windowLen: 1))
    expect EligibilityError: discard e.openWindow()

  test "invalid configurations are refused":
    expect EligibilityError: discard initEligibility(EligibilityCfg(k0: -1, windowLen: 1))
    expect EligibilityError: discard initEligibility(EligibilityCfg(k0: 0, windowLen: 0))

  test "lockout is identical after CONTINUE and after REDIRECT":
    # Find one episode whose first point draws CONTINUE and one that draws REDIRECT,
    # run the same script through both, and compare every decision's eligibility.
    var cont, redir = ""
    for i in 0 ..< 100:
      let id = "sym-" & $i
      let a = assign(Seed, id, 0, 0.5)
      if a.arm == armContinue and cont.len == 0: cont = id
      if a.arm == armRedirect and redir.len == 0: redir = id
    check cont.len > 0 and redir.len > 0
    proc trace(id: string): seq[string] =
      let rec = openRecorder(freshLog())
      defer: rec.close()
      let t = startTrial(rec, id, "task", "fam", Seed, Design(q: 0.5, k0: 1, windowLen: 2,
                         intervention: "REDIRECT-v1"))
      t.turnCompleted()
      for step in 0 ..< 6:
        let d = t.decide()
        result.add(if d.randomized: "point" & $d.k else: $d.reason)
        t.toolAction()
      t.finish("answered")
    let tc = trace(cont)
    check tc == trace(redir)
    check tc == @["point0", "window-open", "point1", "window-open", "point2", "window-open"]

suite "E3 write-ahead: nothing is delivered without a durable point record":
  test "a point record that is not durable yields no assignment and disables the trial":
    let path = freshLog()
    let rec = openRecorder(path)
    let t = startTrial(rec, "wa-1", "task", "fam", Seed, Design(q: 0.99, k0: 0, windowLen: 2,
                       intervention: "REDIRECT-v1"))
    rec.failAfter(1)                        # episode.start was record 1; the point record fails
    let d = t.decide()
    check not d.randomized
    check d.arm == armContinue
    check t.disabled
    check t.decide().arm == armContinue     # stays off for the rest of the episode
    t.finish("answered")                    # writes nothing to a broken log
    check records(path).len == 1
    rec.close()
    let s = scanExperiment(path)
    check s.health == jhOk
    check s.episodes[0].points.len == 0
    check s.episodes[0].status == esInterrupted   # never completed, owner gone

  test "the point record precedes the window and carries the pre-treatment history":
    let path = freshLog()
    let rec = openRecorder(path)
    let t = startTrial(rec, "wa-2", "task", "fam", Seed, Design(q: 0.5, k0: 1, windowLen: 1,
                       intervention: "REDIRECT-v1"))
    t.turnCompleted(%*{"n": 1})
    let (hT, hHead) = rec.history("wa-2")
    let d = t.decide(%*{"elapsed": 1})
    check d.randomized
    t.toolAction(%*{"tool": "shell"})
    t.finish("answered")
    rec.close()
    var kinds: seq[string]
    for l in records(path):
      let r = parseJson(l)
      kinds.add r["rec"].getStr
      if r["rec"].getStr == "point":
        check r["histT"].getInt == hT
        check r["histHead"].getStr == hHead
        check r["features"]["elapsed"].getInt == 1
    check kinds == @["episode.start", "obs", "point", "obs", "window.close", "episode.end"]

suite "E4 recording and strict replay":
  test "a complete episode replays clean and every assignment re-derives":
    let path = freshLog()
    let t = standardEpisode(path, "ep-ok")
    t.rec.close()
    let s = scanExperiment(path)
    check s.health == jhOk
    check s.problems.len == 0
    check s.episodes.len == 1
    let e = s.episodes[0]
    check e.status == esComplete
    check e.endReason == "answered"
    check e.turns == 8 and e.actions == 16
    check e.points.len > 0
    for p in e.points:
      check p.arm == assign(Seed, "ep-ok", p.k, design.q).arm
      check p.closed
    check e.design == design
    check e.conditions["model"].getStr == "test-model"

  test "a torn tail is reported, does not hide the prefix, and later writers recover":
    let path = freshLog()
    let t = standardEpisode(path, "ep-torn")
    t.rec.close()
    let f = open(path, fmAppend)
    f.write("\n{\"rec\":\"obs\",\"episode\":\"ep-")   # a write that never completed
    f.close()
    var s = scanExperiment(path)
    check s.health == jhTorn
    check s.episodes[0].status == esComplete
    standardEpisode(path, "ep-after").rec.close()     # next writer's leading newline terminates it
    s = scanExperiment(path)
    check s.health == jhTorn
    check s.problems.len == 0
    check s.episodes.len == 2 and s.episodes[1].status == esComplete

  test "a writer that died mid-episode is INTERRUPTED; a live one is RUNNING":
    let path = freshLog()
    let rec = openRecorder(path)
    let t = startTrial(rec, "ep-crash", "task", "fam", Seed, design)
    t.turnCompleted(); t.turnCompleted()
    check t.decide().randomized
    check scanExperiment(path).episodes[0].status == esRunning
    rec.close()                                        # liveness lock released, as on SIGKILL
    let s = scanExperiment(path)
    check s.health == jhOk
    check s.episodes[0].status == esInterrupted
    check not s.episodes[0].points[0].closed           # censored by the crash, visibly

  test "an evaluator may add outcomes under its own writer id":
    let path = freshLog()
    let t = standardEpisode(path, "ep-eval")
    t.rec.close()
    let ev = openRecorder(path, writer = "evaluator")
    ev.outcome("ep-eval", "patched_file_within_window", %true, k = 0)
    ev.outcome("ep-eval", "tests_pass", %false)
    ev.close()
    let s = scanExperiment(path)
    check s.health == jhOk
    check s.episodes[0].outcomes.len == 2

  test "the log refuses a directory that overlaps the workspace":
    let ws = scratch / "ws"
    createDir(ws / "state")
    expect ExperimentError: discard openRecorder(ws / "state" / "experiment.jsonl", workspace = ws)

  test "invalid designs are refused before anything is written":
    let rec = openRecorder(freshLog())
    defer: rec.close()
    for d in [Design(q: 0.0, k0: 1, windowLen: 1, intervention: "R"),
              Design(q: 1.0, k0: 1, windowLen: 1, intervention: "R"),
              Design(q: 0.5, k0: 1, windowLen: 0, intervention: "R"),
              Design(q: 0.5, k0: 1, windowLen: 1, intervention: " ")]:
      expect ExperimentError: rec.episodeStart("bad", "t", "f", Seed, d, nil)

suite "E4 forgeries that pass the CRC are caught by replay":
  proc forged(episode: string; edit: proc(r: JsonNode): bool): ExpScan =
    let path = freshLog()
    let t = standardEpisode(path, episode)
    t.rec.close()
    rewrite(path, edit)
    scan(path)

  test "a flipped arm does not re-derive from the seed":
    var done = false
    let s = forged("f-arm", proc(r: JsonNode): bool =
      if not done and r["rec"].getStr == "point" and r["eligible"].getBool:
        r["arm"] = %(if r["arm"].getStr == "REDIRECT": "CONTINUE" else: "REDIRECT")
        done = true
        return true)
    check s.health == jhCorrupt
    check s.problemsMention("does not re-derive")

  test "a changed seed invalidates every assignment":
    let s = forged("f-seed", proc(r: JsonNode): bool =
      if r["rec"].getStr == "episode.start":
        r["seed"] = %"00000000000000ff"
        return true)
    check s.health == jhCorrupt
    check s.problemsMention("does not re-derive")

  test "an edited observation breaks the history chain":
    var done = false
    let s = forged("f-obs", proc(r: JsonNode): bool =
      if not done and r["rec"].getStr == "obs":
        r["data"] = %*{"step": 99}
        done = true
        return true)
    check s.health == jhCorrupt
    check s.problemsMention("history chain mismatch")

  test "a point's history reference must be the observations before it":
    var done = false
    let s = forged("f-hist", proc(r: JsonNode): bool =
      if not done and r["rec"].getStr == "point" and r["eligible"].getBool:
        r["histHead"] = %GenesisHead
        done = true
        return true)
    check s.health == jhCorrupt
    check s.problemsMention("history reference")

  test "an edit replay cannot see (features) is caught by the CRC":
    let path = freshLog()
    let t = standardEpisode(path, "f-crc")
    t.rec.close()
    var outp = ""
    var done = false
    for l in records(path):
      if not done and "\"features\"" in l:
        outp.add "\n" & l.replace("\"step\":", "\"step\": 1") & "\n"   # not re-sealed
        done = true
      else: outp.add "\n" & l & "\n"
    check done
    writeFile(path, outp)
    let s = scan(path)
    check s.health == jhCorrupt
    check s.problemsMention("checksum mismatch")

  test "a point marked ineligible while replay finds it eligible (selective skipping)":
    var done = false
    let s = forged("f-skip", proc(r: JsonNode): bool =
      if not done and r["rec"].getStr == "point" and r["eligible"].getBool:
        for k in ["k", "arm", "q", "p", "u", "x", "intervention", "features"]:
          if r.hasKey(k): r.delete(k)
        r["eligible"] = %false
        r["reason"] = %"window-open"
        done = true
        return true)
    check s.health == jhCorrupt
    check s.problemsMention("replay finds it eligible")

  test "a point randomized inside an open window violates the lockout":
    let path = freshLog()
    let rec = openRecorder(path)
    rec.episodeStart("f-lock", "t", "f", Seed, Design(q: 0.5, k0: 0, windowLen: 3, intervention: "REDIRECT-v1"), nil)
    rec.pointAssigned("f-lock", assign(Seed, "f-lock", 0, 0.5), "REDIRECT-v1")
    discard rec.observe("f-lock", "action", nil)
    rec.pointAssigned("f-lock", assign(Seed, "f-lock", 1, 0.5), "REDIRECT-v1")   # window still open
    rec.close()
    let s = scan(path)
    check s.health == jhCorrupt
    check s.problemsMention("lockout violated")

  test "a window that replay closes must be closed in the log":
    let path = freshLog()
    let rec = openRecorder(path)
    rec.episodeStart("f-close", "t", "f", Seed, Design(q: 0.5, k0: 0, windowLen: 1, intervention: "REDIRECT-v1"), nil)
    rec.pointAssigned("f-close", assign(Seed, "f-close", 0, 0.5), "REDIRECT-v1")
    discard rec.observe("f-close", "action", nil)   # closes the window in replay...
    discard rec.observe("f-close", "action", nil)   # ...but no window.close was written
    rec.close()
    let s = scan(path)
    check s.health == jhCorrupt
    check s.problemsMention("no window.close followed")

  test "episode.end with an open window is refused":
    let path = freshLog()
    let rec = openRecorder(path)
    rec.episodeStart("f-end", "t", "f", Seed, Design(q: 0.5, k0: 0, windowLen: 4, intervention: "REDIRECT-v1"), nil)
    rec.pointAssigned("f-end", assign(Seed, "f-end", 0, 0.5), "REDIRECT-v1")
    rec.episodeEnd("f-end", "answered")
    rec.close()
    let s = scan(path)
    check s.health == jhCorrupt
    check s.problemsMention("window open")

  test "a censored window.close must match the open window":
    let path = freshLog()
    let rec = openRecorder(path)
    rec.episodeStart("f-cens", "t", "f", Seed, Design(q: 0.5, k0: 0, windowLen: 4, intervention: "REDIRECT-v1"), nil)
    rec.pointAssigned("f-cens", assign(Seed, "f-cens", 0, 0.5), "REDIRECT-v1")
    discard rec.observe("f-cens", "action", nil)
    rec.windowClose("f-cens", WindowClose(k: 0, actions: 2, reason: crEpisodeEnd))   # saw 1, claims 2
    rec.close()
    check scan(path).problemsMention("does not match an open window")

  test "delivery is only recorded for REDIRECT points, once":
    let path = freshLog()
    let rec = openRecorder(path)
    # Drive points until a CONTINUE point exists, then record a delivery for it.
    let t = startTrial(rec, "f-del", "t", "f", Seed, Design(q: 0.5, k0: 0, windowLen: 1, intervention: "REDIRECT-v1"))
    var contK = -1
    for i in 0 ..< 50:
      let d = t.decide()
      if d.randomized and d.arm == armContinue: (contK = d.k; break)
      t.toolAction()
    check contK >= 0
    rec.delivery("f-del", contK, true)
    rec.close()
    check scan(path).problemsMention("CONTINUE point")

  test "records for an episode by a foreign writer are refused":
    let path = freshLog()
    let t = standardEpisode(path, "f-own")
    t.rec.close()
    let other = openRecorder(path, writer = "intruder")
    other.episodeStart("decoy", "t", "f", Seed, design, nil)   # gives `other` a chain to write from
    other.close()
    rewrite(path, proc(r: JsonNode): bool =
      if r["w"].getStr.startsWith("intruder") and r["rec"].getStr == "episode.start":
        r["rec"] = %"obs"
        r["episode"] = %"f-own"
        r["t"] = %17; r["kind"] = %"turn"; r["data"] = newJObject(); r["h"] = %"00000000"
        return true)
    check scan(path).problemsMention("belongs to")

removeDir(scratch)
