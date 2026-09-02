-- .env parsing: the file shape people actually write.
local Env = require("src.env")

return function(t)
  t.describe("env")

  t.it("reads export, quotes and comments", function()
    Env.load("tests/fixtures/env_sample")
    t.eq(Env.get("OLLAMA_API_KEY"), "abc123", "export prefix is stripped")
    t.eq(Env.get("OLLAMA_MODEL"), "gpt-oss:20b", "double quotes are stripped")
    t.eq(Env.get("OLLAMA_HOST"), "https://ollama.com", "spaces around = and single quotes")
    t.eq(Env.get("OLLAMA_THINK"), "low", "trailing comment is dropped")
  end)

  t.it("keeps a # that lives inside quotes", function()
    Env.load("tests/fixtures/env_sample")
    t.eq(Env.get("QUOTED_HASH"), "value # not a comment")
  end)

  t.it("falls back when a key is empty or missing", function()
    Env.load("tests/fixtures/env_sample")
    t.eq(Env.get("EMPTY", "fallback"), "fallback", "an empty value is not a value")
    t.eq(Env.get("NO_SUCH_KEY", "fallback"), "fallback")
    t.eq(Env.get("NO_SUCH_KEY"), nil)
  end)

  t.it("survives a missing file", function()
    Env.load("tests/fixtures/does_not_exist")
    t.eq(Env.get("OLLAMA_MODEL", "default"), os.getenv("OLLAMA_MODEL") or "default",
      "with no file it falls through to the process environment")
  end)

  t.it("restores the real .env for the suites that follow", function()
    Env.load()
    t.ok(true)
  end)
end
