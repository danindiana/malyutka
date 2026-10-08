import std/[asyncdispatch, json, os, unittest]
import malyutka/[types, provider, core, policy, config]

suite "malyutka core":
  test "mock provider completes through tool loop":
    let cfg = AgentConfig(maxSteps: 4, cwd: getCurrentDir(), allowShell: false,
      providerName: "mock", model: "mock", baseUrl: "", apiKey: "", theme: thPlain, jsonEvents: false)
    let r = waitFor runAgent(newMockProvider(), "test", cfg, sink = proc(k: string; p: JsonNode) = discard)
    check r.answer == "Guidance loop completed successfully."
    check r.messages.len >= 4

  test "shell is denied by default":
    let cfg = AgentConfig(maxSteps: 4, cwd: getCurrentDir(), allowShell: false,
      providerName: "mock", model: "mock", baseUrl: "", apiKey: "", theme: thPlain, jsonEvents: false)
    let d = decide(ToolCall(id: "t1", name: "shell", args: %*{"command":"pwd"}), cfg)
    check d.kind == pdDeny

  test "theme aliases parse":
    check parseTheme("green") == thWarsaw
    check parseTheme("amber") == thNato
