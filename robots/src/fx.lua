local Theme = require("src.theme")
local Ease = require("src.ease")
local Layout = require("src.layout")

local FX = {
  sparks = {}, flashes = {}, dust = {}, waves = {}, jets = {},
  toasts = {}, t = 0, shake = 0,
}

function FX.clear()
  FX.sparks = {}
  FX.flashes = {}
  FX.dust = {}
  FX.waves = {}
  FX.jets = {}
  FX.toasts = {}
  FX.t = 0
  FX.shake = 0
end

function FX.reset()
  FX.clear()
end

function FX.kick(n)
  FX.shake = math.max(FX.shake or 0, n or 3)
end

function FX.burst(x, y, color, n)
  n = n or 14
  color = color or Theme.cyan
  for _ = 1, n do
    local a = love.math.random() * math.pi * 2
    local sp = 18 + love.math.random() * 90
    FX.sparks[#FX.sparks + 1] = {
      x = x, y = y,
      vx = math.cos(a) * sp,
      vy = math.sin(a) * sp - 30,
      life = 0.28 + love.math.random() * 0.35,
      t = 0,
      color = color,
      s = love.math.random() < 0.3 and 2 or 1,
      space = "screen",
    }
  end
end

function FX.burstWorld(x, y, color, n)
  n = n or 10
  color = color or Theme.cyan
  for _ = 1, n do
    local a = love.math.random() * math.pi * 2
    local sp = 12 + love.math.random() * 40
    FX.sparks[#FX.sparks + 1] = {
      x = x, y = y,
      vx = math.cos(a) * sp,
      vy = math.sin(a) * sp,
      life = 0.22 + love.math.random() * 0.3,
      t = 0,
      color = color,
      s = 1,
      space = "world",
    }
  end
end

-- A single soft screen-space ember, drifting up. Cheap enough to trail a
-- caret at typing speed, unlike a whole burst.
function FX.ember(x, y, color, up)
  FX.sparks[#FX.sparks + 1] = {
    x = x, y = y,
    vx = (love.math.random() * 2 - 1) * 22,
    vy = -(up or 26) - love.math.random() * 20,
    life = 0.30 + love.math.random() * 0.30,
    t = 0,
    color = color or Theme.cyan,
    s = love.math.random() < 0.22 and 2 or 1,
    space = "screen",
  }
end

function FX.flash(x, y, w, h, color, life)
  FX.flashes[#FX.flashes + 1] = {
    x = x, y = y, w = w, h = h,
    color = color or Theme.cyan, life = life or 0.22, t = 0,
  }
end

function FX.wave(x, y, color, maxR)
  FX.waves[#FX.waves + 1] = {
    x = x, y = y,
    color = color or Theme.cyan,
    r = 2,
    max = maxR or 90,
    t = 0,
    life = 0.55,
  }
end

function FX.jet(x, y, heading, color)
  local bx = x - math.cos(heading) * 3
  local by = y - math.sin(heading) * 3
  FX.jets[#FX.jets + 1] = {
    x = bx, y = by,
    vx = -math.cos(heading) * (18 + love.math.random() * 22),
    vy = -math.sin(heading) * (18 + love.math.random() * 22),
    t = 0,
    life = 0.18 + love.math.random() * 0.16,
    color = color or Theme.amber,
  }
end

function FX.toast(text, color)
  FX.toasts[#FX.toasts + 1] = {
    text = text,
    color = color or Theme.gold,
    t = 0,
    life = 2.2,
    y = 0,
  }
  while #FX.toasts > 5 do table.remove(FX.toasts, 1) end
end

function FX.update(dt)
  FX.t = (FX.t or 0) + dt
  FX.shake = math.max(0, (FX.shake or 0) - dt * 18)

  FX.dust = FX.dust or {}
  if #FX.dust < 18 and love.math.random() < dt * 7 then
    local c = Theme.cyan
    local r = love.math.random()
    if r < 0.33 then c = Theme.gold elseif r < 0.55 then c = Theme.magenta end
    FX.dust[#FX.dust + 1] = {
      x = love.math.random(4, math.max(8, Layout.vw - 4)),
      y = Layout.vh + 2,
      vy = -(8 + love.math.random() * 20),
      vx = (love.math.random() * 2 - 1) * 7,
      life = 2.2 + love.math.random() * 3,
      t = 0,
      c = c,
    }
  end

  for i = #FX.sparks, 1, -1 do
    local s = FX.sparks[i]
    s.t = s.t + dt
    s.x = s.x + s.vx * dt
    s.y = s.y + s.vy * dt
    -- air drag, so a spark decelerates instead of coasting in a straight line
    local drag = 1 - math.min(0.9, 2.2 * dt)
    s.vx = s.vx * drag
    if s.space ~= "world" then s.vy = s.vy * drag + 110 * dt else s.vy = s.vy * drag end
    if s.t >= s.life then table.remove(FX.sparks, i) end
  end
  for i = #FX.flashes, 1, -1 do
    local f = FX.flashes[i]
    f.t = f.t + dt
    if f.t >= f.life then table.remove(FX.flashes, i) end
  end
  for i = #FX.dust, 1, -1 do
    local d = FX.dust[i]
    d.t = d.t + dt
    d.x = d.x + d.vx * dt
    d.y = d.y + d.vy * dt
    if d.t >= d.life or d.y < -4 then table.remove(FX.dust, i) end
  end
  for i = #FX.waves, 1, -1 do
    local w = FX.waves[i]
    w.t = w.t + dt
    local u = math.min(1, w.t / w.life)
    w.r = 2 + (w.max - 2) * (1 - (1 - u) * (1 - u) * (1 - u))
    if w.t >= w.life then table.remove(FX.waves, i) end
  end
  for i = #FX.jets, 1, -1 do
    local j = FX.jets[i]
    j.t = j.t + dt
    j.x = j.x + j.vx * dt
    j.y = j.y + j.vy * dt
    if j.t >= j.life then table.remove(FX.jets, i) end
  end
  for i = #FX.toasts, 1, -1 do
    local t = FX.toasts[i]
    t.t = t.t + dt
    if t.t >= t.life then table.remove(FX.toasts, i) end
  end
end

function FX.drawWorld()
  for _, w in ipairs(FX.waves) do
    local a = Ease.outSine(1 - w.t / w.life) * 0.85
    love.graphics.setColor(w.color[1], w.color[2], w.color[3], a)
    love.graphics.circle("line", w.x, w.y, w.r)
    love.graphics.setColor(w.color[1], w.color[2], w.color[3], a * 0.25)
    love.graphics.circle("line", w.x, w.y, w.r * 0.72)
  end
  for _, j in ipairs(FX.jets) do
    local a = Ease.outSine(1 - j.t / j.life)
    love.graphics.setColor(j.color[1], j.color[2], j.color[3], a)
    love.graphics.rectangle("fill", math.floor(j.x), math.floor(j.y), 1, 1)
  end
  for _, s in ipairs(FX.sparks) do
    if s.space == "world" then
      local a = Ease.outSine(1 - s.t / s.life)
      love.graphics.setColor(s.color[1], s.color[2], s.color[3], a)
      love.graphics.rectangle("fill", math.floor(s.x), math.floor(s.y), s.s, s.s)
    end
  end
end

function FX.draw()
  for _, d in ipairs(FX.dust or {}) do
    local a = 0.4 * Ease.outSine(1 - d.t / d.life)
    love.graphics.setColor(d.c[1], d.c[2], d.c[3], a)
    love.graphics.rectangle("fill", math.floor(d.x), math.floor(d.y), 1, 1)
  end
  for _, s in ipairs(FX.sparks) do
    if s.space ~= "world" then
      local a = Ease.outSine(1 - s.t / s.life)
      love.graphics.setColor(s.color[1], s.color[2], s.color[3], a)
      love.graphics.rectangle("fill", math.floor(s.x), math.floor(s.y), s.s, s.s)
    end
  end
  for _, f in ipairs(FX.flashes) do
    local a = Ease.outSine(1 - f.t / f.life) * 0.45
    love.graphics.setColor(f.color[1], f.color[2], f.color[3], a)
    love.graphics.rectangle("fill", f.x, f.y, f.w, f.h)
  end
end

function FX.drawCursor()
  local vx, vy = Layout.mouse()
  if not vx then return end
  vx, vy = math.floor(vx), math.floor(vy)
  local pulse = 0.5 + 0.5 * math.sin(FX.t * 8)
  love.graphics.setColor(Theme.gold)
  love.graphics.rectangle("fill", vx - 5, vy, 11, 1)
  love.graphics.rectangle("fill", vx, vy - 5, 1, 11)
  love.graphics.setColor(Theme.void)
  love.graphics.rectangle("fill", vx, vy, 1, 1)
  love.graphics.setColor(Theme.magenta[1], Theme.magenta[2], Theme.magenta[3], 0.55 + 0.45 * pulse)
  love.graphics.rectangle("fill", vx + 4, vy + 4, 2, 1)
  love.graphics.rectangle("fill", vx + 4, vy + 4, 1, 2)
end

return FX
