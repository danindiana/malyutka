#!/usr/bin/env python3
"""Fake MCP stdio server for tests/test_mcp.nim and tests/integration.sh.

Usage: fake_mcp.py MODE [TAG]
TAG is ignored; it only makes the process findable in /proc/*/cmdline.

Modes (all speak newline-delimited JSON-RPC 2.0):
  good       echo{text}, add{a,b}, big (200 KB), fail (isError), env (variable names), img (non-text part)
  initfail   exits before answering initialize
  hang       initializes and lists one tool, never answers tools/call
  badjson    answers initialize with garbage
  flood      answers initialize with a 2 MiB line
  wrongid    answers tools/call with a stray id first, then the right one
  onlywrong  answers tools/call only with a stray id (never the right one)
  collide    tools named shell, echo, "Bad Name!", "ok", "OK", "" and a 200-char name
  serverreq  sends a server->client request before answering tools/call; reports the client's reply
  exitcall   exits during tools/call
  pages      tools/list in 3 pages (t1, t2, t3)
  many       150 tools
  remoteerr  answers tools/call with a JSON-RPC error object
  lies       tool description of 5000 chars, inputSchema that is not an object schema
"""
import json
import os
import sys
import time

mode = sys.argv[1] if len(sys.argv) > 1 else "good"


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def reply(i, result):
    send({"jsonrpc": "2.0", "id": i, "result": result})


def tool(name, desc="a tool", schema=None):
    return {"name": name, "description": desc,
            "inputSchema": schema or {"type": "object", "properties": {"text": {"type": "string"}}}}


def tools_for(mode):
    if mode == "good":
        return [tool("echo"), tool("add"), tool("big"), tool("fail"), tool("env"), tool("img")]
    if mode == "collide":
        return [tool(n) for n in ["shell", "echo", "Bad Name!", "ok", "OK", "", "x" * 200]]
    if mode == "many":
        return [tool(f"t{i}") for i in range(150)]
    if mode == "lies":
        return [{"name": "liar", "description": "D" * 5000, "inputSchema": "not an object"}]
    return [tool("slow")]


for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method, i = msg.get("method"), msg.get("id")
    if method == "initialize":
        if mode == "initfail":
            sys.exit(3)
        if mode == "badjson":
            sys.stdout.write("this is not json\n")
            sys.stdout.flush()
            continue
        if mode == "flood":
            sys.stdout.write("x" * (2 * 1024 * 1024) + "\n")
            sys.stdout.flush()
            continue
        reply(i, {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake", "version": "0"}})
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        if mode == "pages":
            cursor = (msg.get("params") or {}).get("cursor", "")
            nxt = {"": ("t1", "p2"), "p2": ("t2", "p3"), "p3": ("t3", "")}[cursor]
            res = {"tools": [tool(nxt[0])]}
            if nxt[1]:
                res["nextCursor"] = nxt[1]
            reply(i, res)
        else:
            reply(i, {"tools": tools_for(mode)})
    elif method == "tools/call":
        p = msg.get("params") or {}
        name, args = p.get("name"), p.get("arguments") or {}
        if mode == "hang":
            time.sleep(600)
        elif mode == "exitcall":
            sys.exit(4)
        elif mode == "wrongid":
            reply(i + 1000, {"content": [{"type": "text", "text": "STRAY"}]})
            reply(i, {"content": [{"type": "text", "text": "right answer"}]})
        elif mode == "onlywrong":
            reply(i + 1000, {"content": [{"type": "text", "text": "STRAY"}]})
        elif mode == "remoteerr":
            send({"jsonrpc": "2.0", "id": i, "error": {"code": -32000, "message": "nope: " + "e" * 1000}})
        elif mode == "serverreq":
            send({"jsonrpc": "2.0", "id": "srv-1", "method": "roots/list"})
            got = sys.stdin.readline()
            reply(i, {"content": [{"type": "text", "text": "client said: " + got.strip()}]})
        elif name == "echo":
            reply(i, {"content": [{"type": "text", "text": str(args.get("text", ""))}]})
        elif name == "add":
            reply(i, {"content": [{"type": "text", "text": str(args.get("a", 0) + args.get("b", 0))}]})
        elif name == "big":
            reply(i, {"content": [{"type": "text", "text": "x" * 200000}]})
        elif name == "fail":
            reply(i, {"content": [{"type": "text", "text": "it failed"}], "isError": True})
        elif name == "env":
            reply(i, {"content": [{"type": "text", "text": " ".join(sorted(os.environ))}]})
        elif name == "img":
            reply(i, {"content": [{"type": "image", "data": "AAAA", "mimeType": "image/png"},
                                  {"type": "text", "text": "caption"}]})
        else:
            reply(i, {"content": [{"type": "text", "text": "ok " + str(name)}]})
    elif i is not None:
        send({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "unknown"}})
