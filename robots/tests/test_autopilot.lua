-- The idle timer and the hand-over: who has the helm, and what the house
-- does with it when the operator walks away.
local Autopilot = require("src.autopilot")
local Chat = require("src.chat")
local Ollama = require("src.ollama")
local Fleet = require("src.fleet")
local World = require("src.world")
local Central = require("src.central")
local Agents = require("src.agents")

local function reset()
  love.math.setRandomSeed(20260901)
  if not World.ready then World.build() end
  Fleet.spawn()
  Fleet.setFilter(0)
  Central.reset()
  for _, u in ipairs(Fleet.units) do u.online = true end
  Agents.activateAll()
  Chat.reset()
  Autopilot.reset()
  Autopilot.enabled = true
  Autopilot.timeout = 60
end

-- run the clock with nobody touching anything
local function quiet(seconds, step)
  step = step or 0.5
  for _ = 1, math.ceil(seconds / step) do
    Autopilot.update(step, false)
    Chat.update(step)
  end
end

return function(t)
  t.describe("autopilot / timer")

  local realAsk, realEnabled = Ollama.ask, Ollama.enabled

  t.it("counts a minute down before it takes over", function()
    reset()
    Ollama.enabled = false
    t.eq(Autopilot.remaining(), 60)
    t.eq(Autopilot.label(), "AUTO 1:00")

    quiet(13)
    t.eq(Autopilot.active, false, "still the operator's console")
    t.near(Autopilot.remaining(), 47, 1)
    t.eq(Autopilot.label(), "AUTO 0:47")
  end)

  t.it("takes the helm when the minute runs out", function()
    reset()
    Ollama.enabled = false
    quiet(59)
    t.eq(Autopilot.active, false, "not a second early")
    quiet(2)
    t.eq(Autopilot.active, true)
    t.eq(Autopilot.label(), "AUTOPILOT")
  end)

  t.it("hands control straight back on any touch", function()
    reset()
    Ollama.enabled = false
    quiet(61)
    t.eq(Autopilot.active, true)

    Autopilot.update(0.016, true)
    t.eq(Autopilot.active, false, "a keypress ends it at once")
    t.eq(Autopilot.remaining(), 60, "and the countdown starts over")
  end)

  t.it("can be disarmed, and then never fires", function()
    reset()
    Ollama.enabled = false
    Autopilot.toggle()
    t.eq(Autopilot.enabled, false)
    t.eq(Autopilot.label(), "AUTO OFF")
    quiet(120)
    t.eq(Autopilot.active, false, "a disarmed helm stays with the operator")
    Autopilot.toggle()
    t.eq(Autopilot.enabled, true)
  end)

  t.it("respects a custom timeout from the environment", function()
    reset()
    Ollama.enabled = false
    Autopilot.timeout = 10
    quiet(11)
    t.eq(Autopilot.active, true)
  end)

  t.describe("autopilot / the watch")

  t.it("moves the swarm on its own, offline", function()
    reset()
    Ollama.enabled = false
    quiet(61)
    local before = Fleet.units[1].destY
    quiet(120)
    t.ok(Autopilot.moves > 1, "it kept working the console, " .. Autopilot.moves .. " moves")
    t.ok(#Autopilot.recent > 0, "and remembers what it did")
    local moved = false
    for _, u in ipairs(Fleet.units) do
      if u.destY ~= before then moved = true break end
    end
    t.ok(moved, "the swarm actually went somewhere")
  end)

  t.it("never repeats itself twice in a row", function()
    reset()
    Ollama.enabled = false
    quiet(61)
    quiet(600)
    for i = 2, #Autopilot.recent do
      t.ok(Autopilot.recent[i] ~= Autopilot.recent[i - 1],
        "back-to-back " .. tostring(Autopilot.recent[i]) .. " reads like a stuck script")
    end
  end)

  t.it("keeps a human rhythm: idle most of the time, with the odd summon", function()
    reset()
    Ollama.enabled = false
    local seen = {}
    for _ = 1, 40 do
      local id = Autopilot.pick()
      seen[id] = (seen[id] or 0) + 1
      Autopilot.recent[#Autopilot.recent + 1] = id
      while #Autopilot.recent > 4 do table.remove(Autopilot.recent, 1) end
    end
    t.ok((seen.idle or 0) > 0, "it lets them idle")
    local kinds = 0
    for _ in pairs(seen) do kinds = kinds + 1 end
    t.ok(kinds >= 4, "and mixes in other moves, saw " .. kinds .. " kinds")
  end)

  t.describe("autopilot / with the model")

  t.it("asks the model, with the state as context", function()
    reset()
    local calls = {}
    Ollama.enabled = true
    Ollama.ask = function(messages, cb, opts)
      calls[#calls + 1] = messages
      cb("THE SWARM RESTS, SIR.", nil, nil)
      return true
    end

    quiet(62)
    t.eq(Autopilot.active, true)
    t.ok(#calls > 0, "it put the question to JARVIS")

    local asked = calls[1][#calls[1]].content
    t.has(asked, "have the helm")
    t.has(asked, "operator has been away", "it says how long you have been gone")
    t.has(asked, "Local time", "and what time it is")
    t.has(asked, "units online", "and what the swarm is doing")
    t.has(asked, "first move of the watch")
  end)

  t.it("records the move the model actually made", function()
    reset()
    Ollama.enabled = true
    Ollama.ask = function(messages, cb, opts)
      cb("", nil, {
        role = "assistant",
        tool_calls = { { ["function"] = { name = "fleet_command", arguments = { command = "idle" } } } },
      })
      return true
    end

    quiet(62)
    t.eq(Autopilot.recent[#Autopilot.recent], "idle", "the tool it ran is what goes in the log")
    t.eq(Fleet.units[1].idle, true, "and the swarm followed the order")

    -- the next question carries the move it just made
    Ollama.ask = function(messages, cb)
      cb("NOTED, SIR.", nil, nil)
      return true
    end
    quiet(40)
    t.eq(Autopilot.active, true)
  end)

  t.it("waits for a reply instead of talking over it", function()
    reset()
    Ollama.enabled = true
    local calls = 0
    Ollama.ask = function(messages, cb) calls = calls + 1 return true end  -- never answers

    quiet(62)
    t.eq(calls, 1, "one question in flight")
    quiet(120)
    t.eq(calls, 1, "it does not pile more on while the first is unanswered")
  end)

  t.it("restores the real link for the suites that follow", function()
    Ollama.ask, Ollama.enabled = realAsk, realEnabled
    Autopilot.reset()
    Chat.reset()
    t.eq(Ollama.ask, realAsk)
  end)
end
