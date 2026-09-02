-- Real round trips to the configured Ollama host. Opt-in, because it costs
-- tokens and needs the network: `make test-live`.
local Ollama = require("src.ollama")
local Chat = require("src.chat")
local Tools = require("src.tools")
local Fleet = require("src.fleet")
local World = require("src.world")
local Central = require("src.central")
local Agents = require("src.agents")

local TIMEOUT = 90

local function reset()
  if not World.ready then World.build() end
  Fleet.spawn()
  Fleet.setFilter(0)
  Central.reset()
  for _, u in ipairs(Fleet.units) do u.online = true end
  Agents.activateAll()
  Chat.reset()
end

-- Pumps the module the way love.update would, until done() or the deadline.
local function pump(done)
  local t0 = os.time()
  while os.time() - t0 < TIMEOUT do
    Ollama.update(0.05)
    Chat.update(0.05)
    if done() then return true end
    love.timer.sleep(0.05)
  end
  return false
end

local function execLines()
  local out = {}
  for _, ln in ipairs(Chat.lines) do
    if ln.who == "EXEC" then out[#out + 1] = ln.text end
  end
  return out
end

local function homeCount()
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if u.destY == u.homeY then n = n + 1 end
  end
  return n
end

return function(t)
  t.describe("live / " .. tostring(Ollama.model))

  if os.getenv("JARVIS_TEST_LIVE") ~= "1" then
    t.skip("live API round trips", "set JARVIS_TEST_LIVE=1, or run make test-live")
    return
  end

  -- the test runner never boots the game, so bring the link up here
  if not Ollama.enabled then Ollama.init() end
  if not Ollama.enabled then
    t.skip("live API round trips", Ollama.reason)
    return
  end

  t.it("probes the model specs", function()
    Ollama.askSpecs()
    t.ok(pump(function() return Ollama.probe == "done" end), "the spec probe answered")
    local i = Ollama.info or {}
    t.ok(i.params or i.size, "the host reported parameters or a weight size")
  end)

  t.it("answers a plain question in console-safe text", function()
    reset()
    Chat.ask("say READY and nothing else", Agents.list[1], nil)
    t.ok(pump(function() return Chat.typing ~= nil or #Chat.lines > 0 end), "a reply arrived")
    local said = (Chat.typing and Chat.typing.full) or ""
    t.ok(#said > 0, "the reply is not empty")
    t.eq(said, said:upper())
  end)

  t.it("calls a tool when the operator gives an order", function()
    reset()
    Fleet.command("rally")
    t.eq(homeCount(), 0)

    Chat.ask("send every drone home now", Agents.list[1], nil)
    local ok = pump(function() return #execLines() > 0 and not Ollama.busy() end)
    t.ok(ok, "the model called a tool")
    local exec = table.concat(execLines(), " | ")
    t.has(exec, "FLEET", "it reached for a fleet tool: " .. exec)
    t.ok(homeCount() > 0, "the swarm actually moved")
  end)

  t.it("reads the clock through the tool rather than guessing", function()
    reset()
    Chat.ask("what is the exact time in UTC right now", Agents.list[1], nil)
    t.ok(pump(function() return #execLines() > 0 and not Ollama.busy() end), "the model called a tool")
    t.has(table.concat(execLines(), " | "), "GET_TIME")
  end)

  t.it("recovers when a reply spends its whole budget thinking", function()
    -- 24 tokens is not enough for gpt-oss to think and speak, so this is the
    -- path that used to come back empty; the retry should rescue it.
    local done, text = false, nil
    Ollama.ask({
      { role = "system", content = "You are a terse assistant. Answer in one short sentence." },
      { role = "user", content = "name one colour" },
    }, function(reply) text, done = reply, true end, { numPredict = 24 })
    t.ok(pump(function() return done end), "the call finished")
    t.ok(text and #text > 0, "a retry produced real content instead of an empty message")
  end)
end
