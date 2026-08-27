-- CAUSEWAYBAY JARVIS -- the cartridge.
--
-- A 27-billion-parameter model, on this machine, behind a 720x405 screen with
-- sixteen colours and a 6x8 font. Everything is drawn into one canvas at that
-- size and blown up through a CRT shader at the end, so nothing anywhere else
-- has to think about the size of the window.
--
--   love love/                       the chat
--   love love/ --demo                the same, with a recorded model
--   love love/ --model qwen3.8:27b-mlx-8bit
--   love love/ --palette apple2
--
-- The model itself runs on `worker.lua`, on its own thread, through the same
-- `libjarvis` the `rustcli` binary and `lua/chat.lua` use.

local palette = require("src.palette")
local text = require("src.text")
local shaders = require("src.shaders")
local sfx = require("src.sfx")
local music = require("src.music")
local art = require("src.art")
local app = require("src.app")
local ui = require("src.ui")

-- The canvas fills the window, at a whole-number scale.
--
-- It is not a fixed canvas blown up and letterboxed: the *scale* is fixed to
-- an integer -- half a pixel of a 6x8 font is not a font -- and the canvas is
-- then whatever that scale divides the window into. On a 1440x810 window that
-- is exactly 720x405 at 2x; on anything else it is some other size, and every
-- rectangle in the client comes out of `layout.compute` against it rather than
-- out of a constant. The alternative is bars, and on a tall window the bars
-- were most of the screen.
--
-- MIN is the smallest canvas the layout stays usable at, and it is what
-- decides the scale: the biggest whole number that still leaves this much.
-- Lowering these raises the scale, which makes everything on screen bigger
-- and fits less of it: the canvas is the window divided by the scale.
--
-- Two of them. FIT is what the scale is chosen against on a window big enough
-- to have the choice, and MIN is the floor a small one falls back to. The
-- scale used to be taken against MIN alone, which is the coarsest that fits
-- and so always the coarsest: a 1440x810 window became a 480x270 canvas at
-- three window pixels a canvas pixel, and the transcript was forty-six columns
-- of very large letters. Against FIT the same window takes two, which is
-- 720x405, and the letters come out two thirds the size.
--
-- FIT is one number rather than a shape because it is measured against the
-- window's short side; see `best_fit`.
local FIT = 340
local MIN_W, MIN_H = 340, 250
local W, H = 480, 270

local canvas
local scene
local transition
local crt_on = true
local shots
local scale, offset_x, offset_y, pixel_scale = 1, 0, 0, 1

-- A window change waiting for the frame to end. Never do one inside
-- `love.draw`: the whole scene is drawn into a canvas, and swapping the window
-- mode -- or the canvas itself -- in the middle of that pass tears the render
-- target out from under drawing that has not happened yet. Both go through
-- here, and `love.update` performs them before it does anything else.
local pending = nil
local last_window_w, last_window_h = 0, 0
local box = { x = 0, y = 0, w = 480, h = 270 }

local SETTINGS = "settings"

-- ------------------------------------------------------------- arguments ---

--- What was chosen last time. A missing or unreadable file is not an error:
--- it means the defaults, which is what a first run wants anyway.
local function remembered()
  local out = {}
  local text = love.filesystem.read(SETTINGS)
  if not text then return out end
  for key, value in text:gmatch("(%w+)%s*=%s*(%S+)") do out[key] = value end
  return out
end

local function remember(key, value)
  local settings = remembered()
  settings[key] = tostring(value)
  local lines = {}
  for k, v in pairs(settings) do lines[#lines + 1] = k .. " = " .. v end
  table.sort(lines)
  pcall(love.filesystem.write, SETTINGS, table.concat(lines, "\n") .. "\n")
end

local function parse(argv)
  local options = {}
  local i = 1
  while i <= #argv do
    local arg = argv[i]
    if arg == "--demo" then options.demo = true
    elseif arg == "--no-crt" then options.no_crt = true
    elseif arg == "--model" or arg == "-m" then i = i + 1 options.model = argv[i]
    elseif arg == "--palette" then i = i + 1 options.palette = argv[i]
    elseif arg == "--plate" then i = i + 1 options.plate = argv[i]
    elseif arg == "--shots" then options.shots = true
    elseif arg == "--portrait" then options.portrait = true
    elseif arg == "--landscape" then options.portrait = false
    elseif arg == "--windowed" then options.windowed = true
    elseif arg == "--fullscreen" then options.fullscreen = true
    elseif arg == "--download" then options.download = true
    end
    i = i + 1
  end
  return options
end

-- --------------------------------------------------------------- scenes ----

--- The box the interface is laid out in, inside the canvas.
---
--- Normally the whole of it. But an arrangement has a shape — two columns
--- wants a wide screen, two bands a tall one — and when the window is the
--- other way up, the arrangement is **letterboxed into the shape it wants**
--- rather than stretched to fill one it does not: two columns in a canvas
--- twice as tall as it is wide is a column of conversation beside a column of
--- nothing.
---
--- The tolerance is wide, because a letterbox nobody asked for is worse than a
--- slightly wrong aspect: anything within about forty per cent of 16:9 (or of
--- 9:16) is left alone and simply fills.
local function layout_box(cw, ch, portrait)
  local target = portrait and (9 / 16) or (16 / 9)
  local aspect = cw / ch
  local ratio = aspect / target
  if ratio > 0.7 and ratio < 1.43 then return 0, 0, cw, ch end

  local bw, bh = cw, ch
  if aspect > target then bw = math.floor(ch * target) else bh = math.floor(cw / target) end
  return math.floor((cw - bw) / 2), math.floor((ch - bh) / 2), bw, bh
end

--- The largest whole scale that still leaves a comfortable canvas, and the
--- canvas it divides the window into.
---
--- Measured against the window's **short** side, because that is the side the
--- interface is tight in either way up -- and because a rule with a width and
--- a height in it has to be turned for a tall window, and then gets the turn
--- wrong. Held as a shape, an 810x1080 window failed a 560 height requirement
--- by twenty pixels, fell to a scale of one and lost every bit of the chunk
--- this is drawn in; on its short side it is a 405x540 canvas at two, which is
--- what it should have been.
---
--- A window too small to give even one scale that much falls back to MIN, the
--- smallest canvas the interface still lays out in -- below that there is no
--- scale to choose and the answer is one either way.
local function best_fit()
  local ww, wh = love.graphics.getDimensions()
  local s = math.floor(math.min(ww, wh) / FIT)
  if s < 1 then
    s = math.max(1, math.min(math.floor(ww / MIN_W), math.floor(wh / MIN_H)))
  end
  return s, math.floor(ww / s), math.floor(wh / s)
end

--- Rebuild everything that is sized against the canvas. Called when the window
--- changes shape, and after any window-mode change -- a mode change empties
--- every canvas the client holds, so a plate baked before one comes back
--- blank, which is what turning the screen used to do to all seven of them.
local function refit(force)
  local s, cw, ch = best_fit()
  local portrait = app.layout_pref == "portrait"
    or (app.layout_pref ~= "landscape" and ch > cw)
  local bx, by, bw, bh = layout_box(cw, ch, portrait)
  if not force and s == scale and cw == W and ch == H
     and bw == box.w and bh == box.h then return false end

  scale, W, H = s, cw, ch
  box = { x = bx, y = by, w = bw, h = bh }

  canvas = love.graphics.newCanvas(W, H)
  canvas:setFilter("nearest", "nearest")

  -- The scenes are told the size of the *box*, not of the canvas: as far as
  -- anything above this line is concerned, the box is the screen.
  app.set_size(bw, bh)
  art.resize(bw, bh)
  shaders.crt:send("virtual_size", { W, H })
  app.window.portrait = app.L.portrait
  return true
end

--- Which arrangement the chat scene uses: two columns, or two bands. Free of
--- the window's shape, though a windowed window is reshaped to match so that
--- asking for the tall layout gives you a tall window to put it in.
local function set_layout(portrait, remember_it)
  app.set_size(W, H, portrait and "portrait" or "landscape")
  if remember_it ~= false then remember("portrait", portrait and 1 or 0) end

  if not love.window.getFullscreen() then
    local ww, wh = love.graphics.getDimensions()
    if (wh > ww) ~= portrait then
      local _, _, flags = love.window.getMode()
      flags.minwidth, flags.minheight = MIN_W, MIN_H
      love.window.setMode(wh, ww, flags)
    end
  end
  refit(true)
  return true
end

--- Ask for a window change, to happen between frames rather than now.
local function ask(change)
  pending = pending or {}
  for key, value in pairs(change) do pending[key] = value end
end

--- Fullscreen as far as the interface is concerned, including a change asked
--- for and not yet applied.
local function fullscreen_now()
  if pending and pending.fullscreen ~= nil then return pending.fullscreen end
  return love.window.getFullscreen()
end

local function switch(next_scene, instant)
  if instant then
    if scene and scene.leave then scene:leave() end
    scene = next_scene
    if scene.enter then scene:enter() end
    return
  end
  transition = { t = 0, dur = 0.62, half = false, next = next_scene }
end

_G.SWITCH = switch

-- ---------------------------------------------------------------- love -----

function love.load(argv)
  local options = parse(argv or {})
  local saved = remembered()

  love.graphics.setDefaultFilter("nearest", "nearest")
  love.graphics.setLineStyle("rough")
  love.keyboard.setKeyRepeat(true)

  local saved_text = tonumber(saved.text)
  if saved_text and saved_text > 0 then app.text_pref = saved_text end

  -- Which arrangement. Left as nil unless it was actually chosen -- by a flag
  -- or by F7 in an earlier run -- so that a display nobody has expressed an
  -- opinion about gets the arrangement its shape asks for: bands on a tall
  -- screen, columns on a wide one.
  local portrait = options.portrait
  if portrait == nil and saved.portrait then portrait = saved.portrait == "1" end

  if options.palette then palette.use(options.palette) end

  text.load()
  shaders.load()
  sfx.load()

  -- The canvas is whatever a whole scale divides this window into; the box
  -- inside it is what the scenes are given.
  scale, W, H = best_fit()
  local bx, by, bw, bh = layout_box(W, H, portrait == true)
  box = { x = bx, y = by, w = bw, h = bh }
  art.load(bw, bh)

  crt_on = not options.no_crt

  canvas = love.graphics.newCanvas(W, H)
  canvas:setFilter("nearest", "nearest")

  -- `getSource` may or may not come back with a trailing separator depending
  -- on how love was invoked, and one that does would put the checkout root a
  -- directory too deep.
  local source = love.filesystem.getSource():gsub("[/\\]+$", "")
  local root = source:match("^(.*)[/\\][^/\\]*$") or "."

  app.load({
    source = source,
    lua_dir = root .. "/lua",
    model = options.model,
    demo = options.demo,
    download = options.download,
    width = box.w,
    height = box.h,
    layout = portrait ~= nil and (portrait and "portrait" or "landscape") or nil,
  })
  app.wire_harness()
  app.on_window_request = ask
  -- The button says what the client is doing, which for an unchosen layout is
  -- whatever the canvas shape decided.
  app.window.portrait = app.L.portrait
  -- A windowed window is reshaped to suit the arrangement asked for.
  if portrait ~= nil then ask({ portrait = portrait }) end
  app.plate = options.plate or "medieval-prague"

  music.load(source)

  -- It opens filling the display (see conf.lua) unless it was last left
  -- windowed. Deferred like every other window change, so it happens on the
  -- first update rather than in the middle of setting things up.
  local full = options.fullscreen
  if options.windowed then full = false end
  if full == nil then
    full = (saved.fullscreen == nil) or (saved.fullscreen == "1")
  end
  app.window.fullscreen = full
  if full ~= love.window.getFullscreen() then ask({ fullscreen = full }) end

  -- `--shots` drives the client from a script and photographs it; see shots.lua.
  if options.shots then
    shots = require("src.shots")
    love.window.setVSync(0)          -- the script runs faster than the display
  end

  switch(require("src.scenes.boot"), true)
end

function love.update(dt)
  -- Before anything else: this is the one place allowed to touch the window
  -- or the canvas, because it is the one place that is not inside a canvas
  -- pass. See `ask`.
  if pending then
    local change = pending
    pending = nil
    if change.fullscreen ~= nil then
      love.window.setFullscreen(change.fullscreen, "desktop")
      remember("fullscreen", change.fullscreen and 1 or 0)
      -- Same reason as the turn above: the plates live in canvases and a
      -- mode change empties them.
      art.rebake()
    end
    if change.portrait ~= nil then set_layout(change.portrait) end
    if change.refit then refit(true) end
    app.window.portrait = app.L.portrait
    app.window.fullscreen = love.window.getFullscreen()
  end

  -- The canvas follows the window, checked rather than notified: `love.resize`
  -- does not fire for every way a window can change size (a programmatic
  -- `setMode` among them), and a canvas that has stopped matching its window
  -- is bars down two sides.
  local ww, wh = love.graphics.getDimensions()
  if ww ~= last_window_w or wh ~= last_window_h then
    last_window_w, last_window_h = ww, wh
    refit()
  end

  -- A frame that took a second (the weights arriving, a window dragged
  -- between displays) must not be integrated as a second, or every tween in
  -- flight finishes at once.
  dt = math.min(dt, 1 / 20)

  app.update(dt)
  shaders.update(dt, { glitch = app.glitch_amount })

  if transition then
    transition.t = transition.t + dt
    if not transition.half and transition.t >= transition.dur / 2 then
      transition.half = true
      if scene and scene.leave then scene:leave() end
      scene = transition.next
      if scene.enter then scene:enter() end
    end
    if transition.t >= transition.dur then transition = nil end
  end

  if scene and scene.update then scene:update(dt) end
  if shots then shots.update(dt) end
end

--- The bars that close over a scene change: eight of them, alternating from
--- the two sides, which is how a machine with no alpha changed the subject.
local function draw_transition()
  if not transition then return end
  local t = transition.t / transition.dur
  local closing = t < 0.5
  local fraction = closing and (t * 2) or (1 - (t - 0.5) * 2)
  fraction = fraction ^ 0.8
  local bars = 9
  local height = H / bars
  palette.set("black", 1)
  for i = 0, bars - 1 do
    local width = W * math.min(1, fraction * 1.25 - (i % 3) * 0.08)
    if width > 0 then
      local x = (i % 2 == 0) and 0 or (W - width)
      love.graphics.rectangle("fill", x, i * height, width, height + 1)
    end
  end
  if fraction > 0.55 then
    palette.set("navy", (fraction - 0.55) * 2)
    love.graphics.rectangle("fill", 0, 0, W, H)
  end
end

local function draw_toasts()
  -- Not over an overlay: that is a window someone opened deliberately, and a
  -- toast landing on its title reads as a fault.
  if app.modal then return end
  for i, toast in ipairs(app.toasts) do
    local age = toast.age / toast.life
    -- In fast, hold, out slow.
    local slide = age < 0.12 and (1 - age / 0.12) or 0
    local alpha = age > 0.8 and (1 - age) * 5 or 1
    -- Over the stage, near the top of it: the one part of either layout that
    -- is scenery rather than words. Under the status bar they sat on the
    -- transcript's title; above the input they sat on its last line. Stacked
    -- by the height of the letters, so they do not sit on each other at a
    -- large font either.
    local stage = app.L.stage
    local step = text.height() + 4
    local y = stage.y + math.floor(stage.h * 0.12) + (i - 1) * step - slide * (step + 2)
    local label = " " .. toast.text .. " "
    local w = math.min(text.width(label), W - 8)
    palette.set("black", 0.75 * alpha)
    love.graphics.rectangle("fill", (W - w) / 2, y, w, step - 2)
    palette.set(toast.slot, alpha)
    love.graphics.rectangle("line", (W - w) / 2 + 0.5, y + 0.5, w - 1, step - 3)
    text.print(text.clip(toast.text, math.floor(w / app.L.cell)),
      (W - w) / 2 + app.L.cell / 2, y + 1, toast.slot, alpha)
  end
end

function love.draw()
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(1, 1, 1, 1)

  local sx, sy = app.shake_offset()
  love.graphics.push()
  love.graphics.translate(box.x + sx, box.y + sy)
  -- Clipped to the box, so a background that does not know about the
  -- letterbox cannot paint over it.
  love.graphics.setScissor(box.x, box.y, box.w, box.h)
  if scene and scene.draw then scene:draw() end
  draw_toasts()
  love.graphics.setScissor()
  love.graphics.pop()

  if app.flash_amount > 0.01 then
    palette.set(app.flash_slot, app.flash_amount * 0.7)
    love.graphics.rectangle("fill", 0, 0, W, H)
  end

  -- Say why the window has not closed yet.
  if app.closing then
    palette.set("black", 0.72)
    love.graphics.rectangle("fill", 0, 0, W, H)
    ui.banner(H / 2 - 6, "PUTTING THE MODEL DOWN" .. string.rep(".", math.floor(app.closing_for() * 3) % 4),
      "gold", 0.9, W)
  end

  draw_transition()

  love.graphics.setCanvas()
  love.graphics.setColor(1, 1, 1, 1)

  -- The canvas was built to fill this window at this scale, so what is left
  -- over is at most `scale - 1` pixels on each axis. Centre that.
  local window_w, window_h = love.graphics.getDimensions()
  offset_x = math.floor((window_w - W * scale) / 2)
  offset_y = math.floor((window_h - H * scale) / 2)
  pixel_scale = math.max(1, math.floor(scale * (love.window.getDPIScale() or 1) / 3))

  if crt_on then
    shaders.crt:send("virtual_size", { W, H })
    shaders.crt:send("pixel_scale", pixel_scale)
    love.graphics.setShader(shaders.crt)
  end
  love.graphics.draw(canvas, offset_x, offset_y, 0, scale, scale)
  love.graphics.setShader()
end

-- ----------------------------------------------------------------- input ---

function love.keypressed(key, scancode, isrepeat)
  if key == "f11" or (key == "return" and love.keyboard.isDown("lalt", "ralt")) then
    local wanted = not fullscreen_now()
    ask({ fullscreen = wanted })
    app.window.fullscreen = wanted
    sfx.play("select")
    return
  elseif key == "f8" then
    -- The font, in whole steps, and then back to letting the layout choose.
    local order = { 1, 2, 3, nil }
    local at = 4
    for i = 1, 3 do if app.text_pref == order[i] then at = i end end
    local next_size = order[at % 4 + 1]
    app.set_text_size(next_size)
    remember("text", next_size or 0)
    sfx.play("select")
    app.toast(next_size and ("TEXT SIZE " .. next_size) or
      ("TEXT SIZE AUTO (" .. app.L.text_scale .. ")"), "cyan", 1.6)
    return
  elseif key == "f7" then
    local portrait = not app.L.portrait
    ask({ portrait = portrait })
    app.window.portrait = portrait
    sfx.play("open")
    app.toast(portrait and "LAYOUT - VERTICAL" or "LAYOUT - HORIZONTAL", "cyan", 1.6)
    return
  elseif key == "f2" then
    local name = palette.next()
    shaders.send_palette()
    art.rebake()
    sfx.play("select")
    app.toast("PALETTE - " .. palette.label, "cyan", 1.6)
    return
  elseif key == "f4" then
    app.toast(music.toggle() and "MUSIC ON" or "MUSIC OFF", "lime", 1.4)
    return
  elseif key == "f5" then
    local muted = sfx.mute()
    app.toast(muted and "SOUND OFF" or "SOUND ON", "lime", 1.4)
    if not muted then sfx.play("select") end
    return
  elseif key == "f6" then
    crt_on = not crt_on
    sfx.play("select")
    app.toast(crt_on and "CRT ON" or "CRT OFF", "silver", 1.4)
    return
  elseif key == "q" and (love.keyboard.isDown("lgui") or love.keyboard.isDown("rgui")) then
    love.event.quit()
    return
  end

  if transition then return end
  if scene and scene.keypressed then scene:keypressed(key, isrepeat) end
end

function love.textinput(char)
  if transition then return end
  if scene and scene.textinput then scene:textinput(char) end
end

function love.wheelmoved(dx, dy)
  if scene and scene.wheelmoved then scene:wheelmoved(dx, dy) end
end

--- Box pixels, from window pixels: what the scenes draw in.
local function pointer(x, y)
  return (x - offset_x) / scale - box.x, (y - offset_y) / scale - box.y
end

function love.mousemoved(x, y)
  app.mouse.x, app.mouse.y = pointer(x, y)
end

function love.mousepressed(x, y, button)
  local mx, my = pointer(x, y)
  app.mouse.x, app.mouse.y = mx, my
  if transition then return end
  if scene and scene.mousepressed then scene:mousepressed(mx, my, button) end
end

--- Refuse the first quit and take it once the model has let go. See
--- `app.begin_shutdown`: leaving while the worker is inside `jarvis_send`
--- means MLX frees its Metal device out from under it.
function love.quit()
  if app.shutdown_done() then return false end
  app.begin_shutdown()
  return true
end
