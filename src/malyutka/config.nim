import std/[json, os, strutils]
import ./types

proc parseTheme*(s: string): Theme =
  case s.toLowerAscii
  of "warsaw", "wp", "green": thWarsaw
  of "nato", "amber": thNato
  of "plain", "none": thPlain
  else: raise newException(ValueError, "unknown theme: " & s)

proc defaultConfig*(): AgentConfig =
  AgentConfig(maxSteps: 16, cwd: getCurrentDir(), allowShell: false,
    providerName: getEnv("MALYUTKA_PROVIDER", "mock"),
    model: getEnv("MALYUTKA_MODEL", "qwen3.5:latest"),
    baseUrl: getEnv("MALYUTKA_BASE_URL", "http://127.0.0.1:11434"),
    apiKey: getEnv("MALYUTKA_API_KEY", ""), theme: thWarsaw, jsonEvents: false)

proc loadConfig*(path: string; base = defaultConfig()): AgentConfig =
  result = base
  if not fileExists(path): return
  let j = parseJson(readFile(path))
  if j.hasKey("provider"): result.providerName = j["provider"].getStr
  if j.hasKey("model"): result.model = j["model"].getStr
  if j.hasKey("baseUrl"): result.baseUrl = j["baseUrl"].getStr
  if j.hasKey("apiKeyEnv"):
    result.apiKey = getEnv(j["apiKeyEnv"].getStr, result.apiKey)
  if j.hasKey("maxSteps"): result.maxSteps = j["maxSteps"].getInt
  if j.hasKey("allowShell"): result.allowShell = j["allowShell"].getBool
  if j.hasKey("theme"): result.theme = parseTheme(j["theme"].getStr)
