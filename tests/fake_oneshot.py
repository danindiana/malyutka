#!/usr/bin/env python3
"""Fake OpenAI-compatible server: one shell call with the given command, then a final answer.
Usage: fake_oneshot.py PORT COMMAND"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT, CMD = int(sys.argv[1]), sys.argv[2]
turn = 0
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        global turn
        self.rfile.read(int(self.headers["Content-Length"]))
        if turn == 0:
            msg = {"role": "assistant", "content": None, "tool_calls": [{"id": "c1", "type": "function",
                   "function": {"name": "shell", "arguments": json.dumps({"command": CMD})}}]}
        else:
            msg = {"role": "assistant", "content": "done"}
        turn += 1
        out = json.dumps({"choices": [{"message": msg}]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
