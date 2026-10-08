#!/usr/bin/env python3
"""Strict fake OpenAI-compatible server for wire-protocol integration tests.

Rejects (HTTP 400, like vLLM) any request whose tool messages do not answer
a preceding assistant tool_call by id. Replays a fixed script:
  1. a shell call with JSON-string arguments (OpenAI/vLLM style)
  2. two echo calls with object arguments and no ids (some Ollama versions)
  3. a final answer quoting what it saw
Usage: fake_openai.py PORT LOGFILE
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, LOG = int(sys.argv[1]), sys.argv[2]
turn = 0

def validate(body):
    pending = set()
    for i, m in enumerate(body["messages"]):
        role = m.get("role")
        if role == "assistant" and m.get("tool_calls"):
            for tc in m["tool_calls"]:
                if not tc.get("id") or tc.get("type") != "function":
                    return f"message {i}: tool_call missing id/type"
                if not isinstance(tc["function"].get("arguments"), str):
                    return f"message {i}: arguments must be a JSON string"
                pending.add(tc["id"])
        elif role == "tool":
            tid = m.get("tool_call_id")
            if tid not in pending:
                return f"message {i}: tool message answers unknown call {tid!r}"
            pending.discard(tid)
        elif pending:
            return f"message {i}: unanswered tool calls {sorted(pending)}"
    return None

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        global turn
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        err = validate(body)
        tools = [t["function"]["name"] for t in body.get("tools", [])]
        with open(LOG, "a") as f:
            f.write(json.dumps({"turn": turn, "error": err, "tools": tools,
                                "n_messages": len(body["messages"])}) + "\n")
        if err:
            self.send_response(400); self.end_headers()
            self.wfile.write(json.dumps({"error": {"message": err}}).encode()); return
        if turn == 0:
            msg = {"role": "assistant", "content": None, "tool_calls": [
                {"id": "call_a", "type": "function",
                 "function": {"name": "shell", "arguments": json.dumps({"command": "echo sandboxed; touch /etc/escape"})}}]}
        elif turn == 1:
            msg = {"role": "assistant", "content": "", "tool_calls": [
                {"type": "function", "function": {"name": "echo", "arguments": {"text": "one"}}},
                {"type": "function", "function": {"name": "echo", "arguments": {"text": "two"}}}]}
        else:
            last_tools = [m["content"] for m in body["messages"] if m["role"] == "tool"]
            msg = {"role": "assistant", "content": "FINAL saw " + json.dumps(last_tools)}
        turn += 1
        out = json.dumps({"choices": [{"index": 0, "message": msg, "finish_reason": "stop"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers(); self.wfile.write(out)

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
