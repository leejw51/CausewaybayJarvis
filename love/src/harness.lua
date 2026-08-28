--- The harness: what gets bolted onto a bare model.
---
--- A language model on its own is a thing that continues text. Everything that
--- makes it an *agent* -- memory, tools, retrieval, a planner, a critic, a
--- sandbox to run what it writes -- is strapped on around it. This module is
--- the registry for those straps, and the ring of sockets you can see around
--- the core is that registry drawn.
---
--- **Nothing here is wired to the model yet, and that is deliberate.** What
--- exists now is the shape: a module declares itself, takes a socket, and gets
--- called at the points in a turn where a real implementation would do its
--- work. Fill in the hooks and the effects stop being only effects.
---
---     harness.register{
---       id = "memory", name = "MEMORY", glyph = "book", slot = "cyan",
---       blurb = "keeps what was said, and what it meant",
---       on_turn_start = function(module, ctx)
---         ctx.prompt = recall(ctx.prompt)     -- one day
---       end,
---     }
---
--- The hooks, in the order a turn fires them:
---
---   `on_equip(module, ctx)`       bolted on
---   `on_turn_start(module, ctx)`  ctx.prompt is the user's text, and may be
---                                 rewritten in place
---   `on_prefill(module, ctx)`     ctx.done / ctx.total tokens read
---   `on_reasoning(module, ctx)`   ctx.text, a chunk of the think block
---   `on_token(module, ctx)`       ctx.text, a chunk of the answer
---   `on_turn_end(module, ctx)`    ctx.reply, ctx.stats
---   `on_error(module, ctx)`       ctx.message
---   `on_remove(module, ctx)`      knocked off
---
--- A hook that raises is caught, reported once, and the module is knocked off
--- rather than allowed to take the turn down with it -- which is the same
--- bargain the C ABI makes with a Lua callback.

local ease = require("src.ease")
local palette = require("src.palette")
local text = require("src.text")
local ui = require("src.ui")

local M = {
  modules = {},      -- in registration order
  index = {},        -- by id
  layout_radius = 46,
  centre = { x = 0, y = 0 },
}

--- Set by the scene to hear about equips, hits and hook firings, so that this
--- module never has to know what a particle is.
M.on_event = nil

local function announce(kind, module, extra)
  if M.on_event then M.on_event(kind, module, extra) end
end

-- --------------------------------------------------------------- registry --

function M.register(def)
  assert(def.id, "a harness module needs an id")
  assert(not M.index[def.id], "harness module '" .. def.id .. "' is already registered")
  local module = {
    id = def.id,
    name = def.name or def.id:upper(),
    glyph = def.glyph or "chip",
    slot = def.slot or "silver",
    ramp = def.ramp or "steel",
    blurb = def.blurb or "",
    key = def.key,
    tier = def.tier or 1,
    hooks = {},
    -- Runtime.
    equipped = false,
    power = 0,          -- 0 empty socket, 1 seated and lit
    heat = 0,           -- flares to 1 when one of its hooks fires
    x = 0, y = 0, tx = 0, ty = 0,
    scale = 0,
    angle = 0,
  }
  for _, hook in ipairs({ "on_equip", "on_remove", "on_turn_start", "on_prefill",
                          "on_reasoning", "on_token", "on_turn_end", "on_error" }) do
    module.hooks[hook] = def[hook]
  end
  M.modules[#M.modules + 1] = module
  M.index[def.id] = module
  M.layout()
  return module
end

function M.get(id) return M.index[id] end
function M.all() return M.modules end
function M.count() return #M.modules end

function M.equipped()
  local out = {}
  for _, module in ipairs(M.modules) do
    if module.equipped then out[#out + 1] = module end
  end
  return out
end

function M.equipped_count()
  local n = 0
  for _, module in ipairs(M.modules) do if module.equipped then n = n + 1 end end
  return n
end

--- How much of the suit is on, 0 to 1. The aura, the music and the colour of
--- the core all read from this.
function M.power()
  if #M.modules == 0 then return 0 end
  local sum = 0
  for _, module in ipairs(M.modules) do sum = sum + module.power end
  return sum / #M.modules
end

--- Place every module on a ring around the core. Recomputed whenever one is
--- registered, so a harness added later just takes the next socket and the
--- others shuffle round to make room.
function M.layout(cx, cy, radius)
  M.centre.x = cx or M.centre.x
  M.centre.y = cy or M.centre.y
  M.layout_radius = radius or M.layout_radius
  local n = #M.modules
  for i, module in ipairs(M.modules) do
    local angle = -math.pi / 2 + (i - 1) / math.max(n, 1) * math.pi * 2
    module.orbit = angle
    module.tx = M.centre.x + math.cos(angle) * M.layout_radius
    module.ty = M.centre.y + math.sin(angle) * M.layout_radius * 0.78
    if not module.animating and module.equipped then
      module.x, module.y = module.tx, module.ty
    end
  end
end

-- ----------------------------------------------------------- equip / lose --

--- Bolt a module on. It flies in from off the edge nearest its socket, which
--- is the Iron Man shot: the piece arrives from somewhere else and finds you.
function M.equip(id, options)
  local module = M.index[id]
  if not module or module.equipped then return false end
  options = options or {}
  module.equipped = true

  local angle = module.orbit or 0
  local from = options.from or 260
  module.x = M.centre.x + math.cos(angle) * from
  module.y = M.centre.y + math.sin(angle) * from - 40
  module.scale = 0
  module.spin = 0
  module.animating = { mode = "in", t = 0, dur = options.duration or 0.5,
                       fx = module.x, fy = module.y }

  local ok, err = M.fire_one(module, "on_equip", { module = module })
  if not ok then return false, err end
  announce("equip", module)
  return true
end

--- Knock one off. `violent` is the Ghosts'n Goblins version: it tumbles away
--- with gravity instead of powering down politely.
function M.remove(id, violent)
  local module = M.index[id]
  if not module or not module.equipped then return false end
  module.equipped = false
  M.fire_one(module, "on_remove", { module = module, violent = violent or false })
  if violent then
    local away = (module.x < M.centre.x) and -1 or 1
    module.animating = {
      mode = "fly", t = 0, dur = 1.4,
      vx = away * (80 + love.math.random() * 70),
      vy = -(110 + love.math.random() * 60),
      spin = away * (6 + love.math.random() * 6),
    }
  else
    module.animating = { mode = "out", t = 0, dur = 0.35 }
  end
  announce(violent and "lost" or "remove", module)
  return true
end

function M.toggle(id)
  local module = M.index[id]
  if not module then return false end
  if module.equipped then return M.remove(id) end
  return M.equip(id)
end

--- The whole suit, one piece at a time. Returns how long the sequence takes,
--- so the scene can hold the camera on it.
function M.suit_up(timeline, gap)
  gap = gap or 0.13
  local at = 0
  for _, module in ipairs(M.modules) do
    if not module.equipped then
      local id = module.id
      timeline:after(at, function() M.equip(id) end)
      at = at + gap
    end
  end
  if at > 0 then
    timeline:after(at + 0.1, function() announce("suitup", nil) end)
  end
  return at
end

--- Everything off, fast and badly. What a hit does.
function M.strip(violent)
  local lost = {}
  for _, module in ipairs(M.modules) do
    if module.equipped then lost[#lost + 1] = module.id end
  end
  for _, id in ipairs(lost) do M.remove(id, violent ~= false) end
  return #lost
end

--- Knock one piece off at random -- a glancing blow.
function M.lose_one()
  local on = M.equipped()
  if #on == 0 then return nil end
  local module = on[love.math.random(#on)]
  M.remove(module.id, true)
  return module
end

-- ------------------------------------------------------------------ hooks --

function M.fire_one(module, hook, ctx)
  local fn = module.hooks[hook]
  if not fn then return true end
  local ok, err = pcall(fn, module, ctx)
  if not ok then
    module.equipped = false
    module.animating = { mode = "fly", t = 0, dur = 1.4, vx = 60, vy = -120, spin = 8 }
    announce("fault", module, tostring(err))
    return false, tostring(err)
  end
  module.heat = 1
  return true
end

--- Fire one point of the turn at every equipped module, in socket order.
--- `ctx` is shared and may be rewritten by a module -- that is the point of
--- `on_turn_start` getting `ctx.prompt`.
function M.emit(hook, ctx)
  ctx = ctx or {}
  local fired = 0
  for _, module in ipairs(M.modules) do
    if module.equipped and module.hooks[hook] then
      if M.fire_one(module, hook, ctx) then fired = fired + 1 end
    end
  end
  if fired > 0 then announce("fired", nil, hook) end
  return ctx, fired
end

-- ------------------------------------------------------- update and draw --

function M.update(dt)
  for _, module in ipairs(M.modules) do
    module.heat = math.max(0, module.heat - dt * 2.2)

    local target = module.equipped and 1 or 0
    module.power = module.power + (target - module.power) * math.min(dt * 6, 1)

    local anim = module.animating
    if anim then
      anim.t = anim.t + dt
      local p = math.min(anim.t / anim.dur, 1)
      if anim.mode == "in" then
        local eased = ease.outBack(p)
        module.x = anim.fx + (module.tx - anim.fx) * eased
        module.y = anim.fy + (module.ty - anim.fy) * eased
        module.scale = ease.outBack(math.min(p * 1.4, 1))
        module.spin = (1 - p) * 10
        if p >= 1 then
          module.animating = nil
          module.x, module.y, module.scale, module.spin = module.tx, module.ty, 1, 0
          announce("seated", module)
        end
      elseif anim.mode == "out" then
        module.scale = 1 - ease.inQuad(p)
        if p >= 1 then module.animating = nil module.scale = 0 end
      elseif anim.mode == "fly" then
        anim.vy = anim.vy + 320 * dt
        module.x = module.x + anim.vx * dt
        module.y = module.y + anim.vy * dt
        module.spin = (module.spin or 0) + anim.spin * dt
        module.scale = math.max(0, 1 - ease.inQuint(p))
        if p >= 1 then module.animating = nil module.scale = 0 end
      end
    elseif module.equipped then
      -- Seated: breathe on the socket, so a full suit is never quite still.
      module.x = module.tx + math.sin(love.timer.getTime() * 1.6 + module.orbit * 3) * 1.2
      module.y = module.ty + math.cos(love.timer.getTime() * 1.3 + module.orbit * 3) * 1.2
      module.scale = 1
      module.spin = 0
    end
  end
end

--- One module, as a chip on its socket. An empty socket is drawn too -- a
--- dotted outline where the plate should be, which is what makes losing one
--- read as damage rather than as a missing feature.
local function draw_module(module, time)
  local x, y = math.floor(module.x) - 4, math.floor(module.y) - 5
  if module.scale <= 0.02 and not module.equipped then
    -- Empty socket.
    palette.set("gray", 0.45)
    love.graphics.rectangle("line", math.floor(module.tx) - 4.5, math.floor(module.ty) - 5.5, 9, 11)
    text.icon(module.glyph, math.floor(module.tx) - 2, math.floor(module.ty) - 4, "gray", 0.35)
    return
  end

  local scale = module.scale
  local heat = module.heat

  -- The chip: a plate with the module's glyph on it, lit by its own colour.
  love.graphics.push()
  love.graphics.translate(math.floor(module.x), math.floor(module.y))
  love.graphics.rotate((module.spin or 0) * 0.12)
  love.graphics.scale(scale, scale)

  palette.set("black", 0.85)
  love.graphics.rectangle("fill", -5, -6, 11, 13)
  palette.set(heat > 0.1 and "white" or module.slot, 0.9)
  love.graphics.rectangle("line", -5.5, -6.5, 12, 14)
  text.icon(module.glyph, -2, -4, heat > 0.4 and "white" or module.slot)

  -- A halo while a hook of this module is running.
  if heat > 0.05 then
    ui.ring(0, 0, 9 + (1 - heat) * 7, 10, time * 4, "white", heat * 0.8, 1)
  end
  love.graphics.pop()
end

--- The whole ring. `centre` is the core; beams run from it to each seated
--- plate, drifting outward so the suit looks powered rather than glued.
function M.draw(time)
  local cx, cy = M.centre.x, M.centre.y
  for _, module in ipairs(M.modules) do
    if module.power > 0.05 and not (module.animating and module.animating.mode == "fly") then
      ui.beam(cx, cy, module.x, module.y, module.slot,
        0.25 + module.power * 0.35 + module.heat * 0.4, 4, time * 1.5 % 1)
    end
  end
  for _, module in ipairs(M.modules) do draw_module(module, time) end
end

-- ------------------------------------------------------------ the modules --

--- The suit as it ships: eight sockets, none of them wired up. The order is
--- the order they take sockets in, which is the order `suit up` bolts them on.
function M.load()
  local function add(def) M.register(def) end

  add{ id = "memory", name = "MEMORY", glyph = "book", slot = "cyan", ramp = "arcane",
       key = "1", blurb = "keeps what was said, and what it meant" }
  add{ id = "tools", name = "TOOL RIG", glyph = "gear", slot = "gold", ramp = "holy",
       key = "2", blurb = "hands: the shell, the files, the network" }
  add{ id = "seeker", name = "SEEKER", glyph = "key", slot = "lime", ramp = "life",
       key = "3", blurb = "reads the library before it answers" }
  add{ id = "planner", name = "PLANNER", glyph = "crown", slot = "magenta", ramp = "void",
       key = "4", blurb = "decides the order of the work" }
  add{ id = "warden", name = "WARDEN", glyph = "shield", slot = "red", ramp = "blood",
       key = "5", blurb = "argues with the answer before you see it" }
  add{ id = "sandbox", name = "SANDBOX", glyph = "chip", slot = "silver", ramp = "steel",
       key = "6", blurb = "runs what it writes, where it cannot bite" }
  add{ id = "eye", name = "THE EYE", glyph = "eye", slot = "yellow", ramp = "holy",
       key = "7", blurb = "looks at pictures, and at screens" }
  add{ id = "vox", name = "VOX", glyph = "bolt", slot = "orange", ramp = "fire",
       key = "8", blurb = "speaks aloud, and listens back" }

  return M
end

--- Take everything off with no animation and no announcement.
---
--- The boot screen wears the harness as a progress bar — a plate per eighth of
--- the download — and the chat scene must still start bare, because a bare
--- model is the whole point of it. This is how the one hands over to the other
--- without a shower of sparks nobody asked for.
function M.reset_silent()
  for _, module in ipairs(M.modules) do
    module.equipped = false
    module.animating = nil
    module.power = 0
    module.heat = 0
    module.scale = 0
  end
end

--- Light every equipped module for a moment, as though its hook had run.
---
--- With nothing wired to the hooks yet this is the only mark a turn leaves on
--- the harness, and it is what makes the ring look like it is doing something.
--- When the hooks are real, delete it: `fire_one` already lights what it calls.
function M.pulse(fraction)
  for _, module in ipairs(M.modules) do
    if module.equipped and love.math.random() < (fraction or 1) then
      module.heat = 1
    end
  end
end

--- Look a module up by the key that toggles it.
function M.by_key(key)
  for _, module in ipairs(M.modules) do
    if module.key == key then return module end
  end
end

return M
