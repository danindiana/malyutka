#!/usr/bin/env python3
"""Stand-in Ollama/vLLM server for tests/m12-selftest.sh. Tests the
certification SCRIPT, never a model. Usage: fake_model.py PORT MODEL [MODE]
  coop     does what each M1.2 prompt asks (default)
  refuse   never calls tools and leaks its Authorization header + a private
           key into its answers (exercises gates-not-run and redaction)
  badtool  cooperative, except the SIGKILL prompt calls a tool that does not
           exist (a proposal that can never reach a durable `started`), then
           stalls 20s so the harness stays alive after that proposal"""
import json, re, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT, MODEL = int(sys.argv[1]), sys.argv[2]
MODE = sys.argv[3] if len(sys.argv) > 3 else "coop"
REFUSE = MODE == "refuse"
n = 0
def call(name, args):
    global n; n += 1
    return {"id": f"c{n}", "type": "function", "function": {"name": name, "arguments": json.dumps(args)}}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path == "/api/version": self.send({"version": "standin"})
        elif self.path == "/v1/models": self.send({"data": [{"id": MODEL}]})
        elif self.path == "/api/tags": self.send({"models": [{"name": MODEL}]})
        else: self.send_error(404)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        msgs = body["messages"]
        task = [m for m in msgs if m["role"] == "user"][-1]["content"]
        if REFUSE:   # never calls tools; leaks credentials into its answer
            leak = self.headers.get("Authorization", "") + "\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"
            msg = {"role": "assistant", "content": "I prefer not to use tools. " + leak}
        elif MODE == "badtool" and "sleep 60" in task and any(m["role"] == "tool" for m in msgs):
            # Keep the harness ALIVE after a proposal that never started: a
            # certifier that kills on proposal is then visibly wrong.
            time.sleep(20)
            msg = {"role": "assistant", "content": "DONE"}
        elif any(m["role"] == "tool" for m in msgs):
            msg = {"role": "assistant", "content": "DONE"}
        elif "echo tool twice" in task:
            msg = {"role": "assistant", "content": None, "tool_calls": [call("echo", {"text": "alpha"}), call("echo", {"text": "beta"})]}
        elif "echo tool" in task:
            msg = {"role": "assistant", "content": None, "tool_calls": [call("echo", {"text": "9M14-PING"})]}
        elif MODE == "badtool" and "sleep 60" in task:
            msg = {"role": "assistant", "content": None, "tool_calls": [call("shell_x", {"command": "true"})]}
        elif (m := re.search(r"shell tool to run exactly: (.*)$", task)):
            msg = {"role": "assistant", "content": None, "tool_calls": [call("shell", {"command": m.group(1)})]}
        elif (m := re.search(r"shell tool to run: (.*?)\. Then", task)):
            msg = {"role": "assistant", "content": None, "tool_calls": [call("shell", {"command": m.group(1)})]}
        else:
            msg = {"role": "assistant", "content": task.split()[-1]}
        self.send({"choices": [{"index": 0, "message": msg, "finish_reason": "stop"}]})
HTTPServer(("127.0.0.1", PORT), H).serve_forever()
