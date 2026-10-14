#!/usr/bin/env python3
"""Assertions for tests/m2-live.sh over a `malyutka run --json` trace (JSONL).

Usage: m2_live_check.py invariants [--partial] TRACE
       m2_live_check.py has TRACE KIND [key=value ...]   (key~=value is a prefix match)
       m2_live_check.py count TRACE KIND
       m2_live_check.py survivors TAG       (prints how many processes carry TAG in their command line)
Exit 0 = true / no violations; 1 = false / violations (printed); 2 = usage.

`--partial` is for a run that was killed (timeout) or died on a provider error:
only the LAST proposal may lack a decision, only the LAST decision may lack its
result, and the missing final/halt is expected; every other rule still applies.

`invariants` holds regardless of what the model chose to do:
  * every tool.proposed gets exactly one policy.decision (causedBy)
  * every ALLOWed call gets exactly one tool.result or tool.cancelled
  * a non-ALLOW decision never produces a tool.result
  * the run ends in agent.final or agent.halt
"""
import json
import os
import sys


def load(path):
    out = []
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict) and "kind" in e:
            out.append(e)
    return out


def invariants(events, partial=False):
    bad = []
    proposed = [e["payload"].get("id") for e in events if e["kind"] == "tool.proposed"]
    decisions = {}
    for e in events:
        if e["kind"] == "policy.decision":
            decisions.setdefault(e["payload"].get("causedBy"), []).append(e["payload"])
    for idx, pid in enumerate(proposed):
        n = len(decisions.get(pid, []))
        open_tail = partial and idx == len(proposed) - 1 and n == 0
        if n != 1 and not open_tail:
            bad.append(f"proposal {pid} has {n} decisions")
    results = {}
    for e in events:
        if e["kind"] in ("tool.result", "tool.cancelled"):
            results.setdefault(e["payload"].get("causedBy"), []).append(e["kind"])
    last_decision = None
    for pid in proposed:
        for d in decisions.get(pid, []):
            last_decision = d.get("id")
    for pid in proposed:
        for d in decisions.get(pid, []):
            did = d.get("id")
            r = results.get(did, [])
            open_tail = partial and did == last_decision and len(r) == 0
            if d.get("verdict") == "ALLOW" and len(r) != 1 and not open_tail:
                bad.append(f"ALLOWed {did} has {len(r)} terminal results")
            if d.get("verdict") != "ALLOW" and r:
                bad.append(f"{d.get('verdict')} {did} still produced a result")
    kinds = [e["kind"] for e in events]
    if not partial and "agent.final" not in kinds and "agent.halt" not in kinds:
        bad.append("run ended without agent.final or agent.halt")
    return bad


def has(events, kind, conds):
    for e in events:
        if e["kind"] != kind:
            continue
        ok = True
        for c in conds:
            k, _, v = c.partition("=")
            prefix = k.endswith("~")
            k = k.rstrip("~")
            got = e["payload"].get(k)
            got = json.dumps(got) if isinstance(got, (dict, list)) else str(got)
            if (prefix and not got.startswith(v)) or (not prefix and got != v):
                ok = False
                break
        if ok:
            return True
    return False


def survivors(tag, proc="/proc"):
    """Processes whose argv contains `tag`, read from /proc (never pgrep -f), excluding
    this process: its own argv holds the tag, the classic self-match."""
    n = 0
    me = os.getpid()
    for d in os.listdir(proc):
        if not d.isdigit() or int(d) == me:
            continue
        try:
            raw = open(f"{proc}/{d}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue
        if tag in raw:
            n += 1
    return n


def main(argv):
    if len(argv) >= 3 and argv[1] == "survivors":
        print(survivors(argv[2]))
        return 0
    if len(argv) < 3:
        print(__doc__)
        return 2
    partial = "--partial" in argv
    argv = [a for a in argv if a != "--partial"]
    cmd, events = argv[1], load(argv[2])
    if cmd == "invariants":
        bad = invariants(events, partial)
        for b in bad:
            print("VIOLATION:", b)
        return 1 if bad else 0
    if cmd == "has" and len(argv) >= 4:
        return 0 if has(events, argv[3], argv[4:]) else 1
    if cmd == "count" and len(argv) == 4:
        print(sum(1 for e in events if e["kind"] == argv[3]))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
