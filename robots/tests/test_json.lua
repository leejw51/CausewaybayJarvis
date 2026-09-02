-- JSON encode/decode, checked against bodies the ollama.com API really sent.
local Json = require("src.json")

-- one real /api/chat reply, and one that asked for a tool instead of talking
local REPLY = [[{"model":"gpt-oss:20b","created_at":"2026-09-01T06:28:03Z","message":{"role":"assistant","content":"Unit 12 drifting off course, sir.","thinking":"Short answer, address as \"SIR\"."},"done":true,"done_reason":"stop","eval_count":58}]]
local TOOLCALL = [[{"model":"gpt-oss:20b","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1cq3ei8b","function":{"index":0,"name":"fleet_command","arguments":{"command":"return_home"}}}]},"done":true,"done_reason":"stop"}]]

return function(t)
  t.describe("json")

  t.it("encodes scalars", function()
    t.eq(Json.encode("hi"), '"hi"')
    t.eq(Json.encode(true), "true")
    t.eq(Json.encode(12), "12")
    t.eq(Json.encode(0.5), "0.5")
  end)

  t.it("escapes control characters and quotes", function()
    t.eq(Json.encode('a"b\\c'), '"a\\"b\\\\c"')
    t.eq(Json.encode("line\nbreak"), '"line\\nbreak"')
    t.eq(Json.encode("tab\tsep"), '"tab\\tsep"')
  end)

  t.it("encodes arrays as arrays", function()
    t.eq(Json.encode({ 1, 2, 3 }), "[1,2,3]")
  end)

  t.it("encodes an empty table as an object, for tools with no arguments", function()
    -- "properties": [] makes the tool schema invalid; it has to be {}
    t.eq(Json.encode({}), "{}")
    t.has(Json.encode({ type = "object", properties = {} }), '"properties":{}')
  end)

  t.it("round-trips a chat request body", function()
    local body = Json.encode({
      model = "gpt-oss:20b",
      stream = false,
      think = "low",
      messages = { { role = "user", content = "hello" } },
      options = { temperature = 0.7, num_predict = 400 },
    })
    local back = Json.decode(body)
    t.eq(back.model, "gpt-oss:20b")
    t.eq(back.stream, false)
    t.eq(back.think, "low")
    t.eq(back.messages[1].content, "hello")
    t.eq(back.options.num_predict, 400)
  end)

  t.it("decodes a real assistant reply", function()
    local obj = Json.decode(REPLY)
    t.eq(obj.message.role, "assistant")
    t.has(obj.message.content, "drifting off course")
    t.has(obj.message.thinking, '"SIR"', "escaped quotes survive decoding")
    t.eq(obj.done_reason, "stop")
    t.eq(obj.eval_count, 58)
  end)

  t.it("decodes tool_calls with an object of arguments", function()
    local obj = Json.decode(TOOLCALL)
    local calls = obj.message.tool_calls
    t.eq(#calls, 1)
    t.eq(calls[1]["function"].name, "fleet_command")
    t.eq(calls[1]["function"].arguments.command, "return_home")
  end)

  t.it("re-encodes an assistant message so it can be echoed back as context", function()
    local msg = Json.decode(TOOLCALL).message
    local again = Json.decode(Json.encode(msg))
    t.eq(again.role, "assistant")
    t.eq(again.tool_calls[1]["function"].name, "fleet_command")
    t.eq(again.tool_calls[1]["function"].arguments.command, "return_home")
  end)

  t.it("decodes escapes and unicode", function()
    t.eq(Json.decode([["a\/b"]]), "a/b")
    t.eq(Json.decode([["AB"]]), "AB")
    t.eq(Json.decode("null"), nil)
    t.eq(Json.decode("[1,2]")[2], 2)
  end)

  t.it("returns nil for junk instead of throwing", function()
    t.eq(Json.decode("not json at all"), nil)
    t.eq(Json.decode(""), nil)
    t.eq(Json.decode("{unclosed"), nil)
  end)
end
