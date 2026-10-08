import std/[json, os, times]
import ./types

proc roleName(r: Role): string = $r

proc saveSession*(path: string; messages: seq[Message]) =
  var arr = newJArray()
  for m in messages:
    arr.add(%*{"role": roleName(m.role), "content": m.content,
              "name": m.name, "createdAt": m.createdAt.format("yyyy-MM-dd'T'HH:mm:sszzz")})
  createDir(parentDir(path))
  writeFile(path, pretty(arr))
