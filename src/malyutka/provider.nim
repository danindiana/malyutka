import std/[asyncdispatch, httpclient, json, strutils]
import ./types

type Provider* = ref object of RootObj
  name*: string

method next*(p: Provider; messages: seq[Message]; tools: JsonNode): Future[ModelAction] {.base, async.} =
  raise newException(CatchableError, "Provider.next not implemented")

# ---- scripted mock --------------------------------------------------------

type MockProvider* = ref object of Provider
  script*: seq[ModelAction]
  pos: int

method next*(p: MockProvider; messages: seq[Message]; tools: JsonNode): Future[ModelAction] {.async.} =
  if p.pos < p.script.len:
    result = p.script[p.pos]
    inc p.pos
  else:
    result = ModelAction(kind: makFinal, text: "Mock script exhausted.")

proc newScriptedProvider*(script: seq[ModelAction]): MockProvider =
  MockProvider(name: "mock", script: script)

proc newMockProvider*(): Provider =
  newScriptedProvider(@[
    ModelAction(kind: makToolCalls, calls: @[ToolCall(id: "mock-1", name: "echo",
      args: %*{"text": "Malyutka guidance loop nominal"})]),
    ModelAction(kind: makFinal, text: "Guidance loop completed successfully.")])

# ---- OpenAI-compatible ----------------------------------------------------

type OpenAICompatProvider* = ref object of Provider
  baseUrl*: string
  apiKey*: string
  model*: string
  timeoutMs*: int
  callSeq: int

proc roleName(r: Role): string =
  case r
  of rSystem: "system"
  of rUser: "user"
  of rAssistant: "assistant"
  of rTool: "tool"

proc endpoint*(baseUrl: string): string =
  let b = baseUrl.strip(leading = false, chars = {'/'})
  if b.endsWith("/v1"): b & "/chat/completions"
  else: b & "/v1/chat/completions"

proc toWireMessages*(messages: seq[Message]): JsonNode =
  ## Tool protocol: an assistant message carrying `tool_calls`, followed by one
  ## `tool` message per call with the matching `tool_call_id`. Strict servers
  ## (vLLM, OpenAI) reject tool messages that do not answer a preceding call.
  result = newJArray()
  for m in messages:
    var item = %*{"role": roleName(m.role)}
    case m.role
    of rAssistant:
      if m.toolCalls.len > 0:
        item["content"] = (if m.content.len > 0: %m.content else: newJNull())
        var calls = newJArray()
        for c in m.toolCalls:
          calls.add %*{"id": c.id, "type": "function",
            "function": {"name": c.name, "arguments": $c.args}}
        item["tool_calls"] = calls
      else:
        item["content"] = %m.content
    of rTool:
      item["tool_call_id"] = %m.toolCallId
      item["content"] = %m.content
    else:
      item["content"] = %m.content
    result.add item

proc parseToolArgs(node: JsonNode): JsonNode =
  ## Servers disagree: OpenAI/vLLM send a JSON string, some Ollama versions
  ## send an object. Unparseable input is preserved, never dropped.
  if node.isNil or node.kind == JNull: return newJObject()
  if node.kind == JObject: return node
  if node.kind == JString:
    let raw = node.getStr
    if raw.strip.len == 0: return newJObject()
    try: return parseJson(raw)
    except JsonParsingError: return %*{"_raw": raw}
  %*{"_raw": $node}

proc parseResponse*(p: OpenAICompatProvider; payload: JsonNode): ModelAction =
  if not payload.hasKey("choices") or payload["choices"].len == 0:
    raise newException(IOError, "provider returned no choices: " & $payload)
  let m = payload["choices"][0]{"message"}
  if m.isNil: raise newException(IOError, "provider choice has no message")
  let text = if m{"content"}.isNil or m["content"].kind != JString: "" else: m["content"].getStr
  if m.hasKey("tool_calls") and m["tool_calls"].kind == JArray and m["tool_calls"].len > 0:
    var calls: seq[ToolCall]
    var seen: seq[string]
    for tc in m["tool_calls"]:
      let fn = tc{"function"}
      if fn.isNil: continue
      var id = tc{"id"}.getStr("")
      if id.len == 0 or id in seen:  # missing or reused ids: ours must be unique per turn
        inc p.callSeq
        id = "mk_" & $p.callSeq
      seen.add id
      calls.add ToolCall(id: id, name: fn{"name"}.getStr(""),
                         args: parseToolArgs(fn{"arguments"}))
    if calls.len > 0:
      return ModelAction(kind: makToolCalls, text: text, calls: calls)
  ModelAction(kind: makFinal, text: text)

method next*(p: OpenAICompatProvider; messages: seq[Message]; tools: JsonNode): Future[ModelAction] {.async.} =
  var body = %*{"model": p.model, "messages": toWireMessages(messages), "stream": false}
  if tools.len > 0:
    body["tools"] = tools
    body["tool_choice"] = %"auto"
  let client = newAsyncHttpClient()
  try:
    client.headers = newHttpHeaders({"Content-Type": "application/json"})
    if p.apiKey.len > 0:
      client.headers["Authorization"] = "Bearer " & p.apiKey
    let fut = client.request(endpoint(p.baseUrl), httpMethod = HttpPost, body = $body)
    let inTime = await fut.withTimeout(p.timeoutMs)
    if not inTime:
      raise newException(IOError, "provider timed out after " & $(p.timeoutMs div 1000) & "s")
    let response = fut.read
    let raw = await response.body
    if response.code.int < 200 or response.code.int >= 300:
      raise newException(IOError, "provider HTTP " & $response.code.int & ": " &
        (if raw.len > 500: raw[0 ..< 500] & "..." else: raw))
    var payload: JsonNode
    try: payload = parseJson(raw)
    except JsonParsingError:
      raise newException(IOError, "provider returned non-JSON body")
    result = p.parseResponse(payload)
  finally:
    client.close()

proc newOpenAICompatProvider*(name, baseUrl, apiKey, model: string; timeoutSec = 300): Provider =
  OpenAICompatProvider(name: name, baseUrl: baseUrl, apiKey: apiKey, model: model,
                       timeoutMs: timeoutSec * 1000)
