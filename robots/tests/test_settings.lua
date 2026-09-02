-- The settings page's AI tab: the drafts it builds from a `config` reply and
-- the payload it sends back. Pure, so no window and no daemon are needed.
local Settings = require("src.settings")

return function(F)
  F.describe("settings / the AI setup")

  local reply = {
    setup = {
      ["ondevice.engine"] = { value = "auto", source = "default", set = true },
      ["ondevice.host"] = { value = "http://localhost:11434", source = "default", set = true },
      ["ondevice.model"] = { value = "qwen3.8:27b-mlx", source = "dotenv", set = true },
      ["ondevice.embed"] = { value = "embeddinggemma", source = "default", set = true },
      ["cloud.host"] = { value = "https://ollama.com", source = "default", set = true },
      ["cloud.key"] = { value = "********cdef", source = "env", set = true, secret = true },
      ["cloud.model"] = { value = "gpt-oss:20b", source = "space", set = true },
      ["cloud.embed"] = { value = "embeddinggemma", source = "default", set = true },
      ["think"] = { value = "high", source = "space", set = true },
    },
  }

  F.it("fills the drafts from a config reply, but never the secret", function()
    Settings.loadAI(reply, "")
    F.eq(Settings.ai.draft.od_host, "http://localhost:11434")
    F.eq(Settings.ai.draft.od_model, "qwen3.8:27b-mlx")
    F.eq(Settings.ai.draft.cloud_model, "gpt-oss:20b")
    F.eq(Settings.ai.draft.cloud_key, "")
    F.eq(Settings.ai.engine, "auto")
    F.eq(Settings.ai.think, "high")
    F.eq(Settings.ai.dirty, false)
  end)

  F.it("preloads the key from .env, and sends it back only when edited", function()
    Settings.loadAI(reply, "sk-from-dotenv")
    F.eq(Settings.ai.draft.cloud_key, "sk-from-dotenv")
    F.eq(Settings.ai.keyOrigin, "sk-from-dotenv")
    -- Untouched: the .env value is not copied into the space.
    F.eq(Settings.aiValues()["cloud.key"], nil)
    -- Edited: it is.
    Settings.ai.draft.cloud_key = "sk-from-dotenv-2"
    F.eq(Settings.aiValues()["cloud.key"], "sk-from-dotenv-2")
    -- Cleared: a blank goes, whatever .env says.
    Settings.ai.clearKey = true
    Settings.ai.draft.cloud_key = ""
    F.eq(Settings.aiValues()["cloud.key"], "")
  end)

  F.it("sends every value but only a key that was typed", function()
    Settings.loadAI(reply, "")
    Settings.ai.engine = "ollama"
    Settings.ai.draft.od_model = "qwen3.8:8b"
    local values = Settings.aiValues()
    F.eq(values["ondevice.engine"], "ollama")
    F.eq(values["ondevice.model"], "qwen3.8:8b")
    F.eq(values["cloud.host"], "https://ollama.com")
    F.eq(values["think"], "high")
    F.eq(values["cloud.key"], nil)

    Settings.ai.draft.cloud_key = "sk-new"
    F.eq(Settings.aiValues()["cloud.key"], "sk-new")

    -- CLEAR sends a blank on purpose, which is the one way to persist "none".
    Settings.ai.clearKey = true
    Settings.ai.draft.cloud_key = ""
    F.eq(Settings.aiValues()["cloud.key"], "")
  end)

  F.it("says in one word who answers the next prompt", function()
    local h = Settings.answering(nil)
    F.has(h, "ASKING")
    h = Settings.answering({ effective = "ondevice",
      ondevice = { engine = "ollama", model = "qwen3.8:27b-mlx", host = "http://localhost:11434" } })
    F.eq(h, "ON-DEVICE")
    local _, d = Settings.answering({ effective = "ondevice",
      ondevice = { engine = "ollama", model = "qwen3.8:27b-mlx", host = "http://localhost:11434" } })
    F.has(d, "OLLAMA DAEMON")
    F.has(d, "NOTHING LEAVES")
    _, d = Settings.answering({ effective = "ondevice", ondevice = { engine = "mlx", model = "qwen3.8:27b-mlx" } })
    F.has(d, "MLX ENGINE")
    h, d = Settings.answering({ effective = "cloud", cloud = { model = "gpt-oss:20b", host = "https://ollama.com" } })
    F.eq(h, "CLOUD")
    F.has(d, "PROMPTS LEAVE")
    h, d = Settings.answering({ effective = "offline", why = "no key" })
    F.eq(h, "NOBODY")
    F.has(d, "NO KEY")
  end)

  F.it("survives an empty reply", function()
    Settings.loadAI(nil, "")
    F.eq(Settings.ai.draft.od_host, "")
    F.eq(Settings.ai.engine, "auto")
    F.eq(Settings.aiValues()["ondevice.engine"], "auto")
  end)
end
