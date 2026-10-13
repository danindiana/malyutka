#!/usr/bin/env python3
"""Scripted fake OpenAI-compatible server.

Usage: fake_script.py PORT SCRIPT.json [REQUEST_LOG]
SCRIPT is a JSON list of turns; each turn is a list of {"name", "args"} tool
calls, or {"final": "text"}. After the script is exhausted it answers with
"FINAL saw <tool outputs>" so tests can assert what the model was told.
With REQUEST_LOG, every request body is appended to it as one JSON line.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
SCRIPT = json.load(open(sys.argv[2]))
LOG = sys.argv[3] if len(sys.argv) > 3 else None
turn = 0

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        global turn
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if LOG:
            with open(LOG, "a") as f: f.write(json.dumps(body) + "\n")
        step = SCRIPT[turn] if turn < len(SCRIPT) else None
        if step is None or isinstance(step, dict):
            tools = [m["content"] for m in body["messages"] if m["role"] == "tool"]
            text = (step or {}).get("final") or "FINAL saw " + json.dumps(tools)
            msg = {"role": "assistant", "content": text}
        else:
            msg = {"role": "assistant", "content": None, "tool_calls": [
                {"id": "call_%d_%d" % (turn, i), "type": "function",
                 "function": {"name": c["name"], "arguments": json.dumps(c["args"])}}
                for i, c in enumerate(step)]}
        turn += 1
        out = json.dumps({"choices": [{"index": 0, "message": msg, "finish_reason": "stop"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers(); self.wfile.write(out)

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
