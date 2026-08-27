--- The knight: what the harness is bolted onto.
---
--- Plain iron and nothing else: a breastplate, a gorget, pauldrons, a fauld,
--- a belt and a great helm, with no device on any of it. He is a knight the
--- way the one in Knightmare was a knight — the armour says nothing about the
--- man inside, because there is no man inside. What is bolted on *around* him
--- is the harness (`harness.lua`), and every module of it is a thing a
--- language model does not have on its own; knock them off and the iron is
--- all that is left, which is the joke Ghosts'n Goblins made first.
---
--- Shaded the way a 16-bit sprite was: three or four tones per material off a
--- fixed ramp, a hard ink outline, one light source (the moon, upper left) and
--- a warm rim from whatever torch is burning off to the right. Nothing here
--- fades an alpha to make a gradient.
---
--- States: `dormant` before the ROM is in, `idle`, `think` while the prompt is
--- read and reasoned over, `speak` while tokens arrive, `hurt` when a plate is
--- knocked off, `triumph` when the harness is complete.

local palette = require("src.palette")
local ui = require("src.ui")
local text = require("src.text")
local ease = require("src.ease")

local Avatar = {}
Avatar.__index = Avatar

local M = {}

-- Material ramps, lit to shade. A sprite picks a tone out of one of these
-- rather than naming a colour, so the 8-bit palettes can collapse them.
local STEEL  = { "moon", "silver", "steel", "gray" }
local LINEN  = { "bone", "olive", "rust" }
local LEATHER = { "rust", "maroon", "ink" }
local CLOAK  = { "red", "maroon", "wine" }

function M.new(x, y)
  return setmetatable({
    x = x or 240, y = y or 150,
    state = "dormant",
    time = 0,
    breath = 0,
    sway = 0,
    blink = 2.2,
    blink_for = 0,
    look = 0,          -- where the helm is pointed, -1 to 1
    look_to = 0,
    look_timer = 0,
    glow = 0,          -- the blade, and the eyes behind the slit
    speech = 0,
    flash = 0,
    shake = 0,
    lean = 0,
    power = 0,
    mood = 0,          -- 0 warm and idle, 1 cold and thinking
    orbit = 0,         -- where the sigils are, while it thinks
    rune_phase = 0,
  }, Avatar)
end

function Avatar:set_state(state)
  if self.state == state then return end
  self.state = state
  if state == "hurt" then
    self.flash, self.shake = 1, 1
  elseif state == "triumph" then
    self.flash = 0.6
  end
end

--- A token arrived: the blade takes the light of it.
function Avatar:said(chunk)
  self.speech = math.min(1, self.speech + 0.45 + math.min(#(chunk or ""), 6) * 0.05)
end

function Avatar:hit()
  self.flash, self.shake = 1, 1
  self:set_state("hurt")
end

function Avatar:update(dt, power)
  self.time = self.time + dt
  self.power = power or self.power

  -- Thinking breathes *slower*, not faster. It used to be the fastest of the
  -- three, and a torso quantised to whole pixels at that rate does not read
  -- as breathing -- it reads as a shiver.
  local rate = (self.state == "think" and 0.85) or (self.state == "speak" and 1.5) or 1.1
  self.breath = math.sin(self.time * rate)
  self.sway = math.sin(self.time * 0.75) + math.sin(self.time * 1.31) * 0.4

  local spin = (self.state == "think" and 0.9) or (self.state == "speak" and 0.55) or 0.25
  self.rune_phase = self.rune_phase + dt * spin * (1 + self.power)

  self.blink = self.blink - dt
  if self.blink <= 0 then
    self.blink = 2.0 + love.math.random() * 3.4
    self.blink_for = 0.10
  end
  self.blink_for = math.max(0, self.blink_for - dt)

  -- The helm turns to whatever it is attending to; while it is answering, to
  -- you.
  self.look_timer = self.look_timer - dt
  if self.look_timer <= 0 then
    self.look_timer = 1.1 + love.math.random() * 2.6
    self.look_to = self.state == "speak" and 0 or (love.math.random() - 0.5) * 1.6
  end
  self.look = self.look + (self.look_to - self.look) * math.min(dt * 6, 1)

  -- Leaning on the sword harder while it thinks.
  local lean_to = self.state == "think" and 1 or 0
  self.lean = self.lean + (lean_to - self.lean) * math.min(dt * 3, 1)

  -- The mood crossfades rather than switching: the light around him goes from
  -- torch-warm to arcane-cold over about half a second, and back. Snapping it
  -- was most of why thinking looked like a glitch.
  local mood_to = self.state == "think" and 1 or 0
  self.mood = self.mood + (mood_to - self.mood) * math.min(dt * 2.6, 1)
  -- The sigils orbit at a walking pace: they went round nearly once a second
  -- before, which is not thinking, it is panic.
  self.orbit = self.orbit + dt * (0.25 + self.mood * 0.45)

  self.speech = math.max(0, self.speech - dt * 3.2)
  local glow_to = math.max(self.speech, self.power * 0.45,
    self.state == "think" and 0.55 or 0.18)
  self.glow = self.glow + (glow_to - self.glow) * math.min(dt * 10, 1)

  self.flash = math.max(0, self.flash - dt * 2.2)
  self.shake = math.max(0, self.shake - dt * 1.8)
  if self.state == "hurt" and self.shake <= 0 then self:set_state("idle") end
end

--- Where the harness hangs its ring, and where a beam lands: the chest.
function Avatar:centre()
  return self.x, self.y + self.breath * 0.5
end

-- --------------------------------------------------------------- drawing ---

local function fill(slot, alpha, ...)
  palette.set(slot, alpha)
  love.graphics.polygon("fill", ...)
end

local function edge(slot, alpha, ...)
  palette.set(slot, alpha)
  love.graphics.polygon("line", ...)
end

local function box(slot, x, y, w, h, alpha)
  palette.set(slot, alpha)
  love.graphics.rectangle("fill", math.floor(x), math.floor(y), w, h)
end

--- The eye colour for the state — the only part of him that is not cloth,
--- leather or steel.
local function eye_slot(self, t)
  -- One colour per state. This used to cycle three of them six times a
  -- second, which did not read as thinking -- it read as a fault.
  if self.state == "think" then return "cyan" end
  if self.state == "speak" then return "flame" end
  if self.state == "hurt" then return "red" end
  if self.state == "dormant" then return "gray" end
  if self.state == "triumph" then return "white" end
  return "ember"
end

function Avatar:draw()
  local shake = self.shake > 0 and ease.ring(1 - self.shake, 38, 5) * 3 or 0
  local cx = math.floor(self.x + shake)
  local cy = math.floor(self.y)
  local t = self.time
  -- Whole pixels only, and one of them: `abs` folded the sine in half, so the
  -- torso popped twice per breath instead of once.
  local breath = self.breath > 0.4 and 1 or 0
  local hurt = self.state == "hurt"
  local drift = self.sway
  local feet = cy + 29
  local eyes = eye_slot(self, t)

  -- ---------------------------------------------------------- the ground --
  -- He is standing in a pool of torchlight, which is the only reason you can
  -- see him: everything behind him is a Bohemian street at night, and a
  -- figure with no light on him is a silhouette.
  -- A slow guttering, not a strobe: the 7 Hz component this had made the
  -- whole pool shimmer, and next to a figure holding still that reads as the
  -- figure trembling rather than the flame moving.
  local torch = 0.94 + math.sin(t * 1.7) * 0.04 + math.sin(t * 0.9) * 0.02
  -- Seven steps rather than three: at three the falloff is visibly a stack of
  -- ellipses, and a spotlight is not what a torch does. Both colours are laid
  -- down every frame with complementary alphas, so warm becomes cold by
  -- crossfade -- the palette has no blend, but the blend does.
  local cold = self.mood
  local pool_breath = 1 + math.sin(t * 1.1) * 0.05 * cold
  for i = 7, 1, -1 do
    local rx, ry = 8 + i * 5.5, 10 + i * 4.5
    if cold < 0.99 then
      palette.set("ember", 0.022 * i * torch * (1 - cold))
      love.graphics.ellipse("fill", cx, feet - 8, rx, ry)
    end
    if cold > 0.01 then
      -- The cold pool breathes, which the warm one does not: it is being
      -- pulled in and out rather than burning. One phase for all seven rings,
      -- because per-ring phases made them shimmer against each other.
      palette.set("teal", 0.020 * i * cold)
      love.graphics.ellipse("fill", cx, feet - 8, rx * pool_breath, ry * pool_breath)
    end
  end

  local circle = 0.22 + self.power * 0.45
  palette.set("ink", 0.45)
  love.graphics.ellipse("fill", cx, feet + 2, 17, 4)
  ui.ring(cx, feet + 2, 36, 30, self.rune_phase, "navy", circle, 1, 0.30)
  ui.ring(cx, feet + 2, 29, 8, -self.rune_phase * 1.6, "blue", circle * 0.9, 1, 0.30)
  for i = 0, 3 do
    local angle = self.rune_phase * 0.7 + i * math.pi / 2
    text.icon("rune",
      cx + math.cos(angle) * 35 - 2,
      feet + 2 + math.sin(angle) * 35 * 0.30 - 4,
      self.state == "think" and "cyan" or "navy", circle + 0.25)
  end

  -- ----------------------------------------------------------- the cloak --
  -- Behind him and narrow, so it frames the silhouette instead of becoming
  -- it. Two tones, and a hem that never stops moving.
  for side = -1, 1, 2 do
    local out = 13 + drift * side * 2
    fill("wine", 1,
      cx + side * 5, cy - 17,
      cx + side * out, cy - 4 + drift * side,
      cx + side * (out + 2), cy + 18,
      cx + side * (out - 1), cy + 25,
      cx + side * 4, cy + 22)
    edge("ink", 0.85,
      cx + side * 5, cy - 17,
      cx + side * out, cy - 4 + drift * side,
      cx + side * (out + 2), cy + 18,
      cx + side * (out - 1), cy + 25,
      cx + side * 4, cy + 22)
  end
  palette.set("maroon", 0.85)
  love.graphics.line(cx - 5, cy - 17, cx - 10 + drift * -2, cy - 4 - drift)

  -- ------------------------------------------------------------ the legs --
  -- Hose and boots, with a gap between them: at this size the gap is what
  -- makes them legs rather than a plinth.
  for side = -1, 1, 2 do
    local lx = side < 0 and (cx - 7) or (cx + 2)
    box("ink", lx - 1, cy + 9, 7, 16)
    box(palette.ramp(LINEN, side < 0 and 0.4 or 0.9), lx, cy + 10, 5, 14)
    box("ink", lx - 2, feet - 5, 9, 6)
    box(palette.ramp(LEATHER, side < 0 and 0 or 0.5), lx - 1, feet - 4, 7, 4)
    box("rust", lx - 1, feet - 4, 7, 1, 0.6)
  end

  -- ----------------------------------------------------------- the torso --
  local top = cy - 16 - breath

  -- The gambeson underneath: quilted linen, showing at the neck and under the
  -- arms, which is all of it you see once the plate is on.
  fill("ink", 1,
    cx - 10, top - 1, cx + 10, top - 1, cx + 9, cy + 3, cx - 9, cy + 3)
  fill(palette.ramp(LINEN, 0.5), 1,
    cx - 9, top, cx + 9, top, cx + 8, cy + 2, cx - 8, cy + 2)
  fill("ink", 1, cx - 10, cy + 2, cx + 10, cy + 2, cx + 10, cy + 11, cx - 10, cy + 11)
  fill(palette.ramp(LINEN, 0.5), 1, cx - 9, cy + 3, cx + 9, cy + 3, cx + 9, cy + 10, cx - 9, cy + 10)
  palette.set("olive", 0.5)
  for i = -7, 8, 4 do love.graphics.line(cx + i, cy + 4, cx + i, cy + 9) end

  -- ------------------------------------------------------ the breastplate --
  -- Plain iron. No device, no colours, nothing charged on it: a working
  -- harness of plate, the way the knight in Knightmare wore it. What it says
  -- about the man inside is nothing at all, which is the point of him.
  fill("ink", 1,
    cx - 9, top - 1, cx + 9, top - 1,
    cx + 10, cy + 1, cx + 7, cy + 4, cx - 7, cy + 4, cx - 10, cy + 1)
  fill(palette.ramp(STEEL, hurt and 0.85 or 0.5), 1,
    cx - 8, top, cx + 8, top,
    cx + 9, cy + 1, cx + 6, cy + 3, cx - 6, cy + 3, cx - 9, cy + 1)
  -- Moonlight down the left, shadow down the right, and the raised ridge that
  -- every breastplate has down its middle.
  fill(palette.ramp(STEEL, 0), 1,
    cx - 8, top, cx - 4, top, cx - 4, cy + 3, cx - 6, cy + 3, cx - 9, cy + 1)
  fill(palette.ramp(STEEL, 1), 1,
    cx + 4, top, cx + 8, top, cx + 9, cy + 1, cx + 6, cy + 3, cx + 4, cy + 3)
  box(palette.ramp(STEEL, 0), cx - 1, top + 2, 1, 13)
  box("ink", cx + 1, top + 2, 1, 13, 0.45)
  for i = -6, 6, 4 do box("ink", cx + i, top + 2, 1, 1, 0.7) end

  -- The gorget, under the chin.
  box("ink", cx - 6, top - 4, 12, 4)
  box(palette.ramp(STEEL, 0.25), cx - 5, top - 3, 10, 2)

  -- The fauld: three lames hanging off the belt, each narrower than the last.
  for i = 0, 2 do
    local w = 10 - i * 2
    box("ink", cx - w - 1, cy + 4 + i * 4, w * 2 + 2, 5)
    box(palette.ramp(STEEL, 0.35 + i * 0.2), cx - w, cy + 5 + i * 4, w * 2, 3)
    box(palette.ramp(STEEL, 0), cx - w, cy + 5 + i * 4, w * 2, 1, 0.45)
  end

  -- The belt, over the top lame. Iron buckle, not gold.
  box("ink", cx - 11, cy, 22, 5)
  box(palette.ramp(LEATHER, 0.2), cx - 10, cy + 1, 20, 3)
  box("ink", cx - 3, cy - 1, 6, 7)
  box(palette.ramp(STEEL, 0.3), cx - 2, cy, 4, 5)

  -- ------------------------------------------------------------ the arms --
  -- Both hang straight: a bent arm does not read at fifty-six pixels. The
  -- right one ends in a glove; the left one ends in the fist on the hilt,
  -- which is drawn with the sword so that there are not two hands on one arm.
  local reach = math.floor(self.lean)

  box("ink", cx + 6, top - 1, 6, 19)
  box(palette.ramp(LINEN, 0.5), cx + 7, top, 4, 15)
  box(palette.ramp(LINEN, 0.9), cx + 10, top, 1, 15)
  box("ink", cx + 6, cy + 1, 6, 7)
  box(palette.ramp(LEATHER, 0.4), cx + 7, cy + 2, 4, 5)
  box("rust", cx + 7, cy + 2, 4, 1, 0.7)

  box("ink", cx - 12, top - 1, 6, 16)
  box(palette.ramp(LINEN, 0.15), cx - 11, top, 4, 14)
  box(palette.ramp(LINEN, 0.5), cx - 8, top, 1, 14)

  -- Pauldrons: a cap of plate over the top of each arm, drawn after them so
  -- the shoulder overlaps the sleeve the way it does on a real harness.
  for side = -1, 1, 2 do
    local px = cx + side * 9
    fill("ink", 1,
      px - side * 5, top - 3, px + side * 5, top - 1,
      px + side * 5, top + 6, px - side * 5, top + 5)
    fill(palette.ramp(STEEL, side < 0 and 0.2 or 0.75), 1,
      px - side * 4, top - 2, px + side * 4, top,
      px + side * 4, top + 5, px - side * 4, top + 4)
  end

  -- ----------------------------------------------------------- the sword --
  -- Planted, point in the ground, the fist resting on the hilt at his hip.
  -- Everything in Ultima that ever stood still stood like this.
  local sx = cx - 13 - reach
  box("ink", sx - 1, cy + 13, 6, feet - cy - 10)
  box(palette.ramp(STEEL, 0.55), sx, cy + 14, 4, feet - cy - 12)
  box(palette.ramp(STEEL, 0), sx, cy + 14, 1, feet - cy - 12)      -- moonlit edge
  box(palette.ramp(STEEL, 1), sx + 3, cy + 14, 1, feet - cy - 12)  -- and the far one
  box("ink", sx - 5, cy + 9, 14, 4)                                -- the crossguard
  box(palette.ramp(STEEL, 0.25), sx - 4, cy + 10, 12, 2)
  box("ink", sx, cy, 4, 10)                                        -- the grip
  box(palette.ramp(LEATHER, 0.3), sx + 1, cy + 1, 2, 8)
  box("ink", sx - 1, cy - 4, 6, 5)                                 -- the pommel
  box("gold", sx, cy - 3, 4, 3)
  box("flame", sx + 1, cy - 2, 2, 1, 0.9)

  -- The fist, over the grip and over the end of the sleeve: one hand.
  box("ink", sx - 2, cy + 2, 8, 7)
  box(palette.ramp(LEATHER, 0), sx - 1, cy + 3, 6, 5)
  box("rust", sx - 1, cy + 3, 6, 1, 0.8)
  palette.set("ink", 0.7)
  for i = 0, 2 do love.graphics.rectangle("fill", sx + i * 2, cy + 4, 1, 3) end

  if self.glow > 0.05 then
    palette.set(self.state == "think" and "cyan" or "flame", self.glow * 0.45)
    love.graphics.rectangle("fill", sx - 2, cy + 13, 8, feet - cy - 10)
    palette.set("white", self.glow * 0.7)
    love.graphics.rectangle("fill", sx + 1, cy + 15, 1, feet - cy - 14)
  end

  -- ------------------------------------------------------------ the helm --
  local hx = cx + math.floor(self.look * 2)
  local hy = cy - 30 - breath
  fill("ink", 1,
    hx - 7, hy + 3, hx - 5, hy, hx + 5, hy, hx + 7, hy + 3,
    hx + 7, hy + 11, hx + 4, hy + 14, hx - 4, hy + 14, hx - 7, hy + 11)
  fill(palette.ramp(STEEL, hurt and 0.9 or 0.5), 1,
    hx - 6, hy + 3, hx - 4, hy + 1, hx + 4, hy + 1, hx + 6, hy + 3,
    hx + 6, hy + 10, hx + 3, hy + 13, hx - 3, hy + 13, hx - 6, hy + 10)
  fill(palette.ramp(STEEL, 0), 1,
    hx - 6, hy + 3, hx - 4, hy + 1, hx - 2, hy + 1, hx - 2, hy + 12, hx - 6, hy + 10)
  fill(palette.ramp(STEEL, 1), 1,
    hx + 3, hy + 1, hx + 4, hy + 1, hx + 6, hy + 3, hx + 6, hy + 10, hx + 3, hy + 12)

  -- The crest, swinging on its own.
  local crest = self.sway * 1.6
  for i = 0, 4 do
    box(i % 2 == 0 and "red" or "maroon",
      hx - 1 + math.floor(i * crest / 5), hy - 3 - i, 3, 2)
  end

  -- The visor: a slit, two eyes behind it, breathing holes below.
  box("ink", hx - 5, hy + 4, 11, 3)
  if self.blink_for <= 0 and not hurt then
    -- Brightness carries the state, not colour changes: a slow swell while it
    -- thinks, steady otherwise.
    local pulse = 1
    if self.mood > 0.02 then
      pulse = 1 - self.mood * 0.35 + self.mood * 0.35 * math.sin(t * 1.6)
    end
    palette.set(eyes, 0.4 * pulse)
    love.graphics.rectangle("fill", hx - 5, hy + 4, 11, 3)
    palette.set(eyes, pulse)
    love.graphics.rectangle("fill", hx - 4, hy + 5, 2, 1)
    love.graphics.rectangle("fill", hx + 2, hy + 5, 2, 1)
    palette.set("white", 0.85 * pulse)
    love.graphics.rectangle("fill", hx - 4, hy + 5, 1, 1)
    love.graphics.rectangle("fill", hx + 2, hy + 5, 1, 1)
  end
  palette.set("ink", 0.9)
  for i = -3, 3, 3 do love.graphics.rectangle("fill", hx + i, hy + 9, 1, 2) end

  -- ---------------------------------------------------------- the thinking --
  -- Three sigils on an orbit round the helm, scaled in by the mood rather
  -- than switched on. Each carries a short trail, and the one at the back of
  -- the orbit is dimmer than the one at the front, so the ring reads as going
  -- round him rather than flickering on a flat plane.
  if self.mood > 0.02 then
    for i = 0, 2 do
      local angle = self.orbit + i * (math.pi * 2 / 3)
      local depth = (math.sin(angle) + 1) / 2
      for tail = 2, 0, -1 do
        local a = angle - tail * 0.16
        local ox = math.cos(a) * (15 + self.mood * 5)
        local oy = math.sin(a) * 4.5 - 8
        local alpha = self.mood * (0.25 + depth * 0.6) / (1 + tail * 1.6)
        if tail == 0 then
          text.icon("rune", hx + ox - 2, hy + oy - 4, depth > 0.5 and "moon" or "teal", alpha)
        else
          palette.set("cyan", alpha)
          love.graphics.rectangle("fill", math.floor(hx + ox), math.floor(hy + oy), 1, 1)
        end
      end
    end
  end

  -- On a cold night in Bohemia you can see a man breathe.
  if self.state ~= "dormant" and math.sin(t * 1.1) > 0.94 then
    palette.set("moon", 0.18)
    love.graphics.ellipse("fill", hx + 7, hy + 10, 4 + math.sin(t * 9) * 1.5, 2)
  end

  if self.flash > 0.02 then
    palette.set(hurt and "red" or "white", self.flash * 0.45)
    love.graphics.rectangle("fill", cx - 20, cy - 32, 40, 64)
  end
end

return M
