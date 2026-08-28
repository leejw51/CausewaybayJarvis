--- Turning the machine on.
---
--- The tube warms up, the BIOS counts the memory it has, both slots report
--- empty, and nothing else happens until a cartridge goes into slot one.
--- That is the conceit the whole client is built on: the model is a ROM, and
--- an agent is what you get when you plug it in.
---
--- The weights are loading on the worker thread through all of this. On a
--- machine that has them the fifteen gigabytes take about as long as the boot
--- does, which is not an accident -- the boot is as long as it is because a
--- progress bar you cannot skip is nicer than a frozen window.

local palette = require("src.palette")
local text = require("src.text")
local ui = require("src.ui")
local sfx = require("src.sfx")
local art = require("src.art")
local app = require("src.app")
local toggles = require("src.toggles")
local harness = require("src.harness")
local settings = require("src.settings")
local ease = require("src.ease")

local S = {}

local RAM_KB = 36864

--- Where the machine's furniture goes, for whichever way up the screen is.
--- Computed rather than constant, because the client can be turned while it
--- is booting and a cartridge slot half off the edge is not a slot.
local function geometry()
  local W, H = app.W, app.H
  local slot_w = math.min(120, W - 48)
  local panel_w = math.min(240, W - 32)
  local gauge_w = math.min(200, W - 60)
  return {
    W = W, H = H,
    post = { x = math.max(8, math.floor(W * 0.05)), y = math.floor(H * 0.08) },
    slot = { x = math.floor((W - slot_w) / 2), y = math.floor(H * 0.44), w = slot_w },
    cart = { x = math.floor(W / 2), park = math.floor(H * 0.78), away = H + 60 },
    logo = { y = math.floor(H * 0.17) },
    -- Three rows and a title, at whatever size the letters are: a fixed
    -- sixty-two pixels printed CONTEXT through the bottom border.
    panel = { x = math.floor((W - panel_w) / 2), y = math.floor(H * 0.50),
              w = panel_w, h = text.height() * 4 + 16 },
    gauge = { x = math.floor((W - gauge_w) / 2), y = math.floor(H * 0.80), w = gauge_w },
  }
end

local POST = {
  { label = "MAIN RAM", value = "$RAM KB", ok = true, count = true },
  { label = "VIDEO", value = "V9958  512 KB", ok = true },
  { label = "GPU", value = "APPLE SILICON / METAL", ok = true },
  { label = "MLX", value = "ONE QUEUE, NO BATCHING", ok = true },
  { label = "TOKENIZER", value = "BPE  151936 TOKENS", ok = true },
  { label = "SLOT 1", value = "-- EMPTY --", ok = false },
  { label = "SLOT 2", value = "-- EMPTY --", ok = false },
}

function S:enter()
  self.phase = "warmup"
  self.t = 0
  self.lines = {}
  self.ram = 0
  local g = geometry()
  self.cart = { y = g.cart.away, x = g.cart.x, angle = 0, scale = 1 }
  self.beam = 0
  self.blink = 0
  self.logo = { scale = 0, y = 60 }
  self.slot_flash = 0
  self.skipped = false
  self.hotspots = {}
  app.timeline:clear()

  -- The tube: a line, then a picture.
  app.timeline:run(0.55, "outQuart", function(p) self.beam = p end)
  app.timeline:after(0.12, function() sfx.play("boot") end)
  app.timeline:after(0.6, function() self:start_post() end)
end

function S:leave()
  app.timeline:clear()
  app.toast_mute = false
  -- The suit was the progress bar. The chat starts bare, because a bare model
  -- is the point of it.
  harness.reset_silent()
end

-- ------------------------------------------------------------------ post ---

function S:start_post()
  if self.phase ~= "warmup" then return end
  self.phase = "post"
  local at = 0
  for i, row in ipairs(POST) do
    app.timeline:after(at, function()
      self.lines[#self.lines + 1] = i
      sfx.play("key", 0.8 + i * 0.05)
      if row.count then
        app.timeline:run(0.8, "outQuad", function(p)
          self.ram = math.floor(p * RAM_KB)
          if math.floor(p * 40) % 3 == 0 then sfx.play("page", 1.4) end
        end)
      end
    end)
    at = at + (row.count and 0.95 or 0.18)
  end
  app.timeline:after(at + 0.3, function() self:await_cartridge() end)
end

function S:skip_post()
  if self.phase ~= "post" and self.phase ~= "warmup" then return end
  app.timeline:clear()
  self.lines = {}
  for i = 1, #POST do self.lines[i] = i end
  self.ram = RAM_KB
  self.beam = 1
  self:await_cartridge()
end

function S:await_cartridge()
  local g = geometry()
  self.phase = "waiting"
  self.cart.x, self.cart.y = g.cart.x, g.cart.away
  app.timeline:to(self.cart, 0.7, { y = g.cart.park }, "outBack")
  sfx.play("open")
end

-- ------------------------------------------------------------- the insert --

function S:insert()
  if self.phase ~= "waiting" then return end
  self.phase = "inserting"
  sfx.play("insert")

  -- Up into the slot, overshooting once, then seated.
  local g = geometry()
  local mouth = g.slot.y + 24
  app.timeline:to(self.cart, 0.42, { y = mouth }, "inQuad")
  app.timeline:after(0.42, function()
    app.shake(1.1)
    app.fx:burst(g.cart.x, mouth - 8, 30, { ramp = "holy", speed = 90, life = 0.6 })
    app.fx:ring(g.cart.x, mouth - 8, 18, { ramp = "fire", speed = 70, life = 0.5, radius = 8 })
    sfx.play("clank", 0.8)
    self.slot_flash = 1
  end)
  app.timeline:to(self.cart, 0.5, { y = g.slot.y + 8, scale = 0.6 }, "outElastic", 0.42)

  -- The machine notices, badly, and then well.
  app.timeline:after(0.72, function()
    app.glitch(1)
    app.flash(0.7, "white")
    sfx.play("error", 1.6)
  end)
  app.timeline:after(1.15, function()
    sfx.play("rom")
    app.flash(0.5, "cyan")
    self:begin_arming()
  end)
end

--- The armouring.
---
--- Everything the machine has to do before it can answer — fetch fifteen
--- gigabytes, then map them — is shown as the knight being put into his
--- harness, a plate at a time. The download drives it directly: an eighth of
--- the bytes is a piece of armour, and the last one lands as the model comes
--- up. When the weights are already on disk there is nothing to wait for and
--- the whole suit goes on in about two seconds, which is the honest length of
--- the wait rather than a bar padded out to look like work.
function S:begin_arming()
  self.phase = "arming"
  self.plates = 0
  self.mount = 0
  self.armoured = false
  app.toast_mute = true

  -- The forge. None of it makes the download go faster and it says so; it is
  -- here because fifteen gigabytes is a long time to watch a bar, and an anvil
  -- you can hit is a better thing to do with the wait.
  self.strikes = 0
  self.combo = 0
  self.best_combo = 0
  self.heat = 0
  self.ring = 0
  self.hammer = 0
  self.perfect = 0
  self.white_hot = 0

  app.avatar.x = math.floor(app.W / 2)
  app.avatar.y = math.floor(app.H * 0.40)
  app.avatar:set_state("think")
  harness.reset_silent()
  harness.layout(app.avatar.x, app.avatar.y - 2,
    math.max(42, math.min(64, math.floor(math.min(app.W, app.H) * 0.24))))
  sfx.play("charge")
end

--- The last plate, and the model with it.
function S:finish_arming()
  if self.armoured then return end
  self.armoured = true
  app.avatar:set_state("triumph")
  app.flash(0.85, "white")
  app.shake(1.4)
  sfx.play("suitup")
  local cx, cy = app.avatar:centre()
  app.fx:ring(cx, cy, 44, { ramp = "holy", speed = 130, life = 1.0, radius = 8 })
  app.fx:burst(cx, cy, 70, { ramp = "holy", speed = 100, life = 1.2 })
  app.timeline:after(1.1, function() self:show_title() end)
end

function S:show_title()
  self.phase = "title"
  app.toast_mute = false
  self.logo.scale = 0
  app.timeline:to(self.logo, 0.75, { scale = 3 }, "outBack")
  app.timeline:every(0.10, function()
    app.bg_fx:rise(app.W * 0.12, app.H - 20, app.W * 0.76, 1,
      { ramp = "fire", speed = 12, life = 3.2, wave = 3 })
  end)
end

-- ---------------------------------------------------------------- update ---

--- Hit the anvil. `on_beat` is how close the timing ring was to closing.
function S:strike()
  if self.phase ~= "arming" then return end
  local shrink = self.ring
  local perfect = shrink > 0.82
  self.strikes = self.strikes + 1
  self.hammer = 1
  self.ring = 0

  if perfect then
    self.combo = self.combo + 1
    self.best_combo = math.max(self.best_combo, self.combo)
    self.perfect = 1
    self.heat = math.min(1, self.heat + 0.16)
    app.shake(0.9)
    sfx.play("clank", 1.0 + math.min(self.combo, 8) * 0.06)
    sfx.play("select", 1.4 + math.min(self.combo, 6) * 0.08, 0.5)
  else
    self.combo = 0
    self.heat = math.min(1, self.heat + 0.06)
    app.shake(0.45)
    sfx.play("clank", 0.72 + love.math.random() * 0.1)
  end

  -- Sparks off the anvil, and a few of them drawn into the knight.
  local ax, ay = self:anvil()
  app.fx:burst(ax, ay - 6, perfect and 26 or 12, {
    ramp = "fire", speed = perfect and 120 or 70,
    life = 0.6, spread = 2.2, heading = -math.pi / 2, gravity = 220,
  })
  local cx, cy = app.avatar:centre()
  app.fx:draw_in(cx, cy, perfect and 8 or 3, { ramp = "fire", radius = 46, life = 0.5 })

  if self.heat >= 1 then
    self.heat = 0.35
    self.white_hot = 1
    app.flash(0.5, "flame")
    app.shake(1.2)
    sfx.play("suitup", 1.2, 0.7)
    app.fx:ring(cx, cy, 30, { ramp = "fire", speed = 110, life = 0.8, radius = 6 })
  end
end

--- Where the anvil stands.
function S:anvil()
  return math.floor(app.W / 2), math.floor(app.H * 0.60)
end

--- One plate per eighth of the work, whatever the work is.
function S:arm(dt)
  local total = harness.count()
  local want
  if app.download and (app.download.total or 0) > 0 then
    want = math.floor(math.max(0, math.min(1, app.download.fraction)) * total)
  else
    -- Nothing to fetch: the wait is `jarvis_open` mapping the weights, which
    -- reports no progress at all, so the suit goes on at a fixed rate and the
    -- model coming up finishes it.
    self.mount = self.mount + dt
    want = math.min(total, math.floor(self.mount / 0.22))
  end
  if app.ready then want = total end

  while self.plates < math.min(want, total) do
    self.plates = self.plates + 1
    local module = harness.all()[self.plates]
    if module then harness.equip(module.id) end
  end

  -- The forge: sparks drawn into him, embers off the floor, and the odd
  -- hammer-fall on the plate that just landed.
  local cx, cy = app.avatar:centre()
  if love.math.random() < dt * 26 then
    app.fx:draw_in(cx, cy, 1, { ramp = "fire", radius = 40 + love.math.random() * 40, life = 0.55 })
  end
  if love.math.random() < dt * 14 then
    app.bg_fx:rise(cx - 40, cy + 34, 80, 1, { ramp = "fire", speed = 16, life = 1.8, wave = 3 })
  end

  -- The forge itself: a ring that closes once a second, a heat that fades.
  self.ring = self.ring + dt / 1.05
  if self.ring >= 1 then self.ring = 0 end
  self.hammer = math.max(0, self.hammer - dt * 4)
  self.perfect = math.max(0, self.perfect - dt * 2)
  self.white_hot = math.max(0, self.white_hot - dt * 1.2)
  self.heat = math.max(0, self.heat - dt * 0.05)

  if app.ready and self.plates >= total then self:finish_arming() end
end

function S:update(dt)
  self.t = self.t + dt
  settings.update(dt)
  self.blink = self.blink + dt
  self.slot_flash = math.max(0, self.slot_flash - dt * 2)
  if self.phase == "arming" then self:arm(dt) end
  if self.phase == "waiting" then
    self.cart.angle = math.sin(self.t * 2) * 0.04
  end
end

function S:keypressed(key)
  if settings.keypressed(key) then return end
  if key == "f12" then settings.toggle() return end
  if key == "escape" then
    if self.phase == "post" or self.phase == "warmup" then self:skip_post() end
    return
  end
  if self.phase == "arming" then
    if key == "space" or key == "return" or key == "kpenter" then self:strike() end
  elseif self.phase == "post" or self.phase == "warmup" then
    self:skip_post()
  elseif self.phase == "waiting" then
    if key == "space" or key == "return" or key == "kpenter" then self:insert() end
  elseif self.phase == "title" then
    if (key == "space" or key == "return" or key == "kpenter") and app.ready then
      sfx.play("confirm")
      SWITCH(require("src.scenes.chat"))
    elseif not app.ready then
      sfx.play("deny")
      app.toast("THE ROM IS STILL READING", "red", 1.4)
    end
  end
end

function S:mousepressed(x, y, button)
  if button ~= 1 then return end
  if settings.open then settings.click(self.hotspots, x, y) return end
  if toggles.click(self.hotspots, x, y) then return end
  if self.phase == "waiting" then self:insert() end
end

-- ------------------------------------------------------------------ draw ---

--- The cartridge itself: a black slab with a gold label and a row of contacts
--- along the bottom edge.
local function cartridge(x, y, scale, angle, lit)
  love.graphics.push()
  love.graphics.translate(math.floor(x), math.floor(y))
  love.graphics.rotate(angle or 0)
  love.graphics.scale(scale or 1, scale or 1)

  palette.set("black", 1)
  love.graphics.rectangle("fill", -34, -22, 68, 44)
  palette.set("gray", 1)
  love.graphics.rectangle("fill", -34, -22, 68, 6)
  palette.set(lit and "white" or "silver", 1)
  love.graphics.rectangle("line", -34.5, -22.5, 69, 45)

  -- Label. Always at one, because it is printed on a physical object that is
  -- sixty-eight pixels wide whatever the interface around it is doing.
  palette.set("maroon", 1)
  love.graphics.rectangle("fill", -28, -15, 56, 27)
  palette.set("gold", 1)
  love.graphics.rectangle("line", -28.5, -15.5, 57, 28)
  text.at(1, function()
    text.center("JARVIS", -28, 56, -13, "gold")
    text.center("MK-I", -28, 56, -5, "yellow")
    text.center("27B 4BIT", -28, 56, 3, "silver")
  end)

  -- Contacts.
  palette.set(lit and "white" or "gold", 1)
  for i = -30, 26, 4 do
    love.graphics.rectangle("fill", i, 16, 2, 6)
  end
  love.graphics.pop()
end

--- The slot in the top of the machine, which is where the cartridge goes.
local function slot(g, flash)
  local x, y, w = g.slot.x, g.slot.y, g.slot.w
  palette.set("gray", 1)
  love.graphics.rectangle("fill", x, y, w, 14)
  palette.set("black", 1)
  love.graphics.rectangle("fill", x + 6, y + 4, w - 12, 8)
  palette.set(flash > 0.1 and "white" or "silver", 0.9)
  love.graphics.rectangle("line", x - 0.5, y - 0.5, w + 1, 15)
  if flash > 0.1 then
    palette.set("white", flash)
    love.graphics.rectangle("fill", x + 6, y + 4, w - 12, 8)
  end
end

--- Bytes, the way a download says them.
local function human_bytes(n)
  n = tonumber(n) or 0
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local unit = 1
  while n >= 1024 and unit < #units do
    n = n / 1024
    unit = unit + 1
  end
  if unit <= 2 then return string.format("%d %s", n, units[unit]) end
  return string.format("%.1f %s", n, units[unit])
end

--- A line across the middle, cut to the width of the screen. The boot screen
--- is a fixed-format readout — a BIOS does not reflow — so anything too long
--- for the canvas is trimmed rather than allowed off the edge.
local function centred(s, y, slot, alpha)
  local W = app.W
  text.center(text.clip(s, math.floor((W - 6) / text.cell())), 0, W, y, slot, alpha)
end

--- The anvil, the hammer and the timing ring.
local function anvil(x, y, hot)
  -- A horn, a body and a base. Six rectangles is an anvil at this size.
  palette.set("ink", 1)
  love.graphics.rectangle("fill", x - 17, y - 9, 34, 7)
  love.graphics.rectangle("fill", x - 7, y - 3, 14, 8)
  love.graphics.rectangle("fill", x - 13, y + 4, 26, 6)
  palette.set(palette.c("steel") and "steel" or "gray", 1)
  love.graphics.rectangle("fill", x - 16, y - 8, 32, 5)
  love.graphics.rectangle("fill", x - 6, y - 3, 12, 7)
  love.graphics.rectangle("fill", x - 12, y + 4, 24, 5)
  palette.set("moon", 0.8)
  love.graphics.rectangle("fill", x - 16, y - 8, 32, 1)
  -- The horn, off the left end.
  palette.set("ink", 1)
  love.graphics.polygon("fill", x - 17, y - 9, x - 26, y - 6, x - 17, y - 2)
  palette.set("silver", 1)
  love.graphics.polygon("fill", x - 17, y - 8, x - 24, y - 6, x - 17, y - 3)
  if hot > 0.02 then
    palette.set("flame", hot * 0.7)
    love.graphics.rectangle("fill", x - 16, y - 9, 32, 3)
  end
end

--- The knight being put into his harness, and what it stands for underneath.
function S:draw_arming(g)
  local W, H = app.W, app.H
  local c, lh = text.cell(), text.height()

  harness.draw(self.t)
  app.avatar:draw()

  -- ------------------------------------------------------------- the forge --
  local ax, ay = self:anvil()

  -- The heat in the metal, under everything.
  if self.heat > 0.02 or self.white_hot > 0 then
    local glow = self.heat * 0.5 + self.white_hot * 0.5
    for i = 4, 1, -1 do
      palette.set(self.white_hot > 0.1 and "white" or "ember", 0.05 * i * glow)
      love.graphics.ellipse("fill", ax, ay - 4, 14 + i * 9, 8 + i * 5)
    end
  end

  anvil(ax, ay, self.heat)

  -- The ring that closes: strike as it lands on the anvil.
  local radius = 26 - self.ring * 18
  local close = self.ring > 0.82
  ui.ring(ax, ay - 6, radius, 14, self.t * 0.6,
    close and "flame" or "silver", close and 0.95 or 0.45, close and 2 or 1)

  -- The hammer, swung in from the right.
  if self.hammer > 0.01 then
    local swing = (1 - self.hammer)
    local hx = ax + 20 + swing * -8
    local hy = ay - 30 + swing * 20
    love.graphics.push()
    love.graphics.translate(hx, hy)
    love.graphics.rotate(-0.9 + swing * 0.9)
    palette.set("olive", 1)
    love.graphics.rectangle("fill", -1, 0, 3, 18)
    palette.set("ink", 1)
    love.graphics.rectangle("fill", -7, -6, 15, 8)
    palette.set(palette.c("steel") and "steel" or "gray", 1)
    love.graphics.rectangle("fill", -6, -5, 13, 6)
    palette.set("moon", 0.9)
    love.graphics.rectangle("fill", -6, -5, 13, 1)
    love.graphics.pop()
  end

  if self.perfect > 0.05 then
    text.center("PERFECT", 0, W, ay - 34 - self.perfect * 6, "flame", self.perfect)
  end
  if self.white_hot > 0.05 then
    text.center("WHITE HOT", 0, W, ay - 46, "white", self.white_hot)
  end

  app.fx:draw()

  -- ------------------------------------------------------------ the readout --
  local total = harness.count()
  local fraction = total > 0 and (self.plates / total) or 0

  local pw = math.min(W - 12, math.max(34 * c, 220))
  local px = math.floor((W - pw) / 2)
  local rows = (app.download and 4 or 3) + 1   -- the last one is HEAT and the score
  local py = math.floor(H - lh * rows - 20 - lh * 2)
  local x, y, w = ui.panel(px, py, pw, lh * rows + 16, {
    title = app.download and "FETCHING THE WEIGHTS" or "PUTTING IT ON",
    slot = "gold", title_slot = "yellow", fill = 0.86, glow = "gold",
  })

  if app.download and (app.download.total or 0) > 0 then
    local d = app.download
    ui.gauge(x + 2, y + 2, w - 4, 5, math.max(0, math.min(1, d.fraction)),
      { ramp = "fire", back = "gray" })
    text.print(text.clip(string.format("%s / %s", human_bytes(d.done), human_bytes(d.total)),
      math.floor(w / c)), x + 2, y + 9, "white")
    text.right(string.format("%d%%", math.max(0, math.min(100, math.floor(d.fraction * 100)))),
      x + w - 2, y + 9, "yellow")
    text.print(text.clip(string.format("%d of %d  %s", d.files_done,
      math.max(d.files_total, d.files_done), tostring(d.file)),
      math.floor((w - 4) / c)), x + 2, y + 9 + lh, "gray")
    -- Where they are landing. The home directory is written as `~`, because
    -- the path is long enough without it.
    local home = os.getenv("HOME")
    local dest = tostring(d.dest or "")
    if home and dest:sub(1, #home) == home then dest = "~" .. dest:sub(#home + 1) end
    -- Cut from the left: the end of the path is the part that says which
    -- model this is, and the beginning is the same for every one of them.
    local room = math.floor((w - 4) / c)
    if #dest > room then dest = "~" .. dest:sub(#dest - room + 2) end
    text.print(dest, x + 2, y + 9 + lh * 2, "cyan", 0.8)
  else
    ui.gauge(x + 2, y + 2, w - 4, 5, fraction, { ramp = "steel", back = "gray" })
    text.print(text.clip(app.ready and "READY" or "MOUNTING WEIGHTS", math.floor(w / c)),
      x + 2, y + 9, app.ready and "lime" or "white")
    text.right(string.format("%d/%d", self.plates, total), x + w - 2, y + 9, "silver")
    text.print(text.clip("the harness is the progress bar", math.floor((w - 4) / c)),
      x + 2, y + 9 + lh, "gray")
  end

  -- ------------------------------------------------------------ the score --
  local sy = y + lh * (rows - 2) + 12
  local heat_w = math.floor(w * 0.45)
  text.print("HEAT", x + 2, sy, "orange")
  ui.gauge(x + 2 + 5 * c, sy, heat_w, 5, self.heat,
    { ramp = self.white_hot > 0.1 and "holy" or "fire", back = "gray" })
  text.right(string.format("%d HIT  x%d", self.strikes, self.combo),
    x + w - 2, sy, self.combo > 0 and "yellow" or "silver")

  local hint = math.floor(self.t * 2) % 2 == 0
    and "{yellow}SPACE{} STRIKE THE ANVIL" or "{gray}SPACE{} STRIKE THE ANVIL"
  centred(hint, py + lh * rows + 18, "silver")
  centred("it does not make the download any faster", py + lh * rows + 19 + lh, "gray", 0.7)
end

function S:draw()
  -- Two sizes at most. This screen is columns of machine readout and it has
  -- to fit them side by side; at three times the font a narrow canvas holds
  -- twenty characters, which is not enough for "MAIN RAM 36864 KB OK".
  text.at(math.min(app.L.text_scale, 2), function() self:draw_screen() end)
end

function S:draw_screen()
  self.hotspots = {}
  local g = geometry()
  local W, H = g.W, g.H

  if self.phase == "title" then
    art.draw("cartridge", math.sin(self.t * 0.2) * 0.5, 0, 0.25)
    app.bg_fx:draw()
  elseif self.phase == "arming" then
    -- The forge while the bytes are coming in; the hall where the pieces come
    -- together once they are here.
    art.draw(app.download and "forge" or "awakening",
      math.sin(self.t * 0.25) * 0.4, 0, 0.30)
    app.bg_fx:draw()
  else
    palette.set("black", 1)
    love.graphics.rectangle("fill", 0, 0, W, H)
  end

  -- --------------------------------------------------------- the armouring --
  if self.phase == "arming" then self:draw_arming(g) end

  -- ------------------------------------------------------------- the POST --
  if self.phase ~= "title" and self.phase ~= "arming" then
    local x, y = g.post.x, g.post.y
    local room = math.floor((W - x * 2) / text.cell())
    text.print(text.clip("CausewayBay Personal Computer", room), x, y, "white")
    text.print(text.clip("BIOS 3.2  (C) 2026 CAUSEWAYBAY", room),
      x, y + text.height() + 1, "silver")
    palette.set("gray", 0.8)
    love.graphics.rectangle("fill", x, y + text.height() * 2 + 6,
      math.min(W - x * 2, 50 * text.cell()), 1)

    local step = text.height() + 2
    local label_w = 13 * text.cell()
    for _, i in ipairs(self.lines) do
      local row = POST[i]
      local ly = y + step * 3 + (i - 1) * step
      text.print(row.label, x, ly, "silver")
      local value = row.value
      if row.count then value = string.format("%5d KB", self.ram) end
      text.print(text.clip(value, math.floor((W - x - label_w - 4 * text.cell()) / text.cell())),
        x + label_w, ly, row.ok and "white" or "gray")
      if row.ok and (not row.count or self.ram >= RAM_KB) then
        text.print("OK", W - x - 2 * text.cell(), ly, "lime")
      end
    end

    if self.phase == "waiting" or self.phase == "inserting" then
      slot(g, self.slot_flash)
      if self.phase == "waiting" and math.floor(self.blink * 2) % 2 == 0 then
        centred("INSERT CARTRIDGE INTO SLOT 1", g.slot.y - text.height() - 8, "yellow")
      end
      if self.phase == "waiting" then
        -- Two lines rather than one: thirty-six characters do not fit a
        -- narrow screen at any size worth reading.
        local step = text.height() + 2
        centred("{gray}SPACE{} TO INSERT", H - 8 - step * 2, "silver")
        centred("{gray}ESC{} SKIPS THE POST", H - 8 - step, "silver")
      end
      cartridge(self.cart.x, self.cart.y, self.cart.scale, self.cart.angle,
        self.slot_flash > 0.1)
    end
  end

  -- ------------------------------------------------------------ the title --
  if self.phase == "title" then
    palette.set("black", 0.38)
    love.graphics.rectangle("fill", 0, g.logo.y - 10, W, 88)

    love.graphics.push()
    love.graphics.translate(W / 2, g.logo.y)
    love.graphics.scale(self.logo.scale, self.logo.scale)
    text.at(1, function()
      local label = "JARVIS"
      local w = text.width(label)
      -- Three passes: a hard shadow, a rim, and the face of the letters.
      text.print(label, -w / 2 + 1, 1, "black", 0.9)
      text.print(label, -w / 2, 0, "maroon")
      text.print(label, -w / 2, -1, "gold")
    end)
    love.graphics.pop()

    centred("C A U S E W A Y B A Y", g.logo.y + 36, "silver")
    centred("AN ON-DEVICE FAMILIAR", g.logo.y + 38 + text.height(), "gray")

    -- What the ROM says about itself.
    local x, y, w2, h = ui.panel(g.panel.x, g.panel.y, g.panel.w, g.panel.h,
      { title = "ROM HEADER", slot = "gold" })
    local model = app.model or {}
    local rows = {
      { "MODEL", app.demo and "RECORDED (DEMO)" or tostring(model.model or model.alias or "?") },
      { "PARAMS", model.parameters and model.parameters > 0
        and string.format("%.1fB  %s", model.parameters / 1e9, tostring(model.quantization or "")) or "--" },
      { "CONTEXT", model.context_length and model.context_length > 0
        and string.format("%d TOKENS", model.context_length) or "--" },
    }
    local step = text.height() + 2
    local key_w = 9 * text.cell()
    local room = math.floor((w2 - key_w - 4) / text.cell())
    for i, row in ipairs(rows) do
      text.print(row[1], x + 2, y + 2 + (i - 1) * step, "gray")
      text.print(text.clip(row[2], room), x + 2 + key_w, y + 2 + (i - 1) * step, "white")
    end

    if app.ready then
      if math.floor(self.blink * 1.6) % 2 == 0 then
        centred(app.demo and "PUSH SPACE KEY - DEMO" or "PUSH SPACE KEY",
          g.gauge.y - text.height() - 4, "yellow")
      end
    else
      -- Indeterminate, because `jarvis_open` does not report progress: it
      -- either has fifteen gigabytes mapped or it does not.
      local sweep = (math.sin(self.t * 2.2) * 0.5 + 0.5) * 0.7 + 0.15
      ui.gauge(g.gauge.x, g.gauge.y, g.gauge.w, 5, sweep, { ramp = "fire", back = "gray" })
      centred("MOUNTING WEIGHTS", g.gauge.y + 8, "orange")
    end

    local step = text.height() + 2
    centred("(C) 2026 CAUSEWAYBAY", H - 8 - step * 2, "gray")
    centred("RUST - MLX - METAL", H - 8 - step, "gray")

  end

  -- The two window buttons, in the corner of every screen the machine draws —
  -- the memory count, the empty slots and the title alike. One that can open
  -- fullscreen wants a visible way back out from the first frame, not one you
  -- have to know a function key for.
  local left = toggles.draw(W - 4, 4, self.hotspots, app.L.button_h)
  local setup_w = ui.button_width("SETUP")
  if left - setup_w - 3 > 4 then
    local bx = left - 3 - setup_w
    local hot = app.mouse.x >= bx and app.mouse.x < bx + setup_w
      and app.mouse.y >= 4 and app.mouse.y < 4 + app.L.button_h
    local rect = ui.button(bx, 4, setup_w, app.L.button_h, "SETUP", { slot = "gold", hot = hot })
    self.hotspots[#self.hotspots + 1] = { rect = rect, action = function() settings.toggle() end }
  end

  settings.draw(self.hotspots)

  app.fx:draw()

  -- --------------------------------------------------------- the tube ------
  -- Everything above is masked by the beam while the tube warms up: a bright
  -- line that opens into a picture, which is what switching one on looked
  -- like.
  if self.beam < 1 then
    local open = ease.outQuint(self.beam)
    local band = H * open
    palette.set("black", 1)
    love.graphics.rectangle("fill", 0, 0, W, (H - band) / 2)
    love.graphics.rectangle("fill", 0, (H + band) / 2, W, (H - band) / 2)
    palette.set("white", 1 - open)
    love.graphics.rectangle("fill", 0, H / 2 - 1, W, 2)
  end
end

return S
