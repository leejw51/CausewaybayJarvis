-- The bridge to agentd: what it does with a reply, and where it looks for the
-- binary. No subprocess here -- tests/test_agentd.lua runs the real one.

local Backend = require("src.backend")

--- The first report row whose text carries `needle`, or a row that says so.
local function row(report, needle)
  for _, r in ipairs(report or {}) do
    if tostring(r.text):find(needle, 1, true) then return r end
  end
  return { text = "no line matching " .. needle, tone = "?" }
end

local function line(report, needle)
  return row(report, needle).text
end

return function(F)
  F.describe("backend / replies")

  local parse = Backend._test.parse

  F.it("reads a successful reply", function()
    local data, err = parse('{"ok":true,"op":"health","data":{"online":false}}')
    F.eq(err, nil)
    F.eq(data.online, false)
  end)

  F.it("turns a refusal into a sentence, not a crash", function()
    local data, err = parse('{"ok":false,"op":"page","error":"no robot \\"ghost\\""}')
    F.eq(data, nil)
    F.has(err, "NO ROBOT")
  end)

  F.it("takes the last line, so a warning cannot eat the answer", function()
    local data = parse('warming up\n{"ok":true,"data":{"n":7}}\n')
    F.eq(data.n, 7)
  end)

  F.it("says so when agentd printed nothing at all", function()
    local _, err = parse("")
    F.has(err, "SAID NOTHING")
    local _, err2 = parse("   \n\n")
    F.has(err2, "SAID NOTHING")
  end)

  F.it("says so when agentd printed something that is not the protocol", function()
    local _, err = parse("dyld: Library not loaded\n")
    F.has(err, "BAD REPLY")
  end)

  F.describe("backend / finding the binary")

  F.it("prefers the engine build, then release, then debug, then PATH", function()
    local list = Backend._test.candidates()
    local mlx, release, debug
    for i, path in ipairs(list) do
      if not mlx and path:find("release/agentd-mlx", 1, true) then mlx = i end
      if not release and path:find("release/agentd", 1, true) and not path:find("mlx", 1, true) then release = i end
      if not debug and path:find("debug/agentd", 1, true) then debug = i end
    end
    F.ok(mlx, "no engine-carrying path among the candidates")
    F.ok(release, "no release path among the candidates")
    F.ok(debug, "no debug path among the candidates")
    F.ok(mlx < release, "a lean rebuild could strip the engine")
    F.ok(release < debug, "the debug build would win")
    F.eq(list[#list], "agentd", "PATH is the last resort")
  end)

  F.it("an explicit override is the answer, right or wrong", function()
    -- Cannot set the environment from Lua, so this checks the shape instead:
    -- the override is not one candidate among many.
    for _, path in ipairs(Backend._test.candidates()) do
      F.lacks(path, "JARVIS_AGENTD")
    end
    F.eq(Backend.find and type(Backend.find), "function")
  end)

  F.describe("backend / the provider ring")

  F.it("cycles auto, on-device, cloud, and home again", function()
    F.eq(Backend.nextProvider("auto"), "ondevice")
    F.eq(Backend.nextProvider("ondevice"), "cloud")
    F.eq(Backend.nextProvider("cloud"), "auto")
    F.eq(Backend.nextProvider("garbage"), "auto", "an unknown state restarts the ring")
  end)

  F.it("the label shows the wish, and the outcome when they differ", function()
    local was = Backend.provider
    Backend.provider = nil
    F.eq(Backend.providerLabel(), "AI ...")
    Backend.provider = { current = "ondevice", effective = "ondevice" }
    F.eq(Backend.providerLabel(), "AI ON-DEVICE")
    F.eq(Backend.providerShort(), "AI ON-DEV")
    F.eq(Backend.providerTone(), "good")
    Backend.provider = { current = "auto", effective = "cloud" }
    F.eq(Backend.providerLabel(), "AI CLOUD (AUTO)")
    F.eq(Backend.providerShort(), "AI CLOUD (AUTO)")
    F.eq(Backend.providerTone(), "info")
    Backend.provider = { current = "cloud", effective = "offline" }
    F.eq(Backend.providerLabel(), "AI OFFLINE (CLOUD REFUSED)")
    F.eq(Backend.providerShort(), "AI OFFLINE (NO CLOUD)")
    F.eq(Backend.providerTone(), "warn")
    Backend.provider = was
  end)

  -- The button on the rail is this label. Pressing it walks the ring, and
  -- the first step — auto to on-device — does not change which brain
  -- answers: auto had already chosen it. So a label built only from the
  -- outcome does not move when the button is pressed, which is
  -- indistinguishable from a button that does nothing. Every step has to
  -- show.
  F.it("changes at every step of the ring, including the ones that pick the same brain", function()
    local was = Backend.provider
    local seen, order = {}, {}
    local current = "auto"
    for _ = 1, 3 do
      -- On a machine where on-device can answer, auto and ondevice both
      -- resolve to on-device: the case that used to look broken.
      local effective = (current == "cloud") and "cloud" or "ondevice"
      Backend.provider = { current = current, effective = effective }
      local short = Backend.providerShort()
      F.ok(not seen[short],
        "pressing the button did not change the label: " .. short)
      seen[short] = true
      order[#order + 1] = short
      current = Backend.nextProvider(current)
    end
    F.eq(current, "auto", "the ring did not come back round")
    F.eq(#order, 3)
    Backend.provider = was
  end)

  F.it("names the daemon when it, not MLX, is the on-device engine", function()
    F.eq(Backend.ondeviceLabel({ ondevice = { model = "qwen3.8:27b-mlx", engine = "mlx" } }),
      "QWEN3.8:27B-MLX")
    F.eq(Backend.ondeviceLabel({ ondevice = { model = "qwen3.8:27b-mlx", engine = "ollama" } }),
      "QWEN3.8:27B-MLX VIA OLLAMA")
    F.eq(Backend.ondeviceLabel({}), "?")
  end)

  F.describe("backend / timeouts")

  F.it("a turn gets room the bookkeeping never needs", function()
    local t = Backend._test.timeoutFor
    F.ok(t("chat") >= 600, "a first on-device turn pays the model load")
    F.ok(t("stats") <= 60)
    F.ok(t("agents.list") <= 60)
  end)

  F.describe("backend / the boot report")

  F.it("says why the archive is shut rather than staying silent", function()
    local was, reason = Backend.ready, Backend.reason
    Backend.ready, Backend.reason = false, "AGENTD NOT BUILT"
    local report = Backend.report()
    F.eq(#report, 1)
    F.has(report[1].text, "AGENTD NOT BUILT")
    F.eq(report[1].tone, "warn")
    Backend.ready, Backend.reason = was, reason
  end)

  F.it("passes the model report through once health has answered", function()
    local was, health = Backend.ready, Backend.health
    Backend.ready = true
    Backend.health = {
      root = "~/.causewaybayjarvis",
      provider = { current = "auto", effective = "cloud", cloud = { model = "gpt-oss:20b" } },
      report = { { text = "CLOUD AI  OLLAMA.COM", tone = "info" } },
      embed_fallback = "unauthorized",
    }
    local report = Backend.report()
    -- By content, not by position: the report gains lines over time (the
    -- transport, the model load) and a test that pins row numbers breaks
    -- on every one of them without ever being about them.
    F.has(line(report, "CAUSEWAYBAYJARVIS"), "CAUSEWAYBAYJARVIS")
    F.has(line(report, "AGENT BRAIN"), "AGENT BRAIN  CLOUD")
    F.has(line(report, "CLOUD AI"), "CLOUD AI")
    F.has(line(report, "FELL BACK"), "FELL BACK")

    -- The same cloud lines are left out when the brain is on-device: the
    -- caution that prompts leave the machine would be false.
    Backend.health.provider = { current = "auto", effective = "ondevice",
      ondevice = { engine = "ollama", model = "qwen3.8:27b-mlx" } }
    report = Backend.report()
    for _, line in ipairs(report) do
      F.lacks(line.text, "CLOUD AI")
    end
    Backend.ready, Backend.health = was, health
  end)

  F.it("says which engine is behind an on-device brain", function()
    local was, health = Backend.ready, Backend.health
    Backend.ready = true
    Backend.health = {
      root = "~/.causewaybayjarvis",
      provider = {
        current = "auto", effective = "ondevice",
        ondevice = { ready = true, engine = "ollama", model = "qwen3.8:27b-mlx",
                     host = "http://localhost:11434" },
      },
    }
    local report = Backend.report()
    local brain = row(report, "AGENT BRAIN")
    F.has(brain.text, "ON-DEVICE")
    F.has(brain.text, "VIA OLLAMA")
    F.eq(brain.tone, "good")
    Backend.ready, Backend.health = was, health
  end)
end
