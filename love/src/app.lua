--- What the scenes share: the model on its thread, the timeline, the
--- particles, the avatar, and the small amount of state that outlives a scene
--- change (the transcript, the statistics, whether the cartridge is in).
---
--- Scenes talk to the model through `app.ask`, `app.interrupt` and `app.reset`
--- and hear back through `app.on_event`, which the current scene sets. The
--- channel pump is here so that a scene change cannot drop a token.

local particles = require("src.particles")
local tween = require("src.tween")
local avatar = require("src.avatar")
local harness = require("src.harness")
local sfx = require("src.sfx")
local music = require("src.music")
local layout = require("src.layout")
local text = require("src.text")

local M = {
  W = 480,
  H = 270,
  L = layout.compute(480, 270),

  ready = false,
  demo = false,
  -- Set while the weights are being fetched: fraction, bytes and which file.
  download = nil,
  status = nil,
  -- Where the checkpoint lives on disk, once the worker has worked it out.
  weights = nil,
  busy = false,
  thinking = true,

  model = { alias = "?", architecture = "?", parameters = 0, quantization = "?" },
  stats = nil,
  cached = 0,
  cache_bytes = 0,
  memory = { active = 0, peak = 0 },

  -- Where the pointer is, in canvas pixels. `main` keeps it up to date;
  -- scenes hit-test their own buttons against it.
  mouse = { x = -1, y = -1 },
  -- What the window is doing, so a button can label itself without asking
  -- love.window every frame -- and so it reads right on the frame between a
  -- click and the change actually happening.
  window = { portrait = false, fullscreen = false },

  shake_amount = 0,
  flash_amount = 0,
  flash_slot = "white",
  glitch_amount = 0,
  toasts = {},
  -- True while a scene has an overlay open, so nothing is drawn over it.
  modal = false,
  toast_mute = false,
}

--- The character the model is asked to play. It is speaking through a
--- sixteen-colour terminal in a library, and the prompt says so: without the
--- instruction about length, a 27B model writes essays that scroll off a
--- forty-eight column panel before you can read them.
M.SYSTEM = [[
You are JARVIS, a familiar bound to a cartridge in the Baroque library hall of
the Klementinum in Prague. You run entirely on this machine: nothing you are
asked leaves it.

You are speaking through a sixteen-colour terminal, so write short paragraphs
and keep an answer under about a hundred and twenty words unless more is
actually asked for. Plain words. Dry rather than grand. You may admit when you
do not know something; you never pretend to have looked anything up, because
the harness that would let you do that is not yet wired in.
]]

function M.load(options)
  options = options or {}
  M.source = options.source
  M.lua_dir = options.lua_dir
  M.model_alias = options.model or "qwen3.8:27b-mlx"
  M.want_demo = options.demo or false

  M.timeline = tween.new()
  M.fx = particles.new()          -- in front of the avatar
  M.bg_fx = particles.new()       -- behind it: embers, dust, rain
  M.avatar = avatar.new(93, 104)
  M.log = {}

  harness.load()
  M.set_size(options.width or M.W, options.height or M.H, options.layout)

  M.cmd = love.thread.getChannel("jarvis.cmd")
  M.evt = love.thread.getChannel("jarvis.evt")
  M.stop = love.thread.getChannel("jarvis.stop")

  M.worker = love.thread.newThread("worker.lua")
  M.worker:start(M.lua_dir, M.model_alias, M.want_demo and true or false,
    options.download and true or false)
  M.started_at = love.timer.getTime()
  return M
end

-- ------------------------------------------------------------- the model ---

--- Resize, or turn on the side. Everything placed against the canvas -- the
--- layout table, the knight, the ring of sockets -- is recomputed from one
--- call, so a scene never holds a rectangle of its own.
function M.set_size(width, height, prefer)
  M.W, M.H = width, height
  if prefer ~= nil then M.layout_pref = prefer end
  M.L = layout.compute(width, height, M.layout_pref, M.text_pref)
  -- The layout picks the font size along with everything else, and sets it
  -- here so that nothing downstream can measure text at one scale and draw it
  -- at another.
  text.set_scale(M.L.text_scale)
  if M.avatar then
    M.avatar.x, M.avatar.y = M.L.avatar.x, M.L.avatar.y
  end
  harness.layout(M.L.avatar.x, M.L.avatar.y - 2, M.L.ring)
  return M.L
end

function M.ask(text, params)
  if M.busy or not M.ready then return false end
  M.busy = true
  M.cmd:push({
    op = "send",
    text = text,
    params = params or {
      temperature = 0.7,
      max_tokens = 700,
      enable_thinking = M.thinking,
      effort = "low",
    },
  })
  return true
end

function M.interrupt()
  if not M.busy then return false end
  M.stop:push(true)
  return true
end

function M.reset() M.cmd:push({ op = "reset" }) end

--- Ask the worker how much room the checkpoint takes.
function M.measure_weights()
  local where = M.weights
  if not where or not where.path then return false end
  M.cmd:push({ op = "weights", path = where.path })
  return true
end

--- Erase the downloaded checkpoint. The worker refuses anything that does not
--- look like the Hugging Face cache entry it computed itself.
function M.clear_weights()
  local where = M.weights or (M.download and { path = M.download.dest })
  if not where or not where.path then return false end
  M.clearing = true
  M.cmd:push({ op = "clear", path = where.path })
  return true
end

--- Ask for a window change from a scene. `main` performs it between frames:
--- a button is drawn inside a canvas pass, and changing the window mode in
--- the middle of one tears the render target out from under the drawing that
--- has not happened yet.
--- Force the font size, or nil to let the layout choose. Returns the size in
--- force afterwards.
function M.set_text_size(n)
  M.text_pref = n
  M.set_size(M.W, M.H)
  return M.L.text_scale
end

function M.ask_window(change)
  if M.on_window_request then M.on_window_request(change) end
end

-- ------------------------------------------------------------ shutting down

--- Closing the window is not instant, and must not be.
---
--- MLX's Metal device is a C++ global: it is destroyed by the static
--- destructors that run on the main thread as the process exits. If the worker
--- is still inside `jarvis_send` when that happens it hands a freed compute
--- pipeline to the driver and the process dies with SIGSEGV on the way out --
--- which is what it did, twice in three runs, until the quit learned to wait.
---
--- So a quit is a two-step: interrupt the turn and ask the worker to close,
--- refuse the quit, and issue it again once the thread has actually gone. The
--- cap exists so that a wedged worker costs six seconds rather than the
--- window never closing.
function M.begin_shutdown()
  if M.closing then return end
  M.closing = true
  M.closing_since = love.timer.getTime()
  M.interrupt()
  M.quit_worker()
end

function M.shutdown_done()
  if not M.closing then return false end
  if not M.worker or not M.worker:isRunning() then return true end
  return love.timer.getTime() - M.closing_since > 6
end

--- How long it has been waiting, for the line it draws while it does.
function M.closing_for()
  if not M.closing then return 0 end
  return love.timer.getTime() - M.closing_since
end
function M.set_system(text) M.cmd:push({ op = "system", text = text }) end
function M.quit_worker() M.cmd:push({ op = "quit" }) end

--- Drain the event channel into whatever scene is listening. Anything the
--- scene does not care about is still recorded here, so a scene that starts
--- late still knows the model is up.
function M.pump()
  while true do
    local event = M.evt:pop()
    if not event then break end

    if event.ev == "ready" then
      M.ready = true
      M.demo = event.demo and true or false
      M.model = event.info or M.model
      M.library = event.library
      M.version = event.version
      M.load_seconds = love.timer.getTime() - M.started_at
      if not M.demo then M.set_system(M.SYSTEM) end
    elseif event.ev == "fallback" then
      M.fallback_reason = event.text
    elseif event.ev == "download_start" then
      M.download = { fraction = 0, done = 0, total = 0, file = "",
                     files_done = 0, files_total = 0,
                     dest = event.dest, repo = event.repo }
    elseif event.ev == "download" then
      local was = M.download or {}
      M.download = {
        fraction = event.fraction or 0,
        done = event.done or 0,
        total = event.total or 0,
        file = event.file or "",
        files_done = event.files_done or 0,
        files_total = event.files_total or 0,
        dest = was.dest,
        repo = was.repo,
      }
    elseif event.ev == "download_done" then
      M.download = nil
      M.downloaded = true
    elseif event.ev == "status" then
      M.status = event.text
    elseif event.ev == "where" then
      M.weights = { repo = event.repo, path = event.path, bytes = nil }
      M.measure_weights()
    elseif event.ev == "weights_size" then
      if M.weights then M.weights.bytes = event.bytes end
    elseif event.ev == "cleared" then
      M.clearing = false
      M.cleared = event.ok and true or false
    elseif event.ev == "done" then
      M.busy = false
      M.stats = event.stats
      M.cached = event.cached or M.cached
      M.cache_bytes = event.cache_bytes or M.cache_bytes
      M.memory = event.memory or M.memory
    elseif event.ev == "error" then
      M.busy = false
    end

    if M.on_event then M.on_event(event) end
  end
end

-- --------------------------------------------------------------- feedback --

function M.shake(amount) M.shake_amount = math.max(M.shake_amount, amount) end

function M.flash(amount, slot)
  M.flash_amount = math.max(M.flash_amount, amount)
  M.flash_slot = slot or "white"
end

function M.glitch(amount) M.glitch_amount = math.max(M.glitch_amount, amount) end

--- A line that slides in at the top, holds and goes. Used for everything the
--- game wants to say that is not part of the conversation.
function M.toast(text, slot, seconds)
  -- The boot screen bolts eight plates on in a few seconds and does not want
  -- eight banners about it; the sparks say it better.
  if M.toast_mute then return end
  M.toasts[#M.toasts + 1] = {
    text = text, slot = slot or "gold",
    life = seconds or 2.6, age = 0,
  }
  if #M.toasts > 3 then table.remove(M.toasts, 1) end
end

function M.update(dt)
  M.pump()

  if M.closing and M.shutdown_done() then love.event.quit() end
  M.timeline:update(dt)
  M.fx:update(dt)
  M.bg_fx:update(dt)
  harness.update(dt)
  M.avatar:update(dt, harness.power())
  music.update(dt)

  M.shake_amount = math.max(0, M.shake_amount - dt * 2.4)
  M.flash_amount = math.max(0, M.flash_amount - dt * 2.8)
  M.glitch_amount = math.max(0, M.glitch_amount - dt * 2.0)

  local i = 1
  while i <= #M.toasts do
    local toast = M.toasts[i]
    toast.age = toast.age + dt
    if toast.age >= toast.life then table.remove(M.toasts, i) else i = i + 1 end
  end

  -- The music follows the model: the drums come in while it is working and
  -- fade back to the pad when it stops.
  music.intensity(M.busy and 1 or (harness.power() * 0.35))
end

--- How far the screen is displaced this frame, in whole pixels.
function M.shake_offset()
  if M.shake_amount <= 0 then return 0, 0 end
  local a = M.shake_amount * 5
  return math.floor((love.math.random() - 0.5) * a),
         math.floor((love.math.random() - 0.5) * a)
end

-- ------------------------------------------------------------ the harness --

--- The scene wires this up so that the harness can announce itself without
--- knowing about particles or sound.
function M.wire_harness()
  harness.on_event = function(kind, module, extra)
    if kind == "equip" then
      sfx.play("clank", 0.9 + love.math.random() * 0.3)
    elseif kind == "seated" then
      local x, y = module.x, module.y
      M.fx:burst(x, y, 14, { ramp = module.ramp, speed = 46, life = 0.5 })
      M.fx:ring(x, y, 10, { ramp = module.ramp, speed = 34, life = 0.35, radius = 4 })
      M.shake(0.25)
      M.toast(module.name .. " ONLINE", module.slot, 1.6)
    elseif kind == "lost" then
      sfx.play("damage")
      M.fx:shards(module.x, module.y, 12, { ramp = module.ramp, floor = 230, speed = 100 })
      M.fx:burst(module.x, module.y, 20, { ramp = "blood", speed = 70 })
      M.shake(1)
      M.flash(0.5, "red")
      M.avatar:hit()
      M.toast(module.name .. " LOST", "red", 2)
    elseif kind == "remove" then
      sfx.play("deny")
      M.fx:burst(module.x, module.y, 8, { ramp = "steel", speed = 30, life = 0.4 })
      M.toast(module.name .. " OFFLINE", "gray", 1.4)
    elseif kind == "suitup" then
      sfx.play("suitup")
      local cx, cy = M.avatar:centre()
      M.fx:ring(cx, cy, 40, { ramp = "holy", speed = 120, life = 0.9, radius = 6 })
      M.fx:burst(cx, cy, 60, { ramp = "holy", speed = 90, life = 1.1 })
      M.flash(0.8, "white")
      M.shake(1.2)
      M.avatar:set_state("triumph")
      M.timeline:after(1.2, function()
        if not M.busy then M.avatar:set_state("idle") end
      end)
      M.toast("HARNESS COMPLETE", "yellow", 2.6)
    elseif kind == "fault" then
      sfx.play("error")
      M.toast(module.name .. " FAULTED", "red", 3)
      M.glitch(1)
    end
  end
end

return M
