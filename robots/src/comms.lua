-- The comms feed: how JARVIS actually looks when he talks.
--
-- Every row is animated off its own age, so nothing needs bookkeeping: it
-- flies in on an expo curve, a light bar sweeps the row once, and the stack
-- eases up when a new line lands. The line being typed trails embers off the
-- caret. Cheap to draw, all of it screen space, above the map.

local Theme = require("src.theme")
local Font = require("src.font")
local Ease = require("src.ease")
local Chat = require("src.chat")
local FX = require("src.fx")

local Comms = {
  scroll = 0,    -- pixels the stack still has to climb after a new line
  t = 0,
  seen = 0,      -- visible rows last frame, live row included
  liveT = 0,     -- age of the row being typed or waited on
  wasLive = false,
  liveText = nil,
  settled = nil, -- the pushed line that was already on screen as the live row
  lastLine = nil,
  lastLen = 0,
  chars = 0,
}

local ROW = 12
local IN_DUR = 0.42     -- fly-in
local SWEEP_DUR = 0.55  -- light bar across a fresh row
local HOLD = 8          -- seconds before a row starts to leave
local OUT_DUR = 2.5

local COLORS = {
  amber = Theme.amber, cyan = Theme.cyan, magenta = Theme.magenta,
  ice = Theme.ice, teal = Theme.teal, jade = Theme.jade, gold = Theme.gold,
}

function Comms.color(key)
  if COLORS[key] then return COLORS[key] end
  local Agents = require("src.agents")
  local a = Agents.byId(key)
  if a then return a.color end
  return Theme.cyan
end

function Comms.reset()
  Comms.scroll = 0
  Comms.seen = 0
  Comms.liveT = 0
  Comms.wasLive = false
  Comms.liveText = nil
  Comms.settled = nil
  Comms.lastLine = nil
  Comms.lastLen = 0
  Comms.chars = 0
end

local function railBurst(colorKey)
  local box = Comms.box
  if not box then return end
  local col = Comms.color(colorKey)
  local y = box.y + box.rows * ROW - ROW * 0.5
  FX.burst(box.x + 2, y, col, 7)
  FX.flash(box.x, y - ROW * 0.5, box.w, ROW - 1, col, 0.16)
end

function Comms.update(dt)
  Comms.t = Comms.t + dt

  -- Chat rebuilds the typing/waiting row every frame with t = 0, so its age
  -- is kept here instead; a real line gets its age from the line itself.
  local live = Chat.typing or Chat.awaiting
  if live and not Comms.wasLive then
    Comms.liveT = 0
    railBurst(live.colorKey)
  end
  Comms.liveT = live and (Comms.liveT + dt) or 0

  local n = #Chat.lines
  local newest = Chat.lines[n]
  if newest ~= Comms.lastLine then
    if newest and Comms.wasLive and newest.text == Comms.liveText then
      -- the typed row was already on screen: let it settle, do not re-enter
      Comms.settled = newest
    elseif newest then
      railBurst(newest.colorKey)
    end
    Comms.lastLine = newest
  end

  -- the visible stack grows by a row: close the gap exponentially
  local total = n + (live and 1 or 0)
  if total > Comms.seen then Comms.scroll = ROW end
  Comms.seen = total
  Comms.scroll = Ease.smooth(Comms.scroll, 0, dt, 13)
  if Comms.scroll < 0.35 then Comms.scroll = 0 end

  Comms.wasLive = live ~= nil
  Comms.liveText = Chat.typing and Chat.typing.full or nil
end

function Comms.prefix(who)
  who = tostring(who or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if who == "" then return "" end
  return who .. ": "
end

-- 0..1 fade for a row of age t: expo in, long hold, expo out
local function rowFade(t)
  local inK = Ease.outExpo(math.min(1, t / IN_DUR))
  if t <= HOLD then return inK end
  return inK * (1 - Ease.inExpo(math.min(1, (t - HOLD) / OUT_DUR)))
end

-- One row: `WHO: body` on a single line. No boxed name chip.
local function drawRow(ln, x, y, w, newest, mode)
  local age = ln.t or 0
  if mode then age = Comms.liveT end
  if ln == Comms.settled then age = math.max(age, SWEEP_DUR) end
  local alpha = rowFade(age)
  if alpha <= 0.01 then return end

  local slide = (1 - Ease.outExpo(math.min(1, age / IN_DUR))) * 30
  local rx = x - slide
  local col = Comms.color(ln.colorKey)
  local pulse = 0.5 + 0.5 * math.sin(Comms.t * 3.4)
  local glow = newest and pulse or 0.15
  local prefix = Comms.prefix(ln.who)

  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.62 * alpha)
  love.graphics.rectangle("fill", rx, y, w, ROW - 1)

  love.graphics.setColor(col[1], col[2], col[3], (0.5 + 0.5 * glow) * alpha)
  love.graphics.rectangle("fill", rx, y, 2, ROW - 1)

  if newest then
    love.graphics.setColor(col[1], col[2], col[3], (0.10 + 0.14 * pulse) * alpha)
    love.graphics.rectangle("line", rx + 0.5, y + 0.5, w - 1, ROW - 2)
  end

  local ty = y + 2
  Font.print(prefix, rx + 5, ty, { col[1], col[2], col[3], alpha }, 1)

  local body = ln.text or ""
  if mode == "typing" then body = body:gsub("_$", "") end
  if mode == "awaiting" then body = "" end
  local room = math.max(0, math.floor((w - 10) / 8) - #prefix)
  if body ~= "" then
    Font.print(body:sub(1, room), rx + 5 + #prefix * 8, ty,
      { Theme.paper[1], Theme.paper[2], Theme.paper[3], alpha }, 1)
  end

  if age < SWEEP_DUR then
    local k = Ease.outExpo(age / SWEEP_DUR)
    local bx = rx + k * (w + 26) - 26
    local bw = 26
    local x0 = math.max(rx, bx)
    local x1 = math.min(rx + w, bx + bw)
    if x1 > x0 then
      love.graphics.setColor(col[1], col[2], col[3], 0.30 * (1 - k) * alpha)
      love.graphics.rectangle("fill", x0, y, x1 - x0, ROW - 1)
    end
  end

  return rx + 5 + #prefix * 8, alpha
end

-- The caret on the line being typed, plus the embers it throws.
local function drawCaret(ln, x, y, w, alpha)
  local prefix = Comms.prefix(ln.who)
  local shown = #((ln.text or ""):gsub("_$", ""))
  local room = math.max(0, math.floor((w - 10) / 8) - #prefix)
  local col = Comms.color(ln.colorKey)
  local cx = x + 5 + #prefix * 8 + math.min(shown, room) * 8
  local cy = y + 2
  local blink = Ease.inOutExpo(0.5 + 0.5 * math.sin(Comms.t * 9))
  love.graphics.setColor(col[1], col[2], col[3], (0.35 + 0.65 * blink) * alpha)
  love.graphics.rectangle("fill", cx, cy, 6, 8)

  if shown > Comms.lastLen then
    Comms.chars = Comms.chars + (shown - Comms.lastLen)
    if Comms.chars >= 3 then
      Comms.chars = 0
      FX.ember(cx + 3, cy + 4, col)
    end
  end
  Comms.lastLen = shown
end

-- Waiting on the model: a scanning bar and three breathing blocks.
local function drawThinking(ln, x, y, w, alpha)
  local prefix = Comms.prefix(ln.who)
  local col = Comms.color(ln.colorKey)
  local bx = x + 5 + #prefix * 8
  local by = y + 2
  for i = 1, 3 do
    local phase = Comms.t * 3.2 - i * 0.5
    local k = Ease.inOutExpo(0.5 + 0.5 * math.sin(phase))
    love.graphics.setColor(col[1], col[2], col[3], (0.22 + 0.78 * k) * alpha)
    love.graphics.rectangle("fill", bx + (i - 1) * 10, by + 6 - k * 6, 6, math.max(2, k * 8))
  end
  Font.print("THINKING", bx + 36, by, { col[1], col[2], col[3], 0.75 * alpha }, 1)

  local sweep = (Comms.t * 0.9) % 1
  love.graphics.setColor(col[1], col[2], col[3], 0.16 * alpha)
  love.graphics.rectangle("fill", x + sweep * w, y, 2, ROW - 1)
end

-- Draws the last `n` rows so the newest sits at the bottom of the box.
function Comms.draw(x, y, w, n)
  n = n or 3
  local lines = Chat.recent(n)
  Comms.box = { x = x, y = y, w = w, rows = n }
  if #lines == 0 then return end

  local top = y + Comms.scroll
  for i, ln in ipairs(lines) do
    local newest = (i == #lines)
    local mode
    if newest then
      mode = (Chat.typing and "typing") or (Chat.awaiting and "awaiting") or nil
    end
    local ry = top + (i - 1) * ROW
    local _, alpha = drawRow(ln, x, ry, w, newest, mode)
    if alpha then
      if mode == "typing" then
        drawCaret(ln, x, ry, w, alpha)
      elseif mode == "awaiting" then
        drawThinking(ln, x, ry, w, alpha)
      end
    end
  end
end

function Comms.height(n)
  return (n or 3) * ROW
end

-- A burst on the rail when the operator sends, so the panel answers back.
function Comms.punch(x, y, color)
  FX.burst(x, y, color or Theme.amber, 8)
  FX.flash(x, y - 2, 4, ROW, color or Theme.amber, 0.2)
end

return Comms
