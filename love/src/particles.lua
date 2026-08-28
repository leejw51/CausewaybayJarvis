--- Particles, drawn as whole pixels.
---
--- LÖVE has a particle system; this is not it. Everything here lands on the
--- canvas grid and takes one of the sixteen colours, walking a ramp of
--- palette roles as it ages instead of fading its alpha -- which is what a
--- machine with no alpha channel did, and what keeps a spark looking struck
--- rather than airbrushed.
---
---     local p = particles.new()
---     p:burst(x, y, 24, {ramp = {"white", "yellow", "gold", "red"}, speed = 60})
---     p:update(dt)  p:draw()

local palette = require("src.palette")
local text = require("src.text")

local System = {}
System.__index = System

local M = {}

local LIMIT = 900

function M.new()
  return setmetatable({ list = {}, gravity = 0 }, System)
end

local RAMPS = {
  fire   = { "white", "yellow", "gold", "orange", "red", "maroon" },
  arcane = { "white", "cyan", "blue", "navy" },
  holy   = { "white", "yellow", "gold", "silver" },
  steel  = { "white", "silver", "gray", "navy" },
  blood  = { "white", "orange", "red", "maroon" },
  life   = { "white", "lime", "green", "navy" },
  void   = { "magenta", "navy", "gray", "black" },
}
M.ramps = RAMPS

local function spawn(self, p)
  if #self.list >= LIMIT then table.remove(self.list, 1) end
  p.age = 0
  p.life = p.life or 1
  p.vx = p.vx or 0
  p.vy = p.vy or 0
  p.size = p.size or 1
  p.drag = p.drag or 0
  p.gravity = p.gravity or 0
  p.ramp = p.ramp or RAMPS.fire
  self.list[#self.list + 1] = p
  return p
end

local function ramp_of(options)
  local ramp = options and options.ramp
  if type(ramp) == "string" then return RAMPS[ramp] or RAMPS.fire end
  return ramp or RAMPS.fire
end

--- A radial burst: an impact, a plate seating, a hit taken.
function System:burst(x, y, count, options)
  options = options or {}
  local ramp = ramp_of(options)
  local speed = options.speed or 50
  local spread = options.spread or math.pi * 2
  local heading = options.heading or 0
  for _ = 1, count do
    local angle = heading + (love.math.random() - 0.5) * spread
    local v = speed * (0.35 + love.math.random() * 0.85)
    spawn(self, {
      x = x, y = y,
      vx = math.cos(angle) * v,
      vy = math.sin(angle) * v,
      life = (options.life or 0.7) * (0.6 + love.math.random() * 0.8),
      drag = options.drag or 1.8,
      gravity = options.gravity or 0,
      size = options.size or 1,
      ramp = ramp,
      glyph = options.glyph,
      spin = options.spin,
    })
  end
end

--- A ring that expands: a shockwave, a rune circle firing.
function System:ring(x, y, count, options)
  options = options or {}
  local ramp = ramp_of(options)
  local speed = options.speed or 40
  local radius = options.radius or 0
  for i = 1, count do
    local angle = (i / count) * math.pi * 2 + (options.phase or 0)
    spawn(self, {
      x = x + math.cos(angle) * radius,
      y = y + math.sin(angle) * radius * (options.squash or 1),
      vx = math.cos(angle) * speed,
      vy = math.sin(angle) * speed * (options.squash or 1),
      life = options.life or 0.6,
      drag = options.drag or 2.4,
      size = options.size or 1,
      ramp = ramp,
      glyph = options.glyph,
    })
  end
end

--- Motes drifting up out of a rectangle: embers off candles, dust in a shaft
--- of light, the hall breathing.
function System:rise(x, y, width, count, options)
  options = options or {}
  local ramp = ramp_of(options)
  for _ = 1, count do
    spawn(self, {
      x = x + love.math.random() * width,
      y = y + (options.height and love.math.random() * options.height or 0),
      vx = (love.math.random() - 0.5) * (options.drift or 6),
      vy = -(options.speed or 8) * (0.5 + love.math.random()),
      life = (options.life or 2.4) * (0.6 + love.math.random() * 0.8),
      drag = options.drag or 0.2,
      size = options.size or 1,
      wave = options.wave or 0,
      ramp = ramp,
      glyph = options.glyph,
    })
  end
end

--- Pulled inwards instead of thrown outwards: the core drawing power in
--- while it thinks. `target` is where they converge.
function System:draw_in(x, y, count, options)
  options = options or {}
  local ramp = ramp_of(options)
  local radius = options.radius or 60
  for _ = 1, count do
    local angle = love.math.random() * math.pi * 2
    spawn(self, {
      x = x + math.cos(angle) * radius,
      y = y + math.sin(angle) * radius,
      life = options.life or 0.9,
      size = options.size or 1,
      ramp = ramp,
      glyph = options.glyph,
      pull = { x = x, y = y, force = options.force or 300 },
      drag = options.drag or 1.0,
    })
  end
end

--- Debris that falls and bounces once: a plate of armour knocked off.
function System:shards(x, y, count, options)
  options = options or {}
  local ramp = ramp_of(options)
  for _ = 1, count do
    local angle = -math.pi / 2 + (love.math.random() - 0.5) * 2.2
    local v = (options.speed or 90) * (0.5 + love.math.random())
    spawn(self, {
      x = x, y = y,
      vx = math.cos(angle) * v,
      vy = math.sin(angle) * v,
      life = options.life or 1.6,
      gravity = options.gravity or 260,
      drag = 0.4,
      floor = options.floor,
      bounce = options.bounce or 0.45,
      size = options.size or 2,
      ramp = ramp,
      glyph = options.glyph,
      spin = (love.math.random() - 0.5) * 12,
      angle = 0,
    })
  end
end

function System:add(p) return spawn(self, p) end

function System:clear() self.list = {} end
function System:count() return #self.list end

function System:update(dt)
  local list = self.list
  local i = 1
  while i <= #list do
    local p = list[i]
    p.age = p.age + dt
    if p.age >= p.life then
      table.remove(list, i)
    else
      if p.pull then
        local dx, dy = p.pull.x - p.x, p.pull.y - p.y
        local distance = math.max(math.sqrt(dx * dx + dy * dy), 1)
        local force = p.pull.force / distance
        p.vx = p.vx + dx / distance * force * dt
        p.vy = p.vy + dy / distance * force * dt
      end
      p.vy = p.vy + p.gravity * dt
      local drag = 1 - math.min(p.drag * dt, 0.9)
      p.vx, p.vy = p.vx * drag, p.vy * drag
      p.x = p.x + p.vx * dt
      p.y = p.y + p.vy * dt
      if p.spin then p.angle = (p.angle or 0) + p.spin * dt end
      if p.floor and p.y > p.floor and p.vy > 0 then
        p.y = p.floor
        p.vy = -p.vy * p.bounce
        p.vx = p.vx * 0.7
      end
      i = i + 1
    end
  end
end

function System:draw()
  for _, p in ipairs(self.list) do
    local fraction = p.age / p.life
    local slot = palette.ramp(p.ramp, fraction)
    local x = p.x
    if p.wave and p.wave > 0 then
      x = x + math.sin(p.age * 3 + p.y * 0.2) * p.wave
    end
    if p.glyph then
      text.icon(p.glyph, math.floor(x) - 2, math.floor(p.y) - 4, slot)
    else
      palette.set(slot)
      local size = p.size
      -- Shrink to a single pixel as it dies: sixteen colours cannot fade, so
      -- the shape has to.
      if fraction > 0.7 then size = math.max(1, size - 1) end
      love.graphics.rectangle("fill", math.floor(x), math.floor(p.y), size, size)
    end
  end
end

return M
