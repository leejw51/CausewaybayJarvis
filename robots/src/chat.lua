local Agents = require("src.agents")
local Audio = require("src.audio")
local Fleet = require("src.fleet")
local Central = require("src.central")
local Ollama = require("src.ollama")
local Tools = require("src.tools")

local Chat = {
  lines = {},
  draft = "",
  caret = 0,
  typing = nil,
  queue = {},
  awaiting = nil,
  history = {},
}

local MAX = 48
local WRAP = 44
local HISTORY = 8
-- The model acts through tools, one round trip per batch of calls. Cap the
-- ladder so a confused model cannot loop the swarm all night.
local MAX_ROUNDS = 4

function Chat.reset()
  Chat.lines = {}
  Chat.draft = ""
  Chat.typing = nil
  Chat.queue = {}
  Chat.awaiting = nil
  Chat.history = {}
end

function Chat.push(who, text, colorKey)
  Chat.lines[#Chat.lines + 1] = {
    who = who, text = text, colorKey = colorKey or "cyan", t = 0,
  }
  while #Chat.lines > MAX do table.remove(Chat.lines, 1) end
end

-- Model output arrives as prose. The dashboard font is an 8x8 uppercase
-- ROM, so flatten it to plain ASCII caps before it ever reaches a glyph.
local function sanitize(text)
  text = tostring(text or "")
  text = text:gsub("<think>.-</think>", " ")
  text = text:gsub("<[^>]->", " ")
  text = text:gsub("[%*_`#]", "")
  text = text:gsub("[\128-\255]", " ")
  text = text:gsub("%s+", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  return text:upper()
end

local function wrap(text, width)
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    while #word > width do
      if line ~= "" then out[#out + 1] = line line = "" end
      out[#out + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      out[#out + 1] = line
      line = word
    end
  end
  if line ~= "" then out[#out + 1] = line end
  if #out == 0 then out[1] = "..." end
  return out
end

local function beginTyping(text, who, colorKey)
  Chat.typing = { who = who, full = text, shown = "", colorKey = colorKey, acc = 0 }
end

function Chat.reply(text, agent)
  agent = agent or select(1, Chat.speaker())
  local chunks = wrap(sanitize(text), WRAP)
  Chat.queue = {}
  for i = 2, #chunks do Chat.queue[#Chat.queue + 1] = chunks[i] end
  beginTyping(chunks[1], agent.name, agent.id)
end

-- Locked unit speaks as itself. Nobody locked: the house AI, tagged for the
-- brain behind it — ON-DEV AI or CLOUD AI — so every reply says where it
-- came from, and plain AI only when nothing is answering.
function Chat.speaker()
  local u = Fleet.selected
  if u then return Agents.lookOf(u), u end
  local v = Agents.voice()
  local st = Ollama.status()
  local name = "AI"
  if st.enabled then name = st.cloud and "CLOUD AI" or "ON-DEV AI" end
  return { name = name, id = v.id, color = v.color }, nil
end

local function remember(role, content)
  Chat.history[#Chat.history + 1] = { role = role, content = content }
  while #Chat.history > HISTORY do table.remove(Chat.history, 1) end
end

function Chat.send(raw)
  raw = raw or Chat.draft
  local msg = raw:gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "" then return end
  Chat.push("YOU", msg:upper(), "amber")
  Chat.draft = ""
  Audio.play("blip")
  Chat.interpret(msg)
end

-- Everything the model is allowed to know about the fleet right now.
local function briefing(unit)
  local rec = unit and Central.record(unit)
  local look = unit and Agents.lookOf(unit)
  local lines
  if rec and look then
    lines = {
      unit.robot
        and string.format("You are %s, the %s AI agent of the Causeway Bay swarm, on floor %s. " ..
          "You are one robot with one folder of your own (%s); face mode is where that folder is read from.",
          look.name, look.role, rec.id, tostring(look.folder or ""))
        or string.format("You are %s, drone %s, a %s in the Causeway Bay swarm.",
          look.name, rec.id, look.role),
      "The operator locked you on a 16-bit tactical console and is speaking to you directly.",
      "Speak in first person as this unit. Clipped, in-character. Address the operator as SIR.",
      "Hard limits: at most 2 short sentences, under 30 words total, plain ASCII, no markdown, no emoji, no lists.",
      string.format("Your sector %s, task %s, billet %s.", rec.sector, rec.task, rec.house),
      string.format("Fleet: %d of %d units online. Console orders apply only to you while you are locked.",
        Fleet.onlineCount(), Fleet.COUNT),
      "You have tools that move the real swarm: fleet_command, move_fleet, move_unit, " ..
        "select_unit, fleet_status, get_time. Prefer acting on yourself unless the operator names the fleet.",
      "Places you can fly to: " .. Tools.PLACES .. ". Fleet commands: " .. Tools.COMMANDS .. ".",
      "Only report an order as carried out when the tool answered DONE. If it answered REJECTED, " ..
        "say what went wrong in one short sentence.",
    }
  else
    lines = {
      "You are the central AI for an autonomous drone swarm over Causeway Bay, Hong Kong.",
      "No unit is locked. Answer globally as the house AI, not as a floor robot. Console tag: AI.",
      "You speak to the operator over a 16-bit tactical console.",
      "Style: clipped, dry, unflappable. Address the operator as SIR.",
      "Hard limits: at most 2 short sentences, under 30 words total, plain ASCII, no markdown, no emoji, no lists.",
      string.format("Fleet: %d of %d units online.", Fleet.onlineCount(), Fleet.COUNT),
      string.format("Central DB queries this session: %d.", Central.queries),
      "You have tools that move the real swarm: fleet_command, move_fleet, move_unit, " ..
        "select_unit, fleet_status, get_time. Call them whenever the operator orders an action " ..
        "or asks for live facts or the time; do not guess and do not answer from memory.",
      "Places you can fly units to: " .. Tools.PLACES .. ". Fleet commands: " .. Tools.COMMANDS .. ".",
      Agents.roster
        and string.format("The AI agents on the tower, one folder each: %s. Any of them, or ALL, is a wing.",
          Agents.dutyNames())
        or string.format("On-duty wings this session: %s, or ALL. Catalog has %d models; off-duty names are rejected.",
          Agents.dutyNames(), #Agents.catalog),
      "Only report an order as carried out when the tool answered DONE. If it answered REJECTED, " ..
        "say what went wrong in one short sentence.",
      "No unit is currently selected. Orders apply to the whole swarm.",
    }
  end
  return table.concat(lines, " ")
end

-- Runs the tool calls the model asked for and logs each one on the console,
-- so the operator sees the orders that were actually issued.
local function execute(calls, messages)
  local last
  for _, c in ipairs(calls) do
    local fn = type(c["function"]) == "table" and c["function"] or {}
    local args = fn.arguments
    local out = Tools.run(fn.name, args)
    Chat.push("EXEC", Tools.label(fn.name, args):sub(1, WRAP), "jade")
    require("src.autopilot").recordTool(fn.name, args)
    messages[#messages + 1] = {
      role = "tool", tool_name = tostring(fn.name or "tool"), content = out,
    }
    last = out
  end
  return last
end

local function turn(messages, agent, unit, prompt, round)
  Chat.awaiting = { who = agent.name, colorKey = agent.id, t = 0 }

  local ok = Ollama.ask(messages, function(text, err, msg)
    Chat.awaiting = nil
    local calls = msg and type(msg.tool_calls) == "table" and msg.tool_calls or nil

    if calls and #calls > 0 then
      messages[#messages + 1] = msg
      local last = execute(calls, messages)
      if round < MAX_ROUNDS then
        turn(messages, agent, unit, prompt, round + 1)
      else
        Chat.reply(last or "ORDERS EXECUTED, SIR.", agent)
      end
      return
    end

    if text and text:gsub("%s", "") ~= "" then
      remember("assistant", text)
      Chat.reply(text, agent)
    else
      Chat.push("LINK", (err or "OLLAMA UNREACHABLE"):sub(1, WRAP), "magenta")
      Chat.reply(Central.mockReply(prompt, unit), agent)
    end
  end, { tools = Tools.schema })

  if not ok then
    Chat.awaiting = nil
    Chat.push("LINK", "LINK DOWN. LOCAL CENTRAL ANSWERING.", "magenta")
    Chat.reply(Central.mockReply(prompt, unit), agent)
  end
end

function Chat.ask(msg, agent, unit)
  local messages = { { role = "system", content = briefing(unit) } }
  for _, h in ipairs(Chat.history) do
    messages[#messages + 1] = { role = h.role, content = h.content }
  end
  messages[#messages + 1] = { role = "user", content = msg }
  remember("user", msg)
  turn(messages, agent, unit, msg, 1)
end

local function words(s)
  local n = 0
  for _ in s:gmatch("%S+") do n = n + 1 end
  return n
end

-- The autopilot's own turn. Same tools, same ladder; the console just shows
-- the house taking initiative instead of the operator typing.
function Chat.auto(prompt)
  if not Ollama.available() then return false end
  local a, u = Chat.speaker()
  Chat.ask(prompt, a, u)
  return true
end

function Chat.interpret(msg)
  local Commands = require("src.commands")
  local upper = msg:upper()
  local id = upper:match("U(%d+)") or upper:match("FIND%s+(%d+)") or upper:match("^%s*(%d+)%s*$")
  if id then
    Commands.findUnit(tonumber(id))
    return
  end

  -- A bare command word runs instantly; anything with a sentence in it goes
  -- to the locked unit, or the house AI when nobody is locked.
  local cid = Commands.fromText(msg)
  if cid and (words(msg) <= 2 or not Ollama.available()) then
    Commands.run(cid)
    return
  end

  local a, u = Chat.speaker()
  if Ollama.available() then
    Chat.ask(msg, a, u)
  else
    Chat.reply(Central.mockReply(msg, u), a)
  end
end

function Chat.update(dt)
  for _, ln in ipairs(Chat.lines) do ln.t = ln.t + dt end
  if Chat.awaiting then Chat.awaiting.t = Chat.awaiting.t + dt end
  local ty = Chat.typing
  if ty then
    ty.acc = ty.acc + dt
    local rate = 0.016
    while ty.acc >= rate and #ty.shown < #ty.full do
      ty.acc = ty.acc - rate
      ty.shown = ty.full:sub(1, #ty.shown + 1)
      if ty.shown:sub(-1) ~= " " then Audio.play("type", 1, 0.28) end
    end
    if #ty.shown >= #ty.full then
      Chat.push(ty.who, ty.full, ty.colorKey)
      Chat.typing = nil
      if #Chat.queue > 0 then
        beginTyping(table.remove(Chat.queue, 1), ty.who, ty.colorKey)
      end
    end
  end
end

function Chat.busy()
  return Chat.typing ~= nil or Chat.awaiting ~= nil
end

function Chat.handleInput(Input)
  if Chat.typing then return end
  if Input.text ~= "" then
    local add = Input.text:upper()
    if #Chat.draft + #add <= 48 then Chat.draft = Chat.draft .. add end
  end
  if Input.backspace then
    Chat.draft = Chat.draft:sub(1, -2)
  end
  if Input.wasKey("return") then
    Chat.send()
  end
end

local DOTS = { ".", "..", "...", "...." }

function Chat.recent(n)
  local out = {}
  local extra
  if Chat.typing then
    extra = {
      who = Chat.typing.who, text = Chat.typing.shown .. "_",
      colorKey = Chat.typing.colorKey, t = 0,
    }
  elseif Chat.awaiting then
    local w = Chat.awaiting
    extra = {
      who = w.who, text = "THINKING" .. DOTS[math.floor(w.t * 4) % #DOTS + 1],
      colorKey = w.colorKey, t = 0,
    }
  end
  local total = #Chat.lines + (extra and 1 or 0)
  local start = math.max(1, total - n + 1)
  for i = start, #Chat.lines do out[#out + 1] = Chat.lines[i] end
  if extra and total >= start then out[#out + 1] = extra end
  return out
end

return Chat
