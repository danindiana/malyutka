import std/[json, os, strutils]
import ./[types, latch]

proc parseTheme*(s: string): Theme =
  case s.toLowerAscii
  of "warsaw", "wp", "green": thWarsaw
  of "nato", "amber": thNato
  of "plain", "none": thPlain
  else: raise newException(ValueError, "unknown theme: " & s)

proc parseApprovalMode*(s: string): ApprovalMode =
  case s.toLowerAscii
  of "deny": amDeny
  of "stdin": amStdin
  of "tty": amTty
  of "off": amOff
  else: raise newException(ValueError, "unknown approvals mode: " & s)

proc parseCgroupMode*(s: string): CgroupMode =
  case s.toLowerAscii
  of "auto": cmAuto
  of "require": cmRequire
  of "off": cmOff
  else: raise newException(ValueError, "unknown cgroups mode: " & s)

proc defaultConfig*(): AgentConfig =
  result = baseConfig()
  result.cwd = getCurrentDir()
  result.theme = thWarsaw
  result.contextWindow = 32768
  result.providerName = getEnv("MALYUTKA_PROVIDER", "mock")
  result.model = getEnv("MALYUTKA_MODEL", "qwen3.5:latest")
  result.baseUrl = getEnv("MALYUTKA_BASE_URL", "http://127.0.0.1:11434")
  result.apiKey = getEnv("MALYUTKA_API_KEY", "")

proc loadConfig*(path: string; base = defaultConfig()): AgentConfig =
  result = base
  if not fileExists(path):
    raise newException(IOError, "config file not found: " & path)
  let j = parseJson(readFile(path))
  if j.hasKey("provider"): result.providerName = j["provider"].getStr
  if j.hasKey("model"): result.model = j["model"].getStr
  if j.hasKey("baseUrl"): result.baseUrl = j["baseUrl"].getStr
  if j.hasKey("apiKeyEnv"):
    result.apiKey = getEnv(j["apiKeyEnv"].getStr, result.apiKey)
  if j.hasKey("maxSteps"): result.maxSteps = j["maxSteps"].getInt
  if j.hasKey("allowShell"): result.allowShell = j["allowShell"].getBool
  if j.hasKey("allowFiles"): result.allowFiles = j["allowFiles"].getBool
  if j.hasKey("allowSkills"): result.allowSkills = j["allowSkills"].getBool
  if j.hasKey("allowMcp"): result.allowMcp = j["allowMcp"].getBool
  if j.hasKey("allowProcess"): result.allowProcess = j["allowProcess"].getBool
  if j.hasKey("cgroups"): result.cgroupMode = parseCgroupMode(j["cgroups"].getStr)
  if j.hasKey("limitMemoryMb"): result.limitMemoryMb = j["limitMemoryMb"].getInt
  if j.hasKey("limitPids"): result.limitPids = j["limitPids"].getInt
  if j.hasKey("maxProcesses"): result.maxProcesses = j["maxProcesses"].getInt
  if j.hasKey("contextWindow"): result.contextWindow = j["contextWindow"].getInt
  if j.hasKey("allowMemory"): result.allowMemory = j["allowMemory"].getBool
  if j.hasKey("personality"): result.personality = j["personality"].getStr.toLowerAscii
  if j.hasKey("approvals"): result.approvals = parseApprovalMode(j["approvals"].getStr)
  if j.hasKey("approvalTimeoutSec"): result.approvalTimeoutSec = j["approvalTimeoutSec"].getInt
  if j.hasKey("unconfinedHost"): result.unconfinedHost = j["unconfinedHost"].getBool
  if j.hasKey("shellTimeoutSec"): result.shellTimeoutSec = j["shellTimeoutSec"].getInt
  if j.hasKey("maxOutputBytes"): result.maxOutputBytes = j["maxOutputBytes"].getInt
  if j.hasKey("repeatLimit"): result.repeatLimit = j["repeatLimit"].getInt
  if j.hasKey("requestTimeoutSec"): result.requestTimeoutSec = j["requestTimeoutSec"].getInt
  if j.hasKey("theme"): result.theme = parseTheme(j["theme"].getStr)
  if j.hasKey("askFrom"):
    result.askEnabled = true
    result.askFrom = parseEffect(j["askFrom"].getStr)
  if j.hasKey("mandates"): result.mandates = j["mandates"].getBool
  if j.hasKey("scopeMissLimit"): result.scopeMissLimit = j["scopeMissLimit"].getInt
