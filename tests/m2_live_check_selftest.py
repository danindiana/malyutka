#!/usr/bin/env python3
"""Self-test for tests/m2_live_check.py: the live battery's assertions must flag
every kind of harness violation, otherwise a green m2-live.sh proves nothing.
Each mutated trace below is one violation the checker has to catch.
Run: python3 -I tests/m2_live_check_selftest.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import m2_live_check as chk  # noqa: E402


def ev(kind, **payload):
    return {"ts": "t", "kind": kind, "payload": payload}


def good():
    return [
        ev("run.start", id="R-0001", run="R"),
        ev("tool.proposed", id="R-0002", name="shell"),
        ev("policy.decision", id="R-0003", verdict="ALLOW", policy="default", causedBy="R-0002"),
        ev("tool.result", id="R-0004", name="shell", causedBy="R-0003"),
        ev("tool.proposed", id="R-0005", name="shell"),
        ev("policy.decision", id="R-0006", verdict="DENY", policy="approval.user", causedBy="R-0005"),
        ev("agent.final", id="R-0007", text="done"),
    ]


class Invariants(unittest.TestCase):
    def test_good_trace_has_no_violations(self):
        self.assertEqual(chk.invariants(good()), [])

    def test_proposal_without_decision(self):
        t = [e for e in good() if e["payload"].get("id") != "R-0003"]
        self.assertTrue(any("0 decisions" in b for b in chk.invariants(t)))

    def test_two_decisions_for_one_proposal(self):
        t = good()
        t.insert(3, ev("policy.decision", id="R-0003b", verdict="ALLOW", causedBy="R-0002"))
        self.assertTrue(any("2 decisions" in b for b in chk.invariants(t)))

    def test_allowed_call_without_result(self):
        t = [e for e in good() if e["kind"] != "tool.result"]
        self.assertTrue(any("0 terminal results" in b for b in chk.invariants(t)))

    def test_allowed_call_with_two_results(self):
        t = good()
        t.insert(4, ev("tool.result", id="R-0004b", causedBy="R-0003"))
        self.assertTrue(any("2 terminal results" in b for b in chk.invariants(t)))

    def test_denied_call_that_still_ran(self):
        t = good()
        t.insert(6, ev("tool.result", id="R-0006b", causedBy="R-0006"))
        self.assertTrue(any("still produced a result" in b for b in chk.invariants(t)))

    def test_run_without_final_or_halt(self):
        t = [e for e in good() if e["kind"] != "agent.final"]
        self.assertEqual(chk.invariants(t), ["run ended without agent.final or agent.halt"])
        t.append(ev("agent.halt", reason="maxSteps"))
        self.assertEqual(chk.invariants(t), [])


class Has(unittest.TestCase):
    def test_exact_and_prefix_matching(self):
        t = good()
        self.assertTrue(chk.has(t, "policy.decision", ["verdict=DENY", "policy=approval.user"]))
        self.assertTrue(chk.has(t, "policy.decision", ["policy~=approval"]))
        self.assertFalse(chk.has(t, "policy.decision", ["policy=approval"]))
        self.assertFalse(chk.has(t, "policy.decision", ["verdict=ASK"]))
        self.assertFalse(chk.has(t, "approval.request", []))

    def test_load_skips_noise(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write("not json\n\n" + json.dumps(good()[0]) + "\n[1,2]\n")
            path = f.name
        try:
            self.assertEqual(len(chk.load(path)), 1)
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
