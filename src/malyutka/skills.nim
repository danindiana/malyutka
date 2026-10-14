## Skills (SPEC-009): reusable notes in the agentskills.io SKILL.md shape. They are
## DATA: a skill's text reaches the model only as a tool result, nothing in it is
## executed, and it can neither add a tool nor change a verdict (invariants 1, 4).

import std/[algorithm, json, os, posix, strutils]
import ./[types, memory]

const
  MaxSkillBytes* = 16 * 1024
  MaxSkills* = 100
  MaxSkillFiles = 50
  MaxDescription = 300

type
  SkillError* = object of CatchableError
  SkillInfo* = object
    name*, description*: string

proc validSkillName*(n: string): bool =
  if n.len < 1 or n.len > 48 or n[0] notin {'a'..'z', '0'..'9'}: return false
  for c in n:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc skillsDir*(stateDir: string): string = stateDir / "skills"

proc parseFrontmatter*(text: string): tuple[ok: bool, name, description, body, why: string] =
  ## `---` / `key: value` lines / `---`, then markdown. Only name and description matter.
  let lines = text.splitLines
  if lines.len < 3 or lines[0].strip != "---": return (false, "", "", "", "missing frontmatter")
  var i = 1
  var name, desc = ""
  while i < lines.len and lines[i].strip != "---":
    let colon = lines[i].find(':')
    if colon > 0:
      let v = lines[i][colon + 1 .. ^1].strip
      case lines[i][0 ..< colon].strip.toLowerAscii
      of "name": name = v
      of "description": desc = v
      else: discard
    inc i
  if i >= lines.len: return (false, "", "", "", "unterminated frontmatter")
  if name.len == 0: return (false, "", "", "", "frontmatter has no name")
  if desc.len == 0 or desc.len > MaxDescription:
    return (false, "", "", "", "description must be 1-" & $MaxDescription & " characters")
  (true, name, desc, lines[i + 1 .. ^1].join("\n"), "")

proc realDir(path: string): string =
  ## "" if `path` is a plain directory owned by the operator and not writable by
  ## group/others; otherwise the reason it is refused.
  var st: Stat
  if lstat(cstring(path), st) != 0: return "missing"
  if S_ISLNK(st.st_mode): return "is a symlink"
  if not S_ISDIR(st.st_mode): return "is not a directory"
  if st.st_uid != getuid(): return "not owned by the operator"
  if (int(st.st_mode) and 0o022) != 0: return "writable by group/others"
  ""

proc listSkills*(stateDir: string): tuple[skills: seq[SkillInfo], skipped: seq[string]] =
  let root = skillsDir(stateDir)
  if not dirExists(root): return
  var names: seq[string]
  for kind, path in walkDir(root):
    names.add extractFilename(path)
  names.sort()
  if realDir(root).len > 0:
    result.skipped.add "skills directory (" & realDir(root) & ")"
    return
  for n in names:
    if result.skills.len >= MaxSkills: break
    if not validSkillName(n):
      result.skipped.add n & " (invalid name)"; continue
    let d = root / n
    let why = realDir(d)
    if why.len > 0: result.skipped.add n & " (" & why & ")"; continue
    let (text, problem) = readOperatorFile(d / "SKILL.md", MaxSkillBytes, false)
    if problem.len > 0 or text.len == 0:
      result.skipped.add n & " (" & (if problem.len > 0: "SKILL.md: " & problem else: "no SKILL.md") & ")"
      continue
    let fm = parseFrontmatter(text)
    if not fm.ok: result.skipped.add n & " (" & fm.why & ")"; continue
    if fm.name != n: result.skipped.add n & " (frontmatter name '" & fm.name & "' differs)"; continue
    result.skills.add SkillInfo(name: n, description: fm.description)

proc viewSkill*(stateDir, name: string): tuple[text: string, files: seq[string]] =
  if not validSkillName(name): raise newException(SkillError, "invalid skill name")
  let root = skillsDir(stateDir)
  let d = root / name
  if realDir(root).len > 0 or realDir(d).len > 0:
    raise newException(SkillError, "no usable skill '" & name & "'")
  let (text, problem) = readOperatorFile(d / "SKILL.md", MaxSkillBytes, false)
  if problem.len > 0 or text.len == 0: raise newException(SkillError, "no usable skill '" & name & "'")
  let fm = parseFrontmatter(text)
  if not fm.ok or fm.name != name: raise newException(SkillError, "skill '" & name & "' has invalid frontmatter")
  result.text = text
  for kind, path in walkDir(d):
    let f = extractFilename(path)
    if f != "SKILL.md" and result.files.len < MaxSkillFiles: result.files.add f
  result.files.sort()

proc saveSkill*(stateDir, name, content: string) =
  ## Atomic, 0600 file in a 0700 directory, only under <state>/skills/<name>/.
  if not validSkillName(name): raise newException(SkillError, "invalid skill name (use a-z, 0-9, '-', max 48)")
  if content.len == 0 or content.len > MaxSkillBytes:
    raise newException(SkillError, "content must be 1-" & $MaxSkillBytes & " bytes")
  let fm = parseFrontmatter(content)
  if not fm.ok: raise newException(SkillError, "invalid SKILL.md: " & fm.why)
  if fm.name != name: raise newException(SkillError, "frontmatter name '" & fm.name & "' must equal '" & name & "'")
  let root = skillsDir(stateDir)
  for d in [root, root / name]:
    var st: Stat
    if lstat(cstring(d), st) == 0:
      if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
        raise newException(SkillError, d & " is not a plain directory")
    elif mkdir(cstring(d), 0o700) != 0:
      raise newException(SkillError, "cannot create " & d & ": " & $strerror(errno))
  writePrivate(root / name / "SKILL.md", content)

proc strArg(args: JsonNode; k: string): string =
  if args.kind == JObject and args.hasKey(k) and args[k].kind == JString: args[k].getStr else: ""

proc runSkillsList*(args: JsonNode; cfg: AgentConfig): ToolResult =
  let (skills, skipped) = listSkills(cfg.stateDir)
  var lines: seq[string]
  for s in skills: lines.add s.name & ": " & s.description
  for s in skipped: lines.add "skipped: " & s
  ToolResult(ok: true, exitCode: 0, output: (if lines.len == 0: "no skills" else: lines.join("\n")))

proc runSkillView*(args: JsonNode; cfg: AgentConfig): ToolResult =
  try:
    let (text, files) = viewSkill(cfg.stateDir, strArg(args, "name"))
    var res = text
    if files.len > 0: res.add "\n\n[files in this skill (not loaded): " & files.join(", ") & "]"
    ToolResult(ok: true, exitCode: 0, output: res)
  except SkillError as e:
    ToolResult(ok: false, exitCode: 1, output: "ERROR: " & e.msg)

proc runSkillSave*(args: JsonNode; cfg: AgentConfig): ToolResult =
  try:
    saveSkill(cfg.stateDir, strArg(args, "name"), strArg(args, "content"))
    ToolResult(ok: true, exitCode: 0, output: "saved skill " & strArg(args, "name"))
  except SkillError as e:
    ToolResult(ok: false, exitCode: 1, output: "ERROR: " & e.msg)
  except CatchableError as e:
    ToolResult(ok: false, exitCode: 1, output: "ERROR: " & e.msg)
