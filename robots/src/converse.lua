-- Talking to a robot.
--
-- One turn is one `chat` call to the backend, and the backend does all of it:
-- route (when no robot is chosen), retrieve from that robot's archive with
-- BM25 and vectors together, call the model, run whatever tools it asks for,
-- and write both halves of the turn back into the archive. What arrives here
-- is the answer plus a receipt — which robot took it, what it retrieved, which
-- tools ran — and the receipt is drawn, because a swarm that acts invisibly is
-- indistinguishable from one that does not act.
--
-- This is separate from `src/chat.lua`, which drives the drone swarm on the
-- map. Same window, two different conversations: that one moves units, this
-- one moves knowledge.

local Backend = require("src.backend")
local Robots = require("src.robots")
local Theme = require("src.theme")

local Converse = {
  lines = {},
  draft = "",
  busy = false,
  awaiting = nil,
  lastTurn = nil,
  loadedFor = false,   -- whose transcript is in `lines`
  notice = nil,        -- a one-line receipt under the answer
  streaming = nil,     -- the line currently being written, while one is
  -- How far through reading the prompt the model is, while it still is.
  -- On-device this is most of the wait: seconds of prefill before a single
  -- token, and the one part of it that has a real fraction to show.
  progress = nil,      -- { done, total }
}

local MAX = 120

-- The 8x8 ROM has ninety-odd glyphs and no lower case. Everything on its way
-- to the screen is folded to that, which is also why the model is asked for
-- short answers.
function Converse.flatten(text)
  text = tostring(text or "")
  text = text:gsub("<think>.-</think>", " ")
  text = text:gsub("<[^>]->", " ")
  text = text:gsub("[\128-\255]", " ")
  text = text:gsub("[%*_`]", "")
  text = text:gsub("%s+", " ")
  return (text:gsub("^%s+", ""):gsub("%s+$", "")):upper()
end

function Converse.wrap(text, width)
  local out, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    while #word > width do
      if line ~= "" then out[#out + 1] = line line = "" end
      out[#out + 1] = word:sub(1, width)
      word = word:sub(width + 1)
    end
    if line == "" then line = word
    elseif #line + 1 + #word <= width then line = line .. " " .. word
    else out[#out + 1] = line line = word end
  end
  if line ~= "" then out[#out + 1] = line end
  if #out == 0 then out[1] = "" end
  return out
end

function Converse.push(who, text, color)
  Converse.lines[#Converse.lines + 1] = {
    who = who, text = Converse.flatten(text), color = color or Theme.cyan, t = 0,
  }
  while #Converse.lines > MAX do table.remove(Converse.lines, 1) end
end

function Converse.reset()
  Converse.lines = {}
  Converse.draft = ""
  Converse.busy = false
  Converse.lastTurn = nil
  Converse.notice = nil
  Converse.streaming = nil
  Converse.progress = nil
  Converse.loadedFor = false
end

--- Pull the chosen robot's transcript out of the archive, so switching to a
--- robot shows what was already said to it rather than an empty screen.
function Converse.load(force)
  local want = Robots.selected
  if not force and Converse.loadedFor == want then return false end
  Converse.loadedFor = want
  Converse.lines = {}
  return Backend.call({ op = "messages", agent = want or "global", limit = 40 },
    function(data, err)
      if err or type(data) ~= "table" then return end
      if Converse.loadedFor ~= want then return end
      local robot = Robots.byId[want or ""]
      for _, m in ipairs(data) do
        local who = (m.role == "user") and "YOU" or Robots.name(robot)
        Converse.push(who, m.body, m.role == "user" and Theme.paper or Robots.color(robot))
      end
    end)
end

--- One turn. `who` overrides the chosen robot for this message only.
---
--- The answer is watched as it is written. A line for it goes up empty the
--- moment the turn is sent and grows a piece at a time, so an on-device
--- turn — seconds of model, and a first token that lands long before the
--- last — reads as a robot answering rather than as a window that has
--- stopped responding. A backend with nothing to stream fills that same
--- line in one go at the end, which is what it always did.
function Converse.send(text, who)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return false end
  if Converse.busy then return false, "STILL THINKING" end

  Converse.push("YOU", text, Theme.paper)
  Converse.busy = true
  Converse.notice = nil

  local agent = who or Robots.selected or "global"
  -- Who is answering is not known yet when nobody was chosen: the backend
  -- routes. So the line goes up under the chosen robot's name, or under a
  -- placeholder, and is corrected when the turn says who took it.
  local chosen = Robots.byId[agent] or nil
  local pending = {
    who = chosen and Robots.name(chosen) or "...",
    text = "",
    raw = "",
    color = Robots.color(chosen),
    t = 0,
    partial = true,
  }
  Converse.lines[#Converse.lines + 1] = pending
  Converse.streaming = pending

  local function drop()
    for i = #Converse.lines, 1, -1 do
      if Converse.lines[i] == pending then table.remove(Converse.lines, i) end
    end
    if Converse.streaming == pending then Converse.streaming = nil end
  end

  return Backend.call({ op = "chat", agent = agent, text = text },
    function(data, err)
      Converse.busy = false
      Converse.streaming = nil
      Converse.progress = nil
      if err or type(data) ~= "table" then
        drop()
        Converse.push("SYSTEM", err or "NO ANSWER", Theme.crimson)
        return
      end
      Converse.lastTurn = data
      local robot = data.agent and Robots.byId[data.agent.id] or nil
      -- A routed turn is how a robot arrives without being called: the face
      -- that answers is the face that steps forward.
      if robot and data.routed and not Robots.selected then
        Robots.hint = { agent = data.agent, confident = data.confident }
      end
      -- The whole answer replaces whatever was streamed, rather than being
      -- appended to it: the turn is the truth, and the pieces were a
      -- preview of it. They agree when the stream was complete, and when it
      -- was not — a tool call held back, an interrupted generation — the
      -- turn is the one that is right.
      pending.partial = false
      pending.who = Robots.name(robot)
      pending.color = Robots.color(robot)
      pending.text = Converse.flatten(data.reply)
      pending.raw = nil
      if pending.text == "" then drop() end
      Converse.notice = Converse.receipt(data)
    end,
    { onChunk = function(kind, chunk, done, total)
        if kind == "prefill" then
          Converse.progress = { done = done or 0, total = total or 0 }
          -- Say it where the answer will appear, so the wait and the thing
          -- being waited for are in the same place. Overwritten by the
          -- first token, which is the point.
          if pending.raw == "" and (total or 0) > 0 then
            pending.text = string.format("READING THE PROMPT  %d/%d", done or 0, total)
          end
        elseif kind == "token" then
          -- The prompt is read; the fraction has nothing left to say.
          Converse.progress = nil
          -- The accumulated raw text is flattened each time rather than
          -- each chunk being flattened alone: a chunk boundary that falls
          -- on a space would otherwise weld two words together.
          pending.raw = pending.raw .. tostring(chunk or "")
          pending.text = Converse.flatten(pending.raw)
        elseif kind == "tool" then
          -- What the turn is doing while there is nothing to read. Replaced
          -- by the receipt when the turn lands, and folded the way the
          -- receipt folds a tool label rather than the way prose is folded:
          -- `flatten` strips underscores as markdown, and `search_context`
          -- is a name, not emphasis.
          Converse.notice = (tostring(chunk or ""):gsub("%s+", " ")):upper()
        end
      end })
end

--- One line saying what the turn actually did.
function Converse.receipt(turn)
  if type(turn) ~= "table" then return nil end
  local bits = {}
  if turn.routed and turn.agent then
    bits[#bits + 1] = (turn.confident and "ROUTED TO " or "DEFAULTED TO ")
      .. tostring(turn.agent.name):upper()
  end
  local n = #(turn.retrieved or {})
  if n > 0 then bits[#bits + 1] = n .. " FROM ARCHIVE" end
  for _, t in ipairs(turn.tools or {}) do bits[#bits + 1] = t end
  if turn.model and turn.model ~= "" then bits[#bits + 1] = tostring(turn.model):upper() end
  if #bits == 0 then return nil end
  return table.concat(bits, "  //  ")
end

--- Fit a receipt into `width` by dropping whole sections off the end.
---
--- Cutting the string would leave `GPT-O`, which reads as a bug rather than
--- as an abbreviation. A receipt is a list, so the honest way to shorten one
--- is to say fewer things, not to say one of them halfway.
function Converse.fitReceipt(line, width)
  if not line or #line <= width then return line or "" end
  local parts = {}
  for part in tostring(line):gmatch("[^/]+") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then parts[#parts + 1] = part end
  end
  local out = ""
  for _, part in ipairs(parts) do
    local next = out == "" and part or (out .. "  //  " .. part)
    if #next > width then break end
    out = next
  end
  if out == "" then out = tostring(line):sub(1, math.max(0, width - 1)) .. "-" end
  return out
end

--- Type into the draft. Returns the line when ENTER commits one.
function Converse.handleInput(Input)
  if Input.text ~= "" then
    Converse.draft = Converse.draft .. Input.text
  end
  if Input.backspace and #Converse.draft > 0 then
    Converse.draft = Converse.draft:sub(1, -2)
  end
  if Input.wasKey("return") or Input.wasKey("kpenter") then
    local line = Converse.draft
    Converse.draft = ""
    if line:gsub("%s", "") ~= "" then return line end
  end
  return nil
end

function Converse.update(dt)
  for _, line in ipairs(Converse.lines) do line.t = line.t + dt end
  -- Whoever is chosen owns the transcript on screen.
  if Converse.loadedFor ~= Robots.selected then Converse.load() end
end

--- The last thing a robot said, for the face to speak.
function Converse.lastSaid()
  for i = #Converse.lines, 1, -1 do
    if Converse.lines[i].who ~= "YOU" then return Converse.lines[i] end
  end
  return nil
end

return Converse
