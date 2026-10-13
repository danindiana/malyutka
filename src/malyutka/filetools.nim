## File tools. Every path is resolved component by component with openat(2)
## and O_NOFOLLOW from the workspace's own directory fd, so no string path is
## ever re-resolved: `..`, absolute paths, symlinks (final or intermediate) and
## a workspace swapped mid-run cannot lead outside it (invariant 13). Writes are
## atomic (temp file + renameat in the same directory).

import std/[json, os, posix, strutils, algorithm]
import ./[types, sandbox]

var
  lO_NOFOLLOW {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  lO_DIRECTORY {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint

proc c_openat(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}
proc c_mkdirat(dirfd: cint; path: cstring; mode: Mode): cint
  {.importc: "mkdirat", header: "<sys/stat.h>".}
proc c_renameat(od: cint; o: cstring; nd: cint; n: cstring): cint
  {.importc: "renameat", header: "<stdio.h>".}
proc c_unlinkat(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "unlinkat", header: "<unistd.h>".}

const
  MaxReadBytes* = 256 * 1024
  MaxWriteBytes* = 1024 * 1024
  MaxSearchHits = 200
  MaxSearchBytes = 32 * 1024
  MaxPatchFile = 1024 * 1024
  MaxTodoItems = 50

type
  PathError* = object of CatchableError
  ToolProc* = proc(args: JsonNode; cfg: AgentConfig): ToolResult {.closure.}

proc fail(msg: string) {.noreturn.} = raise newException(PathError, msg)

proc splitRel*(rel: string): seq[string] =
  ## Lexical gate: relative, no NUL, no `..`, no empty/`.` surprises.
  if rel.len == 0: fail("empty path")
  if '\0' in rel: fail("path contains NUL")
  if rel.startsWith("/"): fail("absolute paths are not allowed: " & rel)
  for c in rel.split('/'):
    if c == "" or c == ".": continue
    if c == "..": fail("'..' is not allowed: " & rel)
    result.add c
  if result.len == 0: fail("path names the workspace itself: " & rel)

proc openDirAt(dirfd: cint; name: string; create: bool): cint =
  var fd = c_openat(dirfd, cstring(name),
                    O_RDONLY or O_CLOEXEC or lO_NOFOLLOW or lO_DIRECTORY)
  if fd < 0 and create and errno == ENOENT:
    if c_mkdirat(dirfd, cstring(name), 0o755) != 0 and errno != EEXIST:
      fail("cannot create directory '" & name & "': " & $strerror(errno))
    fd = c_openat(dirfd, cstring(name),
                  O_RDONLY or O_CLOEXEC or lO_NOFOLLOW or lO_DIRECTORY)
  if fd < 0:
    if errno == ELOOP or errno == ENOTDIR:
      fail("'" & name & "' is not a plain directory (symlinks are refused)")
    fail("cannot open directory '" & name & "': " & $strerror(errno))
  fd

proc parentFd(ws: WorkspaceHandle; comps: seq[string]; create: bool): cint =
  ## Walks every directory component from the workspace fd. Returns an owned fd.
  var cur = c_openat(ws.fd, ".", O_RDONLY or O_CLOEXEC or lO_DIRECTORY)
  if cur < 0: fail("cannot open workspace: " & $strerror(errno))
  for i in 0 ..< comps.len - 1:
    let next = try: openDirAt(cur, comps[i], create)
               except PathError:
                 discard posix.close(cur)
                 raise
    discard posix.close(cur)
    cur = next
  cur

proc readAllFd(fd: cint; cap: int): tuple[data: string, more: bool] =
  var buf: array[16384, char]
  while true:
    let n = posix.read(fd, addr buf[0], buf.len)
    if n < 0:
      if errno == EINTR: continue
      fail("read failed: " & $strerror(errno))
    if n == 0: break
    for i in 0 ..< n:
      if result.data.len >= cap: result.more = true; return
      result.data.add buf[i]

proc readInWorkspace*(ws: WorkspaceHandle; rel: string; cap: int): tuple[data: string, more: bool] =
  let comps = splitRel(rel)
  let dfd = parentFd(ws, comps, false)
  defer: discard posix.close(dfd)
  let fd = c_openat(dfd, cstring(comps[^1]), O_RDONLY or O_CLOEXEC or lO_NOFOLLOW)
  if fd < 0:
    if errno == ELOOP: fail("'" & rel & "' is a symlink (refused)")
    fail("cannot open '" & rel & "': " & $strerror(errno))
  defer: discard posix.close(fd)
  var st: Stat
  if fstat(fd, st) != 0 or not S_ISREG(st.st_mode): fail("'" & rel & "' is not a regular file")
  readAllFd(fd, cap)

proc writeInWorkspace*(ws: WorkspaceHandle; rel, content: string) =
  ## Atomic: temp file in the target directory, fsync, renameat over the name.
  ## rename replaces a symlink at the final name instead of following it.
  if content.len > MaxWriteBytes:
    fail("content is " & $content.len & " bytes; the limit is " & $MaxWriteBytes)
  let comps = splitRel(rel)
  let dfd = parentFd(ws, comps, true)
  defer: discard posix.close(dfd)
  let name = comps[^1]
  var probe: Stat
  # A directory at the target name must not be replaced.
  let existing = c_openat(dfd, cstring(name), O_RDONLY or O_CLOEXEC or lO_NOFOLLOW or lO_DIRECTORY)
  if existing >= 0:
    discard posix.close(existing)
    fail("'" & rel & "' is a directory")
  discard probe
  let tmp = ".malyutka-tmp-" & $getCurrentProcessId()
  discard c_unlinkat(dfd, cstring(tmp), 0)
  let fd = c_openat(dfd, cstring(tmp), O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC or lO_NOFOLLOW, 0o644)
  if fd < 0: fail("cannot create temp file: " & $strerror(errno))
  var off = 0
  var werr = ""
  while off < content.len:
    let n = posix.write(fd, unsafeAddr content[off], content.len - off)
    if n < 0:
      if errno == EINTR: continue
      werr = $strerror(errno); break
    off += n
  if werr.len == 0 and fsync(fd) != 0: werr = $strerror(errno)
  discard posix.close(fd)
  if werr.len > 0:
    discard c_unlinkat(dfd, cstring(tmp), 0)
    fail("write failed: " & werr)
  if c_renameat(dfd, cstring(tmp), dfd, cstring(name)) != 0:
    let e = $strerror(errno)
    discard c_unlinkat(dfd, cstring(tmp), 0)
    fail("rename failed: " & e)

# ---- helpers ---------------------------------------------------------------

proc looksBinary(s: string): bool =
  for i in 0 ..< min(s.len, 8192):
    if s[i] == '\0': return true

proc strArg(args: JsonNode; key: string): string =
  if args.kind != JObject or not args.hasKey(key) or args[key].kind != JString:
    fail("missing string argument: " & key)
  args[key].getStr

proc optStr(args: JsonNode; key: string; default = ""): string =
  if args.kind == JObject and args.hasKey(key) and args[key].kind == JString: args[key].getStr
  else: default

proc optInt(args: JsonNode; key: string; default: int): int =
  if args.kind == JObject and args.hasKey(key) and args[key].kind == JInt: args[key].getInt
  else: default

proc errResult(e: ref CatchableError): ToolResult =
  ToolResult(ok: false, output: "ERROR: " & e.msg, exitCode: 1)

proc bodyLines(s: string): seq[string] =
  result = s.splitLines
  if result.len > 0 and result[^1] == "": result.setLen(result.len - 1)

proc diffPreview(path, old, new: string): string =
  ## "- removed" / "+ added" lines, capped at 40. An empty side contributes nothing
  ## (a new file shows only additions) and a trailing newline is not a blank line.
  var lines: seq[string]
  for l in bodyLines(old): lines.add "- " & l
  for l in bodyLines(new): lines.add "+ " & l
  var shown = lines[0 ..< min(lines.len, 40)]
  if lines.len > 40: shown.add "… (" & $(lines.len - 40) & " more lines)"
  "--- " & path & "\n" & shown.join("\n")

# ---- tools -----------------------------------------------------------------

proc readFileTool(): ToolProc =
  result = proc(args: JsonNode; cfg: AgentConfig): ToolResult =
    try:
      let path = strArg(args, "path")
      let ws = openWorkspace(cfg.cwd)
      defer: ws.close()
      let (data, more) = readInWorkspace(ws, path, MaxReadBytes)
      if looksBinary(data): fail("'" & path & "' looks binary")
      let offset = max(1, optInt(args, "offset", 1))
      let limit = max(1, optInt(args, "limit", 2000))
      var outp: seq[string]
      var n = 0
      for l in data.splitLines:
        inc n
        if n < offset: continue
        if outp.len >= limit: break
        outp.add align($n, 5) & "  " & l
      var text = outp.join("\n")
      if more: text.add "\n[malyutka: file truncated at " & $MaxReadBytes & " bytes]"
      ToolResult(ok: true, output: text, exitCode: 0, truncated: more)
    except PathError as e: errResult(e)

proc searchFilesTool(): ToolProc =
  result = proc(args: JsonNode; cfg: AgentConfig): ToolResult =
    try:
      let pattern = strArg(args, "pattern")
      if pattern.len == 0: fail("empty pattern")
      let sub = optStr(args, "path", ".")
      let glob = optStr(args, "glob")
      let ws = openWorkspace(cfg.cwd)
      defer: ws.close()
      var root = ws.path
      if sub notin ["", "."]:
        discard splitRel(sub)   # lexical gate; the walk itself never follows symlinks
        root = ws.path / sub
        if symlinkExists(root) or not dirExists(root): fail("'" & sub & "' is not a plain directory")
      var hits: seq[string]
      var bytes = 0
      var files: seq[string]
      for f in walkDirRec(root, yieldFilter = {pcFile}, followFilter = {pcDir}):
        files.add f
      files.sort()
      for f in files:
        let rel = relativePath(f, ws.path)
        if rel.startsWith(".git/") or "/.git/" in rel: continue
        if glob.len > 0 and not (extractFilename(f).endsWith(glob.replace("*", ""))): continue
        var content = ""
        try: content = readInWorkspace(ws, rel, MaxReadBytes).data
        except PathError: continue
        if looksBinary(content): continue
        var ln = 0
        for l in content.splitLines:
          inc ln
          if pattern in l:
            let hit = rel & ":" & $ln & ": " & (if l.len > 200: l[0 ..< 200] & "…" else: l)
            bytes += hit.len
            hits.add hit
            if hits.len >= MaxSearchHits or bytes >= MaxSearchBytes:
              return ToolResult(ok: true, truncated: true, exitCode: 0,
                output: hits.join("\n") & "\n[malyutka: results truncated]")
      ToolResult(ok: true, output: (if hits.len == 0: "no matches" else: hits.join("\n")), exitCode: 0)
    except PathError as e: errResult(e)

proc writeFileTool(): ToolProc =
  result = proc(args: JsonNode; cfg: AgentConfig): ToolResult =
    try:
      let path = strArg(args, "path")
      let content = strArg(args, "content")
      let ws = openWorkspace(cfg.cwd)
      defer: ws.close()
      writeInWorkspace(ws, path, content)
      ToolResult(ok: true, output: "wrote " & $content.len & " bytes to " & path, exitCode: 0,
                 preview: diffPreview(path, "", content[0 ..< min(content.len, 2000)]))
    except PathError as e: errResult(e)

proc patchTool(): ToolProc =
  result = proc(args: JsonNode; cfg: AgentConfig): ToolResult =
    try:
      let path = strArg(args, "path")
      let old = strArg(args, "old")
      let new = strArg(args, "new")
      let all = args.kind == JObject and args.hasKey("replace_all") and args["replace_all"].getBool
      if old.len == 0: fail("'old' must not be empty")
      let ws = openWorkspace(cfg.cwd)
      defer: ws.close()
      let (data, more) = readInWorkspace(ws, path, MaxPatchFile)
      if more: fail("file is larger than the " & $MaxPatchFile & "-byte patch limit")
      if looksBinary(data): fail("'" & path & "' looks binary")
      let count = data.count(old)
      if count == 0: fail("'old' text not found in " & path)
      if count > 1 and not all:
        fail("'old' text occurs " & $count & " times; add context or set replace_all")
      writeInWorkspace(ws, path, data.replace(old, new))
      ToolResult(ok: true, exitCode: 0,
        output: "patched " & path & ": " & $(if all: count else: 1) & " replacement(s)",
        preview: diffPreview(path, old, new))
    except PathError as e: errResult(e)

proc todoTool(): ToolProc =
  result = proc(args: JsonNode; cfg: AgentConfig): ToolResult =
    try:
      if args.kind != JObject or not args.hasKey("items") or args["items"].kind != JArray:
        fail("missing array argument: items")
      if args["items"].len > MaxTodoItems: fail("at most " & $MaxTodoItems & " items")
      var items = newJArray()
      var lines: seq[string]
      for it in args["items"]:
        if it.kind != JObject: fail("each item must be an object")
        let text = optStr(it, "text")
        let status = optStr(it, "status", "pending")
        if text.len == 0 or text.len > 200: fail("item text must be 1-200 characters")
        if status notin ["pending", "in_progress", "done"]:
          fail("status must be pending, in_progress or done")
        let id = optStr(it, "id", $(items.len + 1))
        items.add %*{"id": id, "text": text, "status": status}
        let mark = (case status
                    of "done": "[x]"
                    of "in_progress": "[~]"
                    else: "[ ]")
        lines.add mark & " " & text
      ToolResult(ok: true, output: lines.join("\n"), exitCode: 0,
                 eventKind: "todo.update", eventPayload: %*{"items": items})
    except PathError as e: errResult(e)

proc fileToolProcs*(): seq[tuple[name, description: string; parameters: JsonNode;
                                 ceiling: EffectClass; run: ToolProc]] =
  @[("read_file", "Read a text file in the workspace (line-numbered).",
     %*{"type": "object", "properties": {"path": {"type": "string"},
        "offset": {"type": "integer"}, "limit": {"type": "integer"}}, "required": ["path"]},
     b1LocalReversible, readFileTool()),
    ("search_files", "Find lines containing a substring in workspace files.",
     %*{"type": "object", "properties": {"pattern": {"type": "string"},
        "path": {"type": "string"}, "glob": {"type": "string"}}, "required": ["pattern"]},
     b1LocalReversible, searchFilesTool()),
    ("write_file", "Create or overwrite a text file in the workspace (atomic).",
     %*{"type": "object", "properties": {"path": {"type": "string"},
        "content": {"type": "string"}}, "required": ["path", "content"]},
     b2BroadWorkspace, writeFileTool()),
    ("patch", "Replace exact text in a workspace file; fails if it is absent or ambiguous.",
     %*{"type": "object", "properties": {"path": {"type": "string"}, "old": {"type": "string"},
        "new": {"type": "string"}, "replace_all": {"type": "boolean"}},
        "required": ["path", "old", "new"]},
     b2BroadWorkspace, patchTool()),
    ("todo", "Replace the task checklist. Items: {id?, text, status: pending|in_progress|done}.",
     %*{"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object",
        "properties": {"id": {"type": "string"}, "text": {"type": "string"},
        "status": {"type": "string"}}, "required": ["text"]}}}, "required": ["items"]},
     b0ReadOnly, todoTool())]
