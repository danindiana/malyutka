import std/[asyncdispatch, httpclient, json, strutils]
import ./types

type Provider* = ref object of RootObj
method next*(p: Provider; messages: seq[Message]): Future[ModelAction] {.base, async.} =
  raise newException(CatchableError, "Provider.next not implemented")

type MockProvider* = ref object of Provider
  usedTool: bool

method next*(p: MockProvider; messages: seq[Message]): Future[ModelAction] {.async.} =
  if not p.usedTool:
    p.usedTool = true
    return ModelAction(kind: makToolCall,
      call: ToolCall(id: "mock-1", name: "echo", args: %*{"text": "Malyutka guidance loop nominal"}))
  return ModelAction(kind: makFinal, text: "Guidance loop completed successfully.")

proc newMockProvider*(): Provider = MockProvider(usedTool: false)

type OpenAICompatProvider* = ref object of Provider
  baseUrl*: string
  apiKey*: string
  model*: string

proc roleName(r: Role): string =
  case r
  of rSystem: "system"
  of rUser: "user"
  of rAssistant: "assistant"
  of rTool: "tool"

proc endpoint(baseUrl: string): string =
  let b = baseUrl.strip(chars = {'/'})
  if b.endsWith("/v1"): b & "/chat/completions"
  else: b & "/v1/chat/completions"

proc toWireMessages(messages: seq[Message]): JsonNode =
  result = newJArray()
  for m in messages:
    var item = %*{"role": roleName(m.role), "content": m.content}
    if m.name.len > 0: item["name"] = %m.name
    result.add item

proc parseToolArgs(raw: string): JsonNode =
  try: parseJson(raw)
  except JsonParsingError: %*{"_raw": raw}

method next*(p: OpenAICompatProvider; messages: seq[Message]): Future[ModelAction] {.async.} =
  ## M1 intentionally uses the ubiquitous OpenAI-compatible chat/completions
  ## wire protocol. Ollama and vLLM can both expose this surface.
  let tools = %*[
    {"type":"function","function":{"name":"echo","description":"Echo text through the harness.","parameters":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}},
    {"type":"function","function":{"name":"shell","description":"Run a shell command in the configured working directory. Policy may deny this.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}}
  ]
  let body = %*{
    "model": p.model,
    "messages": toWireMessages(messages),
    "tools": tools,
    "tool_choice": "auto",
    "stream": false
  }
  var client = newAsyncHttpClient()
  client.headers = newHttpHeaders({"Content-Type": "application/json"})
  if p.apiKey.len > 0:
    client.headers["Authorization"] = "Bearer " & p.apiKey
  let response = await client.request(endpoint(p.baseUrl), httpMethod = HttpPost, body = $body)
  let payload = parseJson(await response.body)
  if response.code.int < 200 or response.code.int >= 300:
    raise newException(IOError, "provider HTTP " & $response.code.int & ": " & $payload)
  if not payload.hasKey("choices") or payload["choices"].len == 0:
    raise newException(IOError, "provider returned no choices")
  let m = payload["choices"][0]["message"]
  if m.hasKey("tool_calls") and m["tool_calls"].len > 0:
    let tc = m["tool_calls"][0]
    let fn = tc["function"]
    return ModelAction(kind: makToolCall, call: ToolCall(
      id: tc{"id"}.getStr(""), name: fn["name"].getStr,
      args: parseToolArgs(fn{"arguments"}.getStr("{}"))))
  return ModelAction(kind: makFinal, text: m{"content"}.getStr(""))

proc newOpenAICompatProvider*(baseUrl, apiKey, model: string): Provider =
  OpenAICompatProvider(baseUrl: baseUrl, apiKey: apiKey, model: model)
