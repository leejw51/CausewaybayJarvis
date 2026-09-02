-- The tool ladder, driven by a stubbed link so it runs offline: the model's
-- tool_calls must reach the fleet, and the results must reach the model.
local Chat = require("src.chat")
local Ollama = require("src.ollama")
local Tools = require("src.tools")
local Fleet = require("src.fleet")
local World = require("src.world")
local Central = require("src.central")
local Agents = require("src.agents")

local realAsk, realEnabled

local function reset()
  -- idle life, scatter and flight jitter all draw from love.math; seed it so
  -- a behaviour test cannot pass or fail by luck
  love.math.setRandomSeed(20260901)
  if not World.ready then World.build() end
  Fleet.spawn()
  Fleet.setFilter(0)
  Central.reset()
  for _, u in ipairs(Fleet.units) do u.online = true end
  Agents.activateAll()
  Chat.reset()
end

-- Answers the chat with a canned script instead of the network. Each entry
-- is { text, err, msg }; the last entry repeats if the ladder keeps going.
local function stub(script)
  local calls = {}
  Ollama.enabled = true
  Ollama.ask = function(messages, cb, opts)
    calls[#calls + 1] = { messages = messages, opts = opts }
    local step = script[math.min(#calls, #script)]
    cb(step.text, step.err, step.msg)
    return true
  end
  return calls
end

local function toolCall(name, args)
  return {
    role = "assistant",
    content = "",
    tool_calls = { { id = "call_test", ["function"] = { name = name, arguments = args } } },
  }
end

local function spoken()
  local parts = {}
  if Chat.typing then parts[#parts + 1] = Chat.typing.full end
  for _, q in ipairs(Chat.queue) do parts[#parts + 1] = q end
  return table.concat(parts, " ")
end

local function lineFrom(who)
  for i = #Chat.lines, 1, -1 do
    if Chat.lines[i].who == who then return Chat.lines[i].text end
  end
end

local function homeCount()
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if u.destY == u.homeY then n = n + 1 end
  end
  return n
end

return function(t)
  t.describe("chat / tool ladder")

  realAsk, realEnabled = Ollama.ask, Ollama.enabled

  t.it("sends the tool schema with every question", function()
    reset()
    local calls = stub({ { text = "NOTED, SIR." } })
    Chat.ask("how is the swarm holding up", Agents.list[1], nil)
    t.eq(#calls, 1)
    t.eq(calls[1].opts.tools, Tools.schema, "the model is offered the tools")
    local sys = calls[1].messages[1]
    t.eq(sys.role, "system")
    t.has(sys.content, "fleet_command", "the briefing names the tools")
    t.has(sys.content, "ROOF", "and the places units can go")
  end)

  t.it("turns a tool call into a real fleet movement", function()
    reset()
    Fleet.command("rally")
    t.eq(homeCount(), 0, "the swarm starts off station")

    local calls = stub({
      { text = "", msg = toolCall("fleet_command", { command = "home" }) },
      { text = "ALL UNITS HOMEBOUND, SIR." },
    })
    Chat.ask("bring everyone back to their flats", Agents.list[1], nil)

    t.eq(#calls, 2, "one round to act, one to speak")
    t.eq(homeCount(), Fleet.COUNT, "the order actually reached the fleet")
    t.has(spoken(), "HOMEBOUND", "and JARVIS reports it")
  end)

  t.it("feeds the tool result back as context", function()
    reset()
    local calls = stub({
      { text = "", msg = toolCall("get_time", { zone = "utc" }) },
      { text = "IT IS PAST MIDNIGHT, SIR." },
    })
    Chat.ask("what time is it in utc", Agents.list[1], nil)

    local msgs = calls[#calls].messages
    local assistant, tool
    for _, m in ipairs(msgs) do
      if m.role == "assistant" and m.tool_calls then assistant = m end
      if m.role == "tool" then tool = m end
    end
    t.ok(assistant, "the assistant turn that asked for the tool is echoed back")
    t.ok(tool, "the result is sent as a tool message")
    t.eq(tool.tool_name, "get_time")
    t.has(tool.content, "UTC", "the model gets the real clock reading")
  end)

  t.it("logs every executed call on the console", function()
    reset()
    stub({
      { text = "", msg = toolCall("move_unit", { unit = 12, place = "roof" }) },
      { text = "U0012 IS CLIMBING, SIR." },
    })
    Chat.ask("put unit 12 on the roof", Agents.list[1], nil)
    t.eq(lineFrom("EXEC"), "MOVE_UNIT 12 ROOF", "the operator sees the order that was issued")
    t.ok(Fleet.get(12).destY <= World.SKY + 8)
  end)

  t.it("runs several calls from one turn", function()
    reset()
    local msg = toolCall("fleet_command", { command = "home" })
    msg.tool_calls[2] = { ["function"] = { name = "get_time", arguments = { zone = "utc" } } }
    local calls = stub({ { text = "", msg = msg }, { text = "DONE AND NOTED, SIR." } })
    Chat.ask("send them home and give me the utc time", Agents.list[1], nil)

    local tools = 0
    for _, m in ipairs(calls[#calls].messages) do
      if m.role == "tool" then tools = tools + 1 end
    end
    t.eq(tools, 2, "both calls ran and both results went back")
    t.eq(homeCount(), Fleet.COUNT)
  end)

  t.it("stops climbing the ladder if the model never speaks", function()
    reset()
    local calls = stub({ { text = "", msg = toolCall("fleet_status", {}) } })
    Chat.ask("status status status", Agents.list[1], nil)
    t.eq(#calls, 4, "capped at four rounds instead of looping forever")
    t.has(spoken(), "UNITS", "the last tool result is read out rather than nothing")
  end)

  t.it("rejects a hallucinated tool without breaking the turn", function()
    reset()
    local calls = stub({
      { text = "", msg = toolCall("open_the_pod_bay_doors", {}) },
      { text = "I CANNOT DO THAT, SIR." },
    })
    Chat.ask("open the pod bay doors", Agents.list[1], nil)
    local last
    for _, m in ipairs(calls[#calls].messages) do
      if m.role == "tool" then last = m.content end
    end
    t.has(last, "REJECTED", "the model is told the tool does not exist")
    t.has(spoken(), "CANNOT")
  end)

  t.it("falls back to local central when the link fails", function()
    reset()
    stub({ { text = nil, err = "OLLAMA TIMED OUT" } })
    Chat.ask("anything at all", Agents.list[1], nil)
    t.has(lineFrom("LINK"), "TIMED OUT", "the failure is shown, not hidden")
    t.ok(#spoken() > 0, "central still answers")
  end)

  t.describe("chat / routing")

  t.it("runs a bare command word locally, without the model", function()
    reset()
    Fleet.command("rally")
    local calls = stub({ { text = "SHOULD NOT BE CALLED" } })
    Chat.interpret("home")
    t.eq(#calls, 0, "one word is a button press, not a conversation")
    t.eq(homeCount(), Fleet.COUNT)
  end)

  t.it("locks a unit typed as a number, without the model", function()
    reset()
    local calls = stub({ { text = "SHOULD NOT BE CALLED" } })
    Chat.interpret("u12")
    t.eq(#calls, 0)
    t.ok(Fleet.selected and Fleet.selected.id == 12)
  end)

  t.it("hands a sentence to the model, which has the tools", function()
    reset()
    local calls = stub({
      { text = "", msg = toolCall("fleet_command", { command = "scatter" }) },
      { text = "SCATTERED, SIR." },
    })
    Chat.interpret("would you mind scattering the swarm across the tower")
    t.eq(#calls, 2, "a sentence goes to JARVIS")
    t.has(spoken(), "SCATTERED")
    t.ok(Chat.typing.who:match("AI$"), "nobody locked: the house AI answers (got " .. tostring(Chat.typing.who) .. ")")
  end)

  t.it("a locked unit answers in its own name", function()
    reset()
    local u = Fleet.get(12)
    Fleet.selected = u
    local calls = stub({ { text = "ON THE FLOOR, SIR." } })
    Chat.interpret("where are you")
    t.eq(#calls, 1)
    t.eq(Chat.typing.who, Agents.lookOf(u).name)
    t.has(calls[1].messages[1].content, Agents.lookOf(u).name)
  end)

  t.it("answers offline from central when the link is down", function()
    reset()
    Ollama.enabled = false
    local calls = stub({ { text = "SHOULD NOT BE CALLED" } })
    Ollama.enabled = false
    Chat.interpret("tell me something about the swarm tonight")
    t.eq(#calls, 0)
    t.ok(#spoken() > 0)
  end)

  t.describe("chat / console text")

  t.it("flattens model prose to the 8x8 uppercase ROM", function()
    reset()
    Chat.reply("**Unit 12** is drifting \226\128\148 re\226\128\145check its GPS lock.", Agents.list[1])
    local said = spoken()
    t.eq(said, said:upper(), "the console font has no lowercase")
    t.lacks(said, "*", "markdown is stripped")
    for i = 1, #said do
      t.ok(said:byte(i) < 128, "non-ASCII byte survived sanitising at " .. i)
    end
    t.has(said, "UNIT 12")
  end)

  t.it("wraps long answers into console-width lines", function()
    reset()
    Chat.reply(string.rep("STATUS NOMINAL ", 12), Agents.list[1])
    t.ok(#Chat.queue > 0, "a long answer is queued as several lines")
    t.ok(#Chat.typing.full <= 44, "each line fits the panel")
    for _, line in ipairs(Chat.queue) do
      t.ok(#line <= 44, "queued line too wide: " .. line)
    end
  end)

  t.it("restores the real link for the suites that follow", function()
    Ollama.ask, Ollama.enabled = realAsk, realEnabled
    Chat.reset()
    t.eq(Ollama.ask, realAsk)
  end)
end
