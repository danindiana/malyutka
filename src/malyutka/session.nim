import std/[json, os, times]
import ./types

proc saveSession*(path, runId: string; messages: seq[Message]) =
  var arr = newJArray()
  for m in messages:
    var item = %*{"role": $m.role, "content": m.content, "name": m.name,
                  "createdAt": m.createdAt.format("yyyy-MM-dd'T'HH:mm:sszzz")}
    if m.toolCallId.len > 0: item["toolCallId"] = %m.toolCallId
    if m.toolCalls.len > 0:
      var calls = newJArray()
      for c in m.toolCalls: calls.add %*{"id": c.id, "name": c.name, "args": c.args}
      item["toolCalls"] = calls
    arr.add item
  createDir(parentDir(path))
  writeFile(path, pretty(%*{"run": runId, "messages": arr}))
