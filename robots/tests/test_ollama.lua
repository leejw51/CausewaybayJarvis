-- Reply parsing, model-spec formatting and the on-device/cloud call, all
-- checked against bodies captured from the real ollama.com API.
local Ollama = require("src.ollama")
local I = Ollama._test

local NORMAL = [[{"message":{"role":"assistant","content":"Unit 12 is drifting, sir."},"done_reason":"stop"}]]
local TOOLCALL = [[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","function":{"name":"get_time","arguments":{"zone":"UTC"}}}]},"done_reason":"stop"}]]
-- what a too-small num_predict actually returns: all budget spent thinking
local TRUNCATED = [[{"message":{"role":"assistant","content":"","thinking":"We need to reply in at most two sentences and address"},"done":true,"done_reason":"length","eval_count":24}]]
local ERRORED = [[{"error":"model \"nope:1b\" not found"}]]
local SHOW = [[{"capabilities":["completion","tools","thinking"],"details":{"parent_model":"gpt-oss:20b","family":"gptoss","parameter_size":"20914757184","quantization_level":"MXFP4"},"model_info":{"general.architecture":"gptoss","general.parameter_count":20914757184,"gptoss.context_length":131072},"modified_at":"2025-08-05T00:00:00Z"}]]
local TAGS = [[{"models":[{"name":"gpt-oss:120b","size":65290180781,"digest":"d98fe6ba01e6"},{"name":"gpt-oss:20b","model":"gpt-oss:20b","modified_at":"2025-08-05T00:00:00Z","size":13780162412,"digest":"05afbac4bad6"}]}]]

return function(t)
  t.describe("ollama")

  t.it("reads OLLAMA_THINK as a reasoning level", function()
    t.eq(I.parseThink("low"), "low")
    t.eq(I.parseThink("HIGH"), "high")
    t.eq(I.parseThink(" medium "), "medium")
    t.eq(I.parseThink(nil), "low", "unset means the default level")
    t.eq(I.parseThink(""), "low")
    t.eq(I.parseThink("off"), false)
    t.eq(I.parseThink("false"), false)
    t.eq(I.parseThink("nonsense"), false)
  end)

  t.it("tells on-device apart from a cloud relay", function()
    local cloud, where = I.classify("https://ollama.com", "gpt-oss:20b")
    t.eq(cloud, true)
    t.eq(where, "CLOUD AI")

    cloud, where = I.classify("http://localhost:11434", "qwen3:8b")
    t.eq(cloud, false, "weights on this machine")
    t.eq(where, "ON-DEVICE")

    cloud, where = I.classify("http://127.0.0.1:11434", "llama3:8b")
    t.eq(cloud, false)

    -- a local daemon can still proxy the cloud, and those tags say so
    cloud, where = I.classify("http://localhost:11434", "gpt-oss:120b-cloud")
    t.eq(cloud, true, "a -cloud tag leaves the machine even via localhost")
    t.eq(where, "CLOUD RELAY")
  end)

  t.it("formats parameter counts, weights and context", function()
    t.eq(I.fmtParams(20914757184), "20.9B")
    t.eq(I.fmtParams("20914757184"), "20.9B", "the cloud sends this as a string")
    t.eq(I.fmtParams(8000000), "8M")
    t.eq(I.fmtParams("20.9B"), "20.9B", "a local daemon sends it pre-formatted")
    t.eq(I.fmtBytes(13780162412), "12.8 GB")
    t.eq(I.fmtBytes(0), nil)
    t.eq(I.fmtCtx(131072), "128K")
    t.eq(I.fmtCtx(nil), nil)
  end)

  t.it("parses a normal reply", function()
    local text, err = I.parse(NORMAL)
    t.eq(err, nil)
    t.has(text, "drifting")
  end)

  t.it("treats tool_calls as a valid empty answer, not a failure", function()
    local text, err, retryable, msg = I.parse(TOOLCALL)
    t.eq(err, nil, "empty content plus tool_calls is the model asking to act")
    t.eq(text, "")
    t.eq(retryable, false)
    t.eq(msg.tool_calls[1]["function"].name, "get_time")
  end)

  t.it("flags a reply that spent its whole budget thinking as retryable", function()
    local text, err, retryable = I.parse(TRUNCATED)
    t.eq(text, nil)
    t.has(err, "REASONING OVERRAN")
    t.eq(retryable, true, "this is what triggers the no-thinking retry")
  end)

  t.it("surfaces API errors and junk", function()
    local _, err = I.parse(ERRORED)
    t.has(err, "not found")
    local _, err2 = I.parse("<html>502</html>")
    t.has(err2, "BAD REPLY")
    local _, err3 = I.parse("   ")
    t.has(err3, "EMPTY REPLY")
  end)

  t.it("reads specs out of /api/show and /api/tags", function()
    local saveModel, saveInfo = Ollama.model, Ollama.info
    Ollama.model = "gpt-oss:20b"
    Ollama.info = { name = Ollama.model }
    I.readShow(I.decode(SHOW))
    I.readTags(I.decode(TAGS))
    local i = Ollama.info
    t.eq(i.params, "20.9B")
    t.eq(i.quant, "MXFP4")
    t.eq(i.ctx, "128K")
    t.eq(i.size, "12.8 GB", "the size comes from the tag, not the show")
    t.eq(i.built, "2025-08-05")
    t.eq(i.build, "05AFBAC4")
    t.eq(i.thinks, true)
    Ollama.model, Ollama.info = saveModel, saveInfo
  end)

  t.it("rides the agent brain whenever the backend has one", function()
    local Backend = require("src.backend")
    local wasReady, wasProvider = Backend.ready, Backend.provider
    Backend.ready, Backend.provider = true, {
      current = "auto", effective = "ondevice",
      ondevice = { engine = "ollama", model = "qwen3.8:27b-mlx" },
    }
    t.ok(Ollama.viaBackend(), "an on-device brain routes the console")
    t.ok(Ollama.available())
    local st = Ollama.status()
    t.eq(st.via, "agentd")
    t.eq(st.cloud, false)
    t.eq(st.where, "ON-DEVICE (OLLAMA)")
    t.eq(st.model, "qwen3.8:27b-mlx")
    local rows = Ollama.report()
    t.ok(rows[1].text:find("AGENT BRAIN", 1, true), "the boot panel says which road")
    t.eq(rows[2].tone, "good")

    Backend.provider = { current = "cloud", effective = "cloud", cloud = { model = "gpt-oss:20b" } }
    st = Ollama.status()
    t.eq(st.cloud, true)
    t.eq(st.where, "CLOUD AI")
    rows = Ollama.report()
    t.ok(rows[#rows].text:find("LEAVE THIS MACHINE", 1, true), "the cloud still carries its caution")

    -- Nothing can answer on the backend: back to the .env link, whatever it is.
    Backend.provider = { current = "auto", effective = "offline", why = "no key" }
    t.eq(Ollama.viaBackend(), false)
    t.eq(Ollama.status().via, "curl")
    Backend.ready, Backend.provider = wasReady, wasProvider
  end)

  t.it("reports a cloud link with the privacy caution", function()
    local save = { Ollama.enabled, Ollama.cloud, Ollama.where, Ollama.host, Ollama.model, Ollama.info }
    Ollama.enabled, Ollama.cloud, Ollama.where = true, true, "CLOUD AI"
    Ollama.host, Ollama.model = "https://ollama.com", "gpt-oss:20b"
    Ollama.info = { params = "20.9B", quant = "MXFP4", size = "12.8 GB", ctx = "128K", built = "2025-08-05" }

    local rows = Ollama.report()
    local all = ""
    for _, r in ipairs(rows) do all = all .. r.text .. "\n" end
    t.has(all, "CLOUD AI", "the operator is told where it runs")
    t.has(all, "OLLAMA.COM")
    t.has(all, "GPT-OSS:20B", "which model")
    t.has(all, "20.9B")
    t.has(all, "12.8 GB", "how big it is")
    t.has(all, "128K")
    t.has(all, "PROMPTS LEAVE THIS MACHINE", "cloud gets the warning")
    t.has(all, "KEEP PRIVATE DATA OFF THE LINK")
    t.eq(rows[#rows].tone, "warn", "the caution is styled as a warning")

    Ollama.enabled, Ollama.cloud, Ollama.where = save[1], save[2], save[3]
    Ollama.host, Ollama.model, Ollama.info = save[4], save[5], save[6]
  end)

  t.it("reports an on-device link with no warning", function()
    local save = { Ollama.enabled, Ollama.cloud, Ollama.where, Ollama.host, Ollama.model, Ollama.info }
    Ollama.enabled, Ollama.cloud, Ollama.where = true, false, "ON-DEVICE"
    Ollama.host, Ollama.model = "http://localhost:11434", "qwen3:8b"
    Ollama.info = { params = "8.0B" }

    local rows = Ollama.report()
    local all = ""
    for _, r in ipairs(rows) do all = all .. r.text .. "\n" end
    t.has(all, "ON-DEVICE")
    t.has(all, "LOCALHOST:11434")
    t.has(all, "QWEN3:8B")
    t.lacks(all, "PROMPTS LEAVE THIS MACHINE", "nothing leaves the box, so no caution")
    t.eq(rows[1].tone, "good")

    Ollama.enabled, Ollama.cloud, Ollama.where = save[1], save[2], save[3]
    Ollama.host, Ollama.model, Ollama.info = save[4], save[5], save[6]
  end)

  t.it("reports the reason when the link is off", function()
    local save = { Ollama.enabled, Ollama.reason }
    Ollama.enabled, Ollama.reason = false, "NO OLLAMA_API_KEY IN .ENV"
    local rows = Ollama.report()
    t.has(rows[1].text, "OFFLINE")
    t.has(rows[1].text, "NO OLLAMA_API_KEY")
    t.eq(rows[1].tone, "warn")
    Ollama.enabled, Ollama.reason = save[1], save[2]
  end)

  t.it("refuses to ask when the link is down", function()
    local save = Ollama.enabled
    Ollama.enabled = false
    local ok, why = Ollama.ask({ { role = "user", content = "hi" } }, function() end)
    t.eq(ok, false)
    t.ok(why, "the caller gets a reason to show")
    Ollama.enabled = save
  end)
end
