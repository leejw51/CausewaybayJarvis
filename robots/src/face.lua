-- FACE MODE. One robot, one conversation, nothing else on the screen.
--
-- The dashboard is a swarm: a tower, a hundred drones, a map, a command rail.
-- Face mode throws all of it away and leaves the thing you are actually
-- talking to — a head, what it just said, and a line to type in. It is the
-- same backend, the same archive and the same tools; only the furniture is
-- gone.
--
-- With no robot chosen the face is the swarm's own, and it *changes as you
-- type*: the router is asked what the half-written line would summon, and the
-- robot that would take it steps forward before you have pressed enter. That
-- is what "for food, the food robot appears" looks like when it is drawn.

local Actions = require("src.actions")
local Backend = require("src.backend")
local Converse = require("src.converse")
local Font = require("src.font")
local Input = require("src.input")
local Layout = require("src.layout")
local Robots = require("src.robots")
local Sprites = require("src.sprites")
local Theme = require("src.theme")
local UI = require("src.ui")

local Face = {
  t = 0,
  -- The face on screen, which lags the routed one so it can be animated in.
  showing = nil,
  swap = 0,
  -- Routing is asked for on a pause in typing, not on every keystroke.
  routeAt = 0,
  routed = "",
  -- The unified search box: open, and what is in it. It borrows the input
  -- line, and the conversation's own draft waits underneath untouched.
  searching = false,
  query = "",
}

--- The menu above the input: the archive words as buttons, and the one
--- thing a word cannot be — a search over every agent whoever is chosen.
Face.MENU = {
  { id = "photo",   label = "PHOTO",   tone = "cyan" },
  { id = "file",    label = "FILE",    tone = "amber" },
  { id = "gallery", label = "GALLERY", tone = "cyan" },
  { id = "paper",   label = "PAPER",   tone = "paper" },
  { id = "search",  label = "SEARCH ALL", tone = "gold" },
}

--- How long the operator has to stop typing before the router is asked. Long
--- enough that a fast typist does not make one call per letter, short enough
--- that the face has arrived by the time they look up.
local ROUTE_IDLE = 0.35
local ROUTE_MIN = 3

function Face.enter()
  Face.t = 0
  Face.swap = 0
  Face.showing = Robots.selected
  Face.searching = false
  Converse.load()
end

--- What an action says back: into the transcript, in the tone's colour.
local function TONE(tone)
  return (tone == "good" and Theme.jade) or (tone == "warn" and Theme.crimson) or Theme.dim
end
function Face.say(text, tone)
  Converse.push("SYSTEM", text, TONE(tone))
end

--- Open the unified search box. Everything typed until enter is the query;
--- enter runs it over every agent, escape closes the box.
function Face.openSearch()
  Face.searching = true
  Face.query = ""
end

--- Run the box's words over every agent — whoever is chosen — and say the
--- hits back into the transcript. Returns false for an empty box.
function Face.searchAll(query)
  query = tostring(query or Face.query):gsub("^%s+", ""):gsub("%s+$", "")
  Face.searching = false
  if query == "" then return false end
  Face.query = ""
  Converse.push("YOU", "search all: " .. query, Theme.paper)
  return Actions.run("search", query, Face.say, { all = true })
end

--- One press on the menu: the archive words go through `Actions`, and the
--- search opens the box.
function Face.press(id)
  if id == "search" then
    Face.openSearch()
    return true
  end
  return Actions.run(id, nil, Face.say)
end

--- The box has the keyboard while it is open: nothing here reaches the
--- conversation's draft or the face's own keys.
local function handleSearchInput()
  if Input.text ~= "" then Face.query = Face.query .. Input.text end
  if Input.backspace and #Face.query > 0 then Face.query = Face.query:sub(1, -2) end
  if Input.wasKey("return") or Input.wasKey("kpenter") then Face.searchAll() end
  if Input.wasKey("escape") then Face.searching = false end
end

--- Which robot's face belongs on screen: the chosen one, or — when none is
--- chosen — whoever the current draft would summon.
function Face.subject()
  if Robots.selected then return Robots.byId[Robots.selected] end
  return Robots.hinted()
end

--- Returns "back" when the operator is done.
function Face.update(dt)
  Face.t = Face.t + dt
  Face.swap = math.max(0, Face.swap - dt * 2.2)
  Converse.update(dt)

  if Face.searching then
    handleSearchInput()
    return nil
  end

  if Input.wasKey("escape") then return "back" end
  if Input.wasKey("f5") then Converse.load(true) end
  if Input.wasKey("left") then Robots.cycle(-1) Face.enter() end
  if Input.wasKey("right") then Robots.cycle(1) Face.enter() end

  local before = Converse.draft
  local line = Converse.handleInput(Input)
  if Converse.draft ~= before then Face.routeAt = Face.t end

  if line then
    -- The archive words — photo, file, paper, gallery, search — are done
    -- here and said back into the transcript; anything else is a turn.
    local handled = Actions.handle(line, Face.say)
    if not handled then
      -- The face on screen is left alone: the robot that is about to answer is
      -- the one already standing there, and blanking it here would flick the
      -- screen back to the swarm for the length of a turn.
      Converse.send(line)
    end
    Face.routed = ""
  end

  -- Ask the router once the typing has paused. Only when nothing is locked
  -- on: a chosen robot answers whatever it is asked.
  --
  -- The hint is never cleared for an empty box. Emptying it is what pressing
  -- enter does, and the robot that just answered has to stay on screen while
  -- you read what it said; a new draft replaces it when it routes somewhere
  -- else, and that is the only thing that should.
  if not Robots.selected then
    local draft = Converse.draft
    if #draft >= ROUTE_MIN and draft ~= Face.routed
      and Face.t - Face.routeAt > ROUTE_IDLE then
      Face.routed = draft
      Robots.ask(draft)
    end
  end

  local subject = Face.subject()
  local id = subject and subject.id or nil
  if id ~= Face.showing then
    Face.showing = id
    Face.swap = 1
  end
  return nil
end

--- Every rectangle, from the canvas size. No `love.*`: checkable headlessly.
--- Every rectangle, from the canvas size. No `love.*`: checkable headlessly.
---
--- Three bands are reserved rather than assumed. Under the head go the
--- robot's name and its role, two rows; above the input go the key hints,
--- one row. The transcript gets everything left. Portrait used to hand the
--- name's rows to the transcript as well, and the two drew over each other.
function Face.rects(w, h, portrait)
  local inputH = 16
  local nameH = 22          -- the robot's name and its role, under the head
  local menuH = 14          -- the menu buttons and the key hints, above the input
  local headerH = portrait and 26 or 18
  local head = portrait and math.min(w - 40, math.floor(h * 0.34))
    or math.min(math.floor(h * 0.62), math.floor(w * 0.34))
  local inputY = h - inputH - 4
  local menu = { x = 4, y = inputY - menuH - 2, w = w - 8, h = menuH }
  if portrait then
    local top = headerH + head + nameH + 6
    return {
      head   = { x = math.floor((w - head) / 2), y = headerH, w = head, h = head },
      speech = { x = 6, y = top, w = w - 12, h = math.max(20, menu.y - 4 - top) },
      menu   = menu,
      input  = { x = 4, y = inputY, w = w - 8, h = inputH },
    }
  end
  return {
    head   = { x = 14, y = math.floor((h - head) / 2) - 6, w = head, h = head },
    speech = { x = head + 26, y = 20, w = w - head - 40,
               h = math.max(20, menu.y - 4 - 20) },
    menu   = menu,
    input  = { x = 4, y = inputY, w = w - 8, h = inputH },
  }
end

--- Where each menu button goes in the menu band, and what is left for the
--- key hints. Pure, so the row can be checked headlessly: `buttons[i]` is
--- `{ id, label, x, w }`, and `hintX` is where the hints may start.
function Face.menuLayout(r)
  local buttons, x = {}, r.x
  for _, m in ipairs(Face.MENU) do
    local label = m.label
    -- A narrow row keeps every button by shortening the long label.
    if r.w < 480 and m.id == "search" then label = "SEARCH" end
    local bw = #label * 8 + 8
    if x + bw > r.x + r.w then break end
    buttons[#buttons + 1] = { id = m.id, label = label, tone = m.tone, x = x, w = bw }
    x = x + bw + 2
  end
  return buttons, x + 4
end

local function drawHead(r, robot, accent)
  local cx, cy = r.x + r.w / 2, r.y + r.h / 2
  local breathe = math.sin(Face.t * 1.7) * 2
  local pop = Face.swap > 0 and (1 + Face.swap * 0.12) or 1

  UI.rings(cx, cy, r.w * 0.56 * pop, Face.t, accent, Theme.withAlpha(accent, 0.5))
  love.graphics.setColor(Theme.withAlpha(accent, 0.10 + 0.05 * math.sin(Face.t * 2)))
  love.graphics.circle("fill", cx, cy, r.w * 0.5)

  if robot and Sprites.head(robot.sprite) then
    local size = r.w * 0.86 * pop
    Sprites.drawHead(robot.sprite, cx - size / 2, cy - size / 2 + breathe, size, 1)
  else
    -- No sprite loaded (or no robot): the swarm's own mark.
    UI.hex(cx, cy + breathe, r.w * 0.3, accent, false, Face.t * 0.4)
    UI.hex(cx, cy + breathe, r.w * 0.2, Theme.withAlpha(accent, 0.6), false, -Face.t * 0.6)
  end

  -- Thinking: a ring that closes while the backend has the turn.
  if Converse.busy then
    love.graphics.setColor(Theme.withAlpha(Theme.gold, 0.8))
    for i = 0, 2 do
      local a = Face.t * 2.4 + i * math.pi * 2 / 3
      love.graphics.circle("fill", cx + math.cos(a) * r.w * 0.62,
        cy + math.sin(a) * r.w * 0.62, 2)
    end
    -- And, while the model is still reading the prompt, how far through it
    -- is. On-device that is most of the wait — seconds before the first
    -- token — and three dots going round say nothing about how long is
    -- left. An arc does.
    -- A ring that fills as the prompt is read. Only the ring: the count
    -- itself goes in the transcript, where the eye already is and where
    -- there is room for it — under the portrait it lands on the key hints.
    local p = Converse.progress
    if p and (p.total or 0) > 0 then
      local k = math.max(0, math.min(1, (p.done or 0) / p.total))
      local radius = r.w * 0.56
      love.graphics.setColor(Theme.withAlpha(Theme.cyan, 0.18))
      love.graphics.circle("line", cx, cy, radius)
      love.graphics.setColor(Theme.withAlpha(Theme.cyan, 0.95))
      love.graphics.arc("line", "open", cx, cy, radius,
        -math.pi / 2, -math.pi / 2 + math.pi * 2 * k)
    end
  end

  -- The name and the role go in the band `Face.rects` left for them, which
  -- is why the transcript below cannot be drawn over.
  local name = Robots.name(robot)
  Font.print(name, cx - #name * 8 / 2, r.y + r.h + 3, accent, 1)
  if robot then
    local role = tostring(robot.role or ""):upper()
    Font.print(role, cx - #role * 4, r.y + r.h + 13, Theme.dim, 1)
  elseif Robots.hint and not Robots.hinted() then
    Font.print("LISTENING", cx - 36, r.y + r.h + 13, Theme.dim, 1)
  end
end

local function drawSpeech(r, accent)
  local chars = math.max(10, math.floor((r.w - 12) / 8))
  local rows = math.max(1, math.floor((r.h - 8) / 10))

  -- Build from the newest backwards, so the latest line is always on screen.
  --
  -- Every row of a block is indented past its speaker's name, and the text
  -- is wrapped to what is left. Wrapping to the full width and then
  -- indenting — which is what this did — pushes the first line of every
  -- answer off the right edge, where it is not cut but simply not there.
  local shown = {}
  for i = #Converse.lines, 1, -1 do
    local line = Converse.lines[i]
    local head = tostring(line.who or ""):sub(1, 10) .. ">"
    local indent = #head + 1
    -- A line still being written gets a block on the end, so a pause
    -- between tokens reads as the robot thinking rather than as the answer
    -- having stopped. It blinks; the text under it does not move.
    local text = line.text
    if line.partial then
      text = text .. (math.floor(Face.t * 3) % 2 == 0 and " |" or "")
    end
    local wrapped = Converse.wrap(text, math.max(8, chars - indent))
    for j = #wrapped, 1, -1 do
      table.insert(shown, 1, { text = wrapped[j], color = line.color,
        indent = indent, head = j == 1 and head or nil })
      if #shown >= rows then break end
    end
    if #shown >= rows then break end
  end

  for i, line in ipairs(shown) do
    local y = r.y + (i - 1) * 10
    if line.head then
      Font.print(line.head, r.x, y, Theme.withAlpha(line.color, 0.7), 1)
    end
    Font.print(line.text, r.x + line.indent * 8, y, line.color, 1)
  end

  if Converse.notice then
    love.graphics.setColor(Theme.withAlpha(accent, 0.5))
    love.graphics.rectangle("fill", r.x, r.y + r.h - 12, r.w, 1)
    Font.print(Converse.fitReceipt(Converse.notice, chars),
      r.x, r.y + r.h - 10, Theme.dim, 1)
  end
end

local function drawInput(r, accent)
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  love.graphics.setColor(Theme.withAlpha(accent, 0.9))
  love.graphics.rectangle("line", r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1)

  if Face.searching then
    -- The unified search box, in the input's place: a prompt that says
    -- how far it reaches, the query, and a caret.
    local prompt = "SEARCH ALL AGENTS>"
    if (#prompt + 12) * 8 > r.w then prompt = "SEARCH ALL>" end
    Font.print(prompt, r.x + 4, r.y + 4, Theme.gold, 1)
    local left = r.x + 4 + (#prompt + 1) * 8
    local chars = math.max(6, math.floor((r.x + r.w - left - 10) / 8))
    local q = Face.query
    if #q > chars then q = q:sub(#q - chars + 1) end
    Font.print(q:upper(), left, r.y + 4, Theme.paper, 1)
    if math.floor(Face.t * 2) % 2 == 0 then
      love.graphics.setColor(Theme.paper)
      love.graphics.rectangle("fill", left + #q * 8, r.y + 4, 6, 8)
    end
    return
  end

  local prompt = Converse.busy and "..." or ">"
  Font.print(prompt, r.x + 4, r.y + 4, accent, 1)
  local chars = math.max(8, math.floor((r.w - 28) / 8))
  local draft = Converse.draft
  if #draft > chars then draft = draft:sub(#draft - chars + 1) end
  Font.print(draft:upper(), r.x + 18, r.y + 4, Theme.paper, 1)
  if math.floor(Face.t * 2) % 2 == 0 and not Converse.busy then
    love.graphics.setColor(Theme.paper)
    love.graphics.rectangle("fill", r.x + 18 + #draft * 8, r.y + 4, 6, 8)
  end
end

--- The menu row: one button per archive word, SEARCH ALL for the unified
--- search, and the key hints in whatever room is left.
local TONES = { cyan = Theme.cyan, amber = Theme.amber, paper = Theme.paper, gold = Theme.gold }
local function drawMenu(r)
  local buttons, hintX = Face.menuLayout(r)
  for _, b in ipairs(buttons) do
    local on = b.id == "search" and Face.searching
    if UI.button("face." .. b.id, b.x, r.y + 1, b.w, r.h - 2, b.label,
      { stroke = TONES[b.tone] or Theme.dim, on = on, onColor = Theme.gold, scale = 1 }) then
      Face.press(b.id)
    end
  end
  local hints = Face.searching and "ENTER SEARCH   ESC CLOSE"
    or "ESC BACK   L/R AGENT   F9 BRAIN   F5 RELOAD"
  if not Face.searching and (hintX + #hints * 8) > r.x + r.w then hints = "ESC BACK  L/R AGENT  F9 BRAIN" end
  if (hintX + #hints * 8) > r.x + r.w then hints = "ESC BACK" end
  if (hintX + #hints * 8) <= r.x + r.w then
    Font.print(hints, hintX, r.y + 4, Theme.dim, 1)
  end
end

function Face.draw()
  local w, h = Layout.vw, Layout.vh
  local robot = Face.subject()
  local accent = Robots.color(robot)
  local r = Face.rects(w, h, Layout.isPortrait())

  love.graphics.setColor(Theme.void)
  love.graphics.rectangle("fill", 0, 0, w, h)
  -- A slow wash of the robot's own colour, so the room changes with the robot.
  love.graphics.setColor(Theme.withAlpha(accent, 0.05))
  love.graphics.rectangle("fill", 0, 0, w, h)

  -- Which brain is answering, and whether a robot is locked on. Three
  -- labels; they share a row only when the row is wide enough to hold
  -- them. At 8 pixels a character a 360-wide portrait canvas holds 45, and
  -- these come to more than that — so portrait puts the brain on its own
  -- row underneath and shortens the rest. Overlapping them, which is what
  -- happened before, makes all three unreadable rather than one absent.
  local plabel = Backend.providerLabel()
  local ptone = Backend.providerTone()
  local pcolor = (ptone == "good" and Theme.jade) or (ptone == "info" and Theme.sky)
    or Theme.crimson
  local locked = Robots.selected and "LOCKED" or "OPEN"
  local wide = (#plabel + #locked + 12) * 8 <= w
  if wide then
    Font.print("FACE MODE", 4, 4, Theme.dim, 1)
    Font.print(plabel, math.floor((w - #plabel * 8) / 2), 4, pcolor, 1)
    local hint = Robots.selected and "LOCKED" or "OPEN -- THE WORDS PICK THE ROBOT"
    if (#hint + #plabel / 2 + 12) * 8 > w then hint = locked end
    Font.print(hint, w - #hint * 8 - 4, 4, Theme.dim, 1)
  else
    Font.print("FACE MODE", 4, 4, Theme.dim, 1)
    Font.print(locked, w - #locked * 8 - 4, 4, Theme.dim, 1)
    Font.print(plabel, math.floor((w - #plabel * 8) / 2), 14, pcolor, 1)
  end

  drawHead(r.head, robot, accent)
  drawSpeech(r.speech, accent)
  drawMenu(r.menu)
  drawInput(r.input, accent)
end

return Face
