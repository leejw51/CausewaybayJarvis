--- The conversation.
---
--- Left: the model, floating in the hall with its harness around it. Right:
--- what it said. Underneath: what you are about to say. Every token that
--- arrives moves something -- the mouth, a spark off the core, a plate in the
--- ring -- because the point of this client is to make a thing that is mostly
--- waiting feel like a thing that is mostly happening.
---
--- Slash commands mirror `rustcli` and `lua/chat.lua`, so muscle memory
--- carries across: /reset /think /stats /system /plate /suit /hit /help.

local palette = require("src.palette")
local text = require("src.text")
local ui = require("src.ui")
local sfx = require("src.sfx")
local music = require("src.music")
local art = require("src.art")
local app = require("src.app")
local harness = require("src.harness")
local toggles = require("src.toggles")
local settings = require("src.settings")
local transcript = require("src.transcript")
local store = require("src.store")
local utf8 = require("utf8")

local S = {}

-- What the input box will hold. A paste is clamped to it, the same as typing.
local INPUT_MAX = 400

-- Where everything goes comes from `app.L`, which `layout.compute` builds
-- from the canvas size. Turning the client swaps the canvas and rebuilds that
-- table; nothing in this file holds a rectangle of its own.

local ROLES = {
  you    = { slot = "lime", glyph = "tri_r", label = "YOU" },
  jarvis = { slot = "white", glyph = "orb", label = "JARVIS" },
  system = { slot = "gray", glyph = "dot", label = "SYSTEM" },
  error  = { slot = "red", glyph = "skull", label = "FAULT" },
}

-- ------------------------------------------------------------- the log ----

local function columns() return math.floor((app.L.log.w - 12) / app.L.cell) end

function S:say(role, body, options)
  options = options or {}
  body = text.ascii(body)
  local entry = {
    role = role,
    body = body,
    lines = text.wrap(body, columns() - 2),
    age = 0,
    slot = options.slot,
  }
  self.log[#self.log + 1] = entry
  if #self.log > 120 then table.remove(self.log, 1) end
  self.scroll = 0
  return entry
end

--- Open the thought window, once.
---
--- This used to be `if self.show_reasoning < 1 then start a tween end`, called
--- from the reasoning handler -- which fires about twenty-six times a second.
--- Every chunk that arrived while the window was still opening saw a value
--- below one, reset it to nothing and started *another* tween, so nine of them
--- at a time fought over the same variable and the window collapsed and sprang
--- back on almost every frame. That was the trembling. A window that is opening
--- is not a window that needs opening.
function S:open_thought()
  if self.thought_state == "open" then return end
  self.thought_state = "open"
  if self.thought_tween then app.timeline:cancel(self.thought_tween) end
  self.show_reasoning = 0.001
  self.thought_tween = app.timeline:run(0.35, "outBack", function(p)
    self.show_reasoning = p
  end)
end

--- Close it. `now` skips the pause, for a turn that is starting.
function S:close_thought(now)
  if self.thought_tween then
    app.timeline:cancel(self.thought_tween)
    self.thought_tween = nil
  end
  if now then
    self.thought_state = nil
    self.show_reasoning = 0
    return
  end
  if self.thought_state ~= "open" then return end
  self.thought_state = "closing"
  -- A beat to finish reading it, then down.
  self.thought_tween = app.timeline:run(0.3, "inQuad", function(p)
    self.show_reasoning = 1 - p
  end, 1.1)
  self.thought_tween.on_done = function() self.thought_state = nil end
end

--- Re-wrap everything already said, because the panel changed width.
---
--- Lines are wrapped once, when they arrive, so that scrolling costs nothing.
--- That is the right trade until the screen is turned on its side and every
--- line in the transcript is four characters too long for the panel it is
--- being drawn in.
function S:relayout()
  local cols = columns() - 2
  if cols == self.wrapped_at then return end
  self.wrapped_at = cols
  for _, entry in ipairs(self.log) do
    entry.lines = text.wrap(entry.body, cols)
  end
  self.reasoning_lines = text.wrap(self.reasoning,
    math.floor((app.L.think.w - 10) / app.L.cell))
  self.scroll = math.min(self.scroll, self:max_scroll())
end

--- Rewrap the streaming reply in place. Cheap enough at forty-seven columns
--- to do on every token, and doing it any other way means the last line of a
--- paragraph jumps when the word that broke it finally arrives.
function S:restream()
  local entry = self.streaming
  if not entry then return end
  -- The first chunk after a think block usually starts with a newline or
  -- two, which would open the reply with a blank line under its own header.
  local body = self.stream:gsub("^%s+", "")
  entry.body = body
  entry.lines = text.wrap(body, columns() - 2)
  if self.scroll == 0 then return end
  self.scroll = math.min(self.scroll, self:max_scroll())
end

function S:total_lines()
  local n = 0
  for _, entry in ipairs(self.log) do n = n + #entry.lines + 1 end
  return n
end

--- How many lines the transcript panel can hold *inside* its frame. A titled
--- panel spends its first line on the title and four pixels on its border, and
--- counting from the outer height drew one row through the bottom edge.
function S:visible_lines()
  return math.max(1, math.floor((app.L.log.h - text.height() - 9) / app.L.line))
end
function S:max_scroll() return math.max(0, self:total_lines() - self:visible_lines()) end

-- ----------------------------------------------------------- the rails ----

--- Buttons cut into a panel's top rail, where `ui.panel` puts its title.
---
--- Measured in one pass and drawn in another, because the title has to be
--- decided *before* the panel draws it and the buttons have to be drawn
--- *after* the masonry is finished, or the border paints over them.
---
--- `rail_fit` drops buttons off the front of the list when the row runs out,
--- so the last item is the last to go -- and then the title is clipped to
--- whatever is left, or dropped. At three times the font on a narrow canvas
--- there is room for one or the other, and a button you can press is worth
--- more than a word you can read.
local function rail_fit(rect, items)
  local inset, gap = app.L.rail_inset, app.L.rail_gap
  local right, left = rect.x + rect.w - inset, rect.x + inset
  local shown = {}
  for i = #items, 1, -1 do
    local w = ui.button_width(items[i].label)
    if right - w < left then break end
    right = right - w
    table.insert(shown, 1, items[i])
    right = right - gap
  end
  return right + gap, shown
end

--- The title the rail has room for, or nil for none. `ui.panel` pads it with
--- a space on each side, which is why two columns come off the top.
local function rail_title(rect, limit, label)
  local room = math.floor((limit - rect.x - app.L.rail_inset) / app.L.cell) - 2
  if room < 4 then return nil end
  return text.clip(label, room)
end

--- Draw what `rail_fit` said would fit, and keep the rectangles for the click.
function S:rail_draw(rect, shown)
  -- `rect` is the rail itself, which `layout` already put a pixel above the
  -- panel: the button straddles the top course the way the title does.
  local h, gap, y = app.L.rail_h, app.L.rail_gap, rect.y
  local right = rect.x + rect.w - app.L.rail_inset
  for i = #shown, 1, -1 do
    local item = shown[i]
    local w = ui.button_width(item.label)
    right = right - w
    local hot = app.mouse.x >= right and app.mouse.x < right + w
      and app.mouse.y >= y and app.mouse.y < y + h
    local drawn = ui.button(right, y, w, h, item.label,
      { slot = item.slot, hot = hot })
    self.hotspots[#self.hotspots + 1] = { rect = drawn, action = item.action }
    right = right - gap
  end
end

-- ------------------------------------------------- out of the transcript --

--- Which model said this, for the head of an exported file.
function S:transcript_meta()
  return {
    model = app.demo and "demo - recorded" or ((app.model or {}).alias),
    stamp = os.date("%Y-%m-%d %H:%M:%S"),
  }
end

--- Refuse politely, in the one voice the client uses for it.
local function deny(message)
  sfx.play("deny")
  app.toast(message, "orange", 1.6)
  return false
end

--- The whole panel onto the clipboard, as plain text.
---
--- `txt` rather than a choice of format: this is the button for pasting the
--- conversation into something else, and every something else takes plain
--- text. Choosing is what EXPORT is for.
function S:copy_log()
  if #self.log == 0 then return deny("NOTHING TO COPY YET") end
  if not (love.system and love.system.setClipboardText) then
    return deny("NO CLIPBOARD ON THIS BUILD")
  end
  love.system.setClipboardText(transcript.render(self.log, "txt", self:transcript_meta()))
  sfx.play("confirm")
  app.toast(string.format("%d MESSAGES COPIED", #self.log), "lime", 2)
  return true
end

--- One file, in one of the four shapes `transcript` writes. The stamp is
--- passed in so that a whole set shares a name and sorts together.
function S:export_one(format, stamp, meta)
  local name = transcript.filename(format, stamp)
  local path, why = store.write(name, transcript.render(self.log, format, meta))
  return path and name or nil, why
end

--- The whole panel out, in all four shapes at once.
---
--- All four rather than a chooser: they are four views of the same
--- conversation, none of them is more than a few kilobytes, and being asked
--- which one you want before you know what you are going to do with it is a
--- question with no good answer. One stamp for the set, so the four files sort
--- together and read as what they are -- one export, four shapes.
---
--- They land in `~/.causewaybayjarvis`, which is where this project keeps its
--- state -- not the LOVE save folder, which is a path under Application
--- Support that nothing else here would look in. The card that opens
--- afterwards says where they went, because a toast is gone in two seconds and
--- the path is the point.
function S:export_all()
  if #self.log == 0 then return deny("NOTHING TO EXPORT YET") end
  local stamp = os.date("%Y%m%d-%H%M%S")
  local meta = self:transcript_meta()

  local written, failed = {}, {}
  for _, format in ipairs(transcript.FORMATS) do
    local name, why = self:export_one(format, stamp, meta)
    if name then written[#written + 1] = name
    else failed[#failed + 1] = transcript.LABEL[format] .. ": " .. tostring(why) end
  end

  self.export_result = {
    count = #self.log,
    written = written,
    failed = failed,
    folder = store.tilde(store.DIR),
  }

  if #written == 0 then
    sfx.play("error")
    self:say("error", "export failed: " .. table.concat(failed, "; "))
    return false
  end

  sfx.play("confirm")
  app.toast(string.format("%d FILES WRITTEN", #written), "lime", 2.6)
  self:say("system", string.format("%d messages written to %s/transcript-%s.*",
    #self.log, self.export_result.folder, stamp), { slot = "cyan" })
  self:open_overlay("export")
  return true
end

--- Trim to a byte budget without cutting a character in half.
---
--- The input box is capped in bytes, and a clipboard is not ASCII. Cutting
--- mid-sequence leaves a byte the font folds to `?` on the screen and the
--- tokenizer sees as broken UTF-8 in the prompt.
local function clamp_utf8(s, bytes)
  if #s <= bytes then return s end
  local cut = bytes + 1
  while cut > 1 do
    local byte = s:byte(cut)
    if not byte or byte < 0x80 or byte >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut - 1)
end

--- The clipboard into the input box, appended where the cursor is -- which is
--- always the end, because the box has no cursor to move.
---
--- Line breaks are folded to spaces: the box is one line, ENTER sends, and a
--- pasted paragraph that kept its newlines would be drawn as a row of `?` and
--- sent looking nothing like what was copied.
function S:paste()
  if not (love.system and love.system.getClipboardText) then
    return deny("NO CLIPBOARD ON THIS BUILD")
  end
  local clip = love.system.getClipboardText()
  if not clip or clip == "" then return deny("THE CLIPBOARD IS EMPTY") end

  clip = clip:gsub("%s+", " ")
  if self.input == "" then clip = clip:gsub("^ +", "") end
  if clip == "" then return deny("THE CLIPBOARD IS EMPTY") end

  local room = INPUT_MAX - #self.input
  if room <= 0 then return deny("THE BOX IS FULL") end
  local kept = clamp_utf8(clip, room)
  self.input = self.input .. kept
  sfx.play("key", 0.7)
  if #kept < #clip then
    app.toast("PASTED, TRIMMED TO " .. INPUT_MAX, "orange", 1.8)
  end
  return true
end

-- ---------------------------------------------------------- the overlays --

function S:open_overlay(which)
  self.overlay = which
  self.overlay_t = 0
  app.modal = true
  sfx.play("open")
end

function S:close_overlay()
  if not self.overlay then return end
  self.overlay = nil
  app.modal = false
  sfx.play("page")
end

-- ------------------------------------------------------------ the scene ---

function S:enter()
  self.log = self.log or {}
  self.input = self.input or ""
  self.history = self.history or {}
  self.history_at = 0
  self.scroll = 0
  self.blink = 0
  self.time = 0
  self.wrapped_at = nil
  self.reasoning = ""
  self.reasoning_lines = {}
  self.show_reasoning = 0        -- animated height, 0..1
  self.thought_state = nil       -- nil, "open" or "closing"
  self.thought_tween = nil
  self.prefill = nil
  self.overlay = nil             -- "harness" | "help" | "export" | nil
  self.overlay_t = 0
  self.hotspots = {}
  self.export_result = nil       -- what the last export wrote, for its card
  self.stream = ""
  self.streaming = nil
  self.since_blip = 0
  self.turn_started = 0
  self.plate = app.plate
  self.pan = { x = 0, y = 0, tx = 0, ty = 0 }

  app.avatar:set_state("idle")

  if #self.log == 0 then
    self:say("system", "Cartridge seated. " ..
      (app.demo and "No weights on this machine, so this is the recorded model: every effect is real, the answers are not."
                 or "The model is resident and nothing you type leaves this machine."))
    self:say("system", "TAB opens the harness. F1 is the key card. Type and press ENTER.")
    if app.fallback_reason then
      self:say("system", "why: " .. tostring(app.fallback_reason), { slot = "orange" })
    end
  end

  app.on_event = function(event) self:on_event(event) end

  -- Ambience: whatever the plate says it has in the air.
  local plate = art.plate(self.plate)
  self.ember_rate = plate and plate.embers and plate.embers.rate or 4
  self.ember_ramp = plate and plate.embers and plate.embers.ramp or "fire"
  self.storm = plate and plate.storm
end

function S:leave() app.on_event = nil end

-- ------------------------------------------------------------- the model --

function S:submit()
  local line = self.input:gsub("^%s+", ""):gsub("%s+$", "")
  if line == "" then return end

  local function accept()
    self.input = ""
    self.history[#self.history + 1] = line
    self.history_at = 0
  end

  -- Commands are local and always go through, including while it is speaking:
  -- /hit and /help are most wanted exactly then.
  if line:sub(1, 1) == "/" then
    accept()
    self:command(line)
    return
  end

  -- A turn cannot start while one is running -- but what you typed is not
  -- mine to throw away. It stays in the box, so ENTER sends it the moment the
  -- answer stops.
  if app.busy then
    sfx.play("deny")
    app.toast("IT IS STILL SPEAKING -- ESC STOPS IT", "orange", 1.6)
    return
  end
  if not app.ready then
    sfx.play("deny")
    app.toast("THE ROM IS STILL READING", "orange", 1.4)
    return
  end

  accept()
  self:say("you", line)
  sfx.play("confirm")

  -- The harness gets the turn first. Nothing is wired to these hooks yet, so
  -- `ctx.prompt` comes back as it went in -- but this is where a memory module
  -- would rewrite it, and the call is here so that wiring one up is the only
  -- change needed.
  local ctx = harness.emit("on_turn_start", { prompt = line })
  harness.pulse()

  app.ask(ctx.prompt or line, {
    temperature = 0.7,
    max_tokens = 700,
    enable_thinking = app.thinking,
    effort = "low",
  })
end

function S:on_event(event)
  local kind = event.ev

  if kind == "turn_start" then
    self.turn_started = love.timer.getTime()
    self.stream = ""
    self.reasoning = ""
    self.reasoning_lines = {}
    self.prefill = { done = 0, total = 1 }
    self.last_pulse = 0
    self:close_thought(true)
    app.avatar:set_state("think")
    sfx.play("charge")
    local cx, cy = app.avatar:centre()
    app.fx:draw_in(cx, cy, 26, { ramp = "arcane", radius = 70, life = 0.8 })

  elseif kind == "prefill" then
    self.prefill = { done = event.done or 0, total = math.max(event.total or 1, 1) }
    harness.emit("on_prefill", self.prefill)
    if love.math.random() < 0.3 then
      local cx, cy = app.avatar:centre()
      app.fx:draw_in(cx, cy, 3, { ramp = "arcane", radius = 60, life = 0.7 })
    end

  elseif kind == "reasoning" then
    self.prefill = nil
    self.reasoning = self.reasoning .. text.ascii(event.text or "")
    self.reasoning_lines = text.wrap(self.reasoning,
      math.floor((app.L.think.w - 10) / app.L.cell))
    harness.emit("on_reasoning", { text = event.text })
    self:open_thought()

    -- Everything below fires once every half second rather than once per
    -- chunk. Reasoning arrives about twenty-six times a second: at that rate
    -- a ring flash is a flicker and a blip is a buzz.
    local now = love.timer.getTime()
    if now - (self.last_pulse or 0) > 0.5 then
      self.last_pulse = now
      harness.pulse(0.35)
      sfx.play("think", 0.8 + love.math.random() * 0.4, 0.5)
    end

  elseif kind == "reasoning_done" then
    self:close_thought()

  elseif kind == "token" then
    self.prefill = nil
    if not self.streaming then
      app.avatar:set_state("speak")
      self.streaming = self:say("jarvis", "")
      self.stream = ""
    end
    self.stream = self.stream .. text.ascii(event.text or "")
    self:restream()
    app.avatar:said(event.text)
    harness.emit("on_token", { text = event.text })

    -- One blip per few tokens, not per token: at seventeen a second the
    -- unthrottled version is a tone, not a voice.
    self.since_blip = self.since_blip + 1
    if self.since_blip >= 2 then
      self.since_blip = 0
      sfx.play("blip", 0.85 + love.math.random() * 0.5, 0.8)
      local cx, cy = app.avatar:centre()
      app.fx:burst(cx + 2, cy - 3, 1, { ramp = "holy", speed = 30, life = 0.5, spread = 1.2, heading = -0.5 })
    end

  elseif kind == "done" then
    self.prefill = nil
    if self.streaming then
      self.stream = text.ascii(event.text or self.stream)
      self:restream()
    elseif event.text and event.text ~= "" then
      self:say("jarvis", event.text)
    end
    self.streaming = nil
    app.avatar:set_state("idle")
    harness.emit("on_turn_end", { reply = event.text, stats = event.stats })
    harness.pulse()
    sfx.play("msg")

    local stats = event.stats or {}
    if event.stop_reason == "interrupted" then
      self:say("system", "-- stopped --", { slot = "orange" })
    elseif event.stop_reason == "max_tokens" then
      self:say("system", "-- token budget spent --", { slot = "orange" })
    end
    app.toast(string.format("%.1f tok/s  -  %d generated",
      stats.decode_tps or 0, stats.generated_tokens or 0), "cyan", 2.2)

  elseif kind == "error" then
    self.prefill = nil
    self.streaming = nil
    app.avatar:hit()
    app.glitch(1)
    sfx.play("error")
    self:say("error", tostring(event.text or "something went wrong"))
    harness.emit("on_error", { message = event.text })
    -- A fault costs a plate. Ghosts'n Goblins rules.
    harness.lose_one()

  elseif kind == "reset" then
    self:say("system", "The conversation is forgotten. The weights are not.")
  end
end

-- ------------------------------------------------------------ commands ----

-- Kept to twenty-eight characters so the card fits the narrow screen too:
-- turned on its side there are two hundred and seventy pixels to play with,
-- and a description that overruns is centred straight through the border.
local HELP = {
  { "ENTER", "send" },
  { "ESC", "stop, or close a window" },
  { "TAB", "the harness" },
  { "1-8", "bolt a module on or off" },
  { "F9", "suit up, all of it" },
  { "F10", "take a hit, lose a plate" },
  { "F1", "this card" },
  { "F2", "palette: SNES/MSX/APPLE" },
  { "F3", "the plate behind you" },
  { "F7", "layout: across or down" },
  { "F12", "settings" },
  { "F8", "text size" },
  { "F11", "fullscreen" },
  { "F4 F5 F6", "music, sound, the tube" },
  { "PGUP/PGDN", "scroll the log" },
  { "CTRL-E", "export all four formats" },
  { "CTRL-C", "copy it to the clipboard" },
  { "CTRL-V", "paste into the box" },
  { "CTRL-R", "forget the conversation" },
  { "CTRL-T", "reasoning on or off" },
}

-- Kept to forty-two characters, which is what the card holds at its own width.
local COMMANDS = {
  "/help /reset /think /stats /system",
  "/export /copy /paste /plate /palette",
  "/suit /hit /strip /quit",
}

function S:command(line)
  local name, rest = line:match("^/(%S+)%s*(.*)$")
  name = (name or ""):lower()

  if name == "help" then
    self:open_overlay("help")
  elseif name == "export" then
    -- `/export csv` writes it; `/export` on its own opens the card, which is
    -- what the button does.
    local format = (rest:lower():gsub("%s+$", ""))
    if format == "" then
      self:export_all()
    elseif transcript.has(format) then
      -- One shape on its own, for when you know which you want. The card is
      -- for the button, which writes the set.
      local name, why = self:export_one(format, os.date("%Y%m%d-%H%M%S"),
        self:transcript_meta())
      if name then
        sfx.play("confirm")
        self:say("system", "written to " .. store.tilde(store.DIR) .. "/" .. name,
          { slot = "cyan" })
      else
        sfx.play("error")
        self:say("error", "export failed: " .. tostring(why))
      end
    else
      self:say("system", "no such format: " .. format .. " -- try "
        .. table.concat(transcript.FORMATS, " "), { slot = "orange" })
      sfx.play("deny")
    end
  elseif name == "copy" then
    self:copy_log()
  elseif name == "paste" then
    self:paste()
  elseif name == "reset" or name == "clear" then
    -- The line announcing this comes back with the worker's `reset` event,
    -- which CTRL-R also produces; saying it here as well printed it twice.
    app.reset()
    self.log = {}
    sfx.play("select")
  elseif name == "think" then
    app.thinking = rest ~= "off"
    self:say("system", "reasoning " .. (app.thinking and "on" or "off"))
  elseif name == "system" then
    if rest == "" then
      self:say("system", app.SYSTEM)
    else
      app.set_system(rest)
      self:say("system", "system prompt replaced; the cache goes with it")
    end
  elseif name == "stats" then
    local s = app.stats
    if not s then
      self:say("system", "nothing generated yet")
    else
      self:say("system", string.format(
        "prompt %d (%d cached) - generated %d - prefill %.1f tok/s - decode %.1f tok/s - peak %.1f GiB",
        s.prompt_tokens or 0, s.cached_prompt_tokens or 0, s.generated_tokens or 0,
        s.prefill_tps or 0, s.decode_tps or 0, (s.peak_memory or 0) / 2 ^ 30))
    end
  elseif name == "plate" then
    self:cycle_plate(rest ~= "" and rest or nil)
  elseif name == "palette" then
    palette.use(rest ~= "" and rest or "msx")
    require("src.shaders").send_palette()
    art.rebake()
    self:say("system", "palette " .. palette.label)
  elseif name == "suit" then
    harness.suit_up(app.timeline)
  elseif name == "hit" then
    if not harness.lose_one() then app.toast("NOTHING LEFT TO LOSE", "gray", 1.4) end
  elseif name == "strip" then
    harness.strip(true)
  elseif name == "quit" or name == "exit" then
    love.event.quit()
  else
    self:say("system", "no such command: /" .. name .. " -- try /help", { slot = "orange" })
    sfx.play("deny")
  end
end

function S:cycle_plate(name)
  if name and art.has(name) then
    self.plate = name
  else
    local at = 1
    for i, plate in ipairs(art.order) do if plate == self.plate then at = i end end
    self.plate = art.order[at % #art.order + 1]
  end
  app.plate = self.plate
  local plate = art.plate(self.plate)
  self.ember_rate = plate.embers and plate.embers.rate or 4
  self.ember_ramp = plate.embers and plate.embers.ramp or "fire"
  self.storm = plate.storm
  app.bg_fx:clear()
  sfx.play("page")
  app.toast(art.title(self.plate), "silver", 2)
end

-- -------------------------------------------------------------- update ----

function S:update(dt)
  self.time = self.time + dt
  settings.update(dt)
  self:relayout()
  self.blink = self.blink + dt
  if self.overlay then self.overlay_t = math.min(1, self.overlay_t + dt * 4) end

  -- The plate drifts, and leans towards whatever is happening.
  self.pan.tx = math.sin(self.time * 0.11) * 0.6 + (app.busy and 0.25 or 0)
  self.pan.ty = math.cos(self.time * 0.08) * 0.4
  self.pan.x = self.pan.x + (self.pan.tx - self.pan.x) * math.min(dt * 1.2, 1)
  self.pan.y = self.pan.y + (self.pan.ty - self.pan.y) * math.min(dt * 1.2, 1)

  -- Embers, dust, whatever the street has in the air.
  local stage = app.L.stage
  if love.math.random() < self.ember_rate * dt then
    app.bg_fx:rise(stage.x, stage.y + stage.h - 8, stage.w, 1,
      { ramp = self.ember_ramp, speed = 7, life = 3.4, wave = 3 })
  end
  if self.storm and love.math.random() < 0.012 then
    app.flash(0.35, "silver")
    sfx.play("thunder", 0.8 + love.math.random() * 0.5, 0.7)
  end

  -- While it thinks, the core pulls motes in. Sparsely: a dense stream of
  -- them converging on a figure that is holding still looks like static.
  if app.busy and love.math.random() < dt * 5 then
    local cx, cy = app.avatar:centre()
    app.fx:draw_in(cx, cy, 1, { ramp = app.avatar.state == "think" and "arcane" or "holy",
                                radius = 55 + love.math.random() * 20, life = 0.75 })
  end
end

-- --------------------------------------------------------------- input ----

function S:textinput(char)
  if self.overlay then return end
  if #self.input < INPUT_MAX then
    self.input = self.input .. char
    sfx.type(char)
  end
end

function S:keypressed(key, isrepeat)
  if settings.keypressed(key) then return end
  if key == "f12" then settings.toggle() return end
  if self.overlay then
    if key == "escape" or key == "tab" or key == "f1" or key == "return" then
      self:close_overlay()
    end
    return
  end

  -- `app.chord`, not `isDown`: a CMD whose release macOS's screen-capture
  -- overlay swallowed must not turn every letter into a command. And a chord
  -- that does run claims the character it would otherwise type -- without
  -- that, CTRL-V pastes and then types a `v` after it, and CTRL-R has been
  -- forgetting the conversation and leaving an `r` in the box since the day
  -- it was added.
  local ctrl = app.chord("lctrl", "rctrl", "lgui", "rgui")
  if ctrl and key:match("^[ecvrt]$") then app.eat_text = true end

  if key == "return" or key == "kpenter" then
    self:submit()
  elseif key == "backspace" then
    if #self.input > 0 then
      -- One character, not one byte: the input is UTF-8.
      local offset = utf8.offset(self.input, -1)
      self.input = offset and self.input:sub(1, offset - 1) or ""
      sfx.play("key", 0.7)
    end
  elseif key == "escape" then
    if app.busy then
      app.interrupt()
      app.toast("STOPPING", "orange", 1.2)
      sfx.play("deny")
    end
  elseif key == "tab" then
    self:open_overlay("harness")
  elseif key == "f1" then
    self:open_overlay("help")
  elseif key == "f3" then
    self:cycle_plate()
  elseif key == "f9" then
    if harness.equipped_count() == harness.count() then
      app.toast("ALREADY WEARING ALL OF IT", "gray", 1.4)
      sfx.play("deny")
    else
      harness.suit_up(app.timeline)
    end
  elseif key == "f10" then
    if not harness.lose_one() then
      app.toast("NOTHING LEFT TO LOSE", "gray", 1.4)
      sfx.play("deny")
    end
  elseif key == "up" then
    if #self.history > 0 then
      self.history_at = math.min(self.history_at + 1, #self.history)
      self.input = self.history[#self.history - self.history_at + 1] or ""
    end
  elseif key == "down" then
    self.history_at = math.max(0, self.history_at - 1)
    self.input = self.history_at == 0 and "" or (self.history[#self.history - self.history_at + 1] or "")
  elseif key == "pageup" then
    self.scroll = math.min(self.scroll + 6, self:max_scroll())
    sfx.play("page")
  elseif key == "pagedown" then
    self.scroll = math.max(self.scroll - 6, 0)
    sfx.play("page")
  elseif ctrl and key == "e" then
    self:export_all()
  elseif ctrl and key == "c" then
    self:copy_log()
  elseif ctrl and key == "v" then
    self:paste()
  elseif ctrl and key == "r" then
    self:command("/reset")
  elseif ctrl and key == "t" then
    app.thinking = not app.thinking
    app.toast(app.thinking and "REASONING ON" or "REASONING OFF", "magenta", 1.4)
    sfx.play("select")
  elseif key:match("^[1-8]$") then
    local module = harness.by_key(key)
    if module then harness.toggle(module.id) end
  end
end

function S:mousepressed(x, y, button)
  if button ~= 1 then return end
  if settings.open then settings.click(self.hotspots, x, y) return end
  if self.overlay then
    self:close_overlay()
    return
  end
  toggles.click(self.hotspots, x, y)
end

function S:wheelmoved(_, dy)
  self.scroll = math.max(0, math.min(self.scroll + dy * 3, self:max_scroll()))
end

-- ---------------------------------------------------------------- draw ----

--- The status bar: the name on the left, what it is doing and how fast in the
--- middle, and the two window buttons at the right end — where they are on
--- every screen, rather than tucked under the keyboard hints at the bottom of
--- one of them.
---
--- Everything is laid out from the right edge inwards and the model name gets
--- whatever is left; on a narrow screen that is often nothing, and nothing is
--- what it gets.
function S:status_bar()
  local BAR = app.L.bar
  local c = app.L.cell
  local ty = BAR.y + math.floor((BAR.h - text.height()) / 2)

  palette.set("black", 0.85)
  love.graphics.rectangle("fill", BAR.x, BAR.y, BAR.w, BAR.h)
  palette.set("gold", 0.7)
  love.graphics.rectangle("fill", BAR.x, BAR.y + BAR.h - 1, BAR.w, 1)

  text.icon("cart", 3, ty, "gold")
  text.print("JARVIS", 4 + c, ty, "gold")
  local left_end = 4 + c * 8

  local right = toggles.draw(BAR.w - 3, BAR.y + 3, self.hotspots)
  local setup_w = ui.button_width("SETUP")
  if right - setup_w > 20 * c then
    right = right - 3 - setup_w
    local hot = app.mouse.x >= right and app.mouse.x < right + setup_w
      and app.mouse.y >= BAR.y + 3 and app.mouse.y < BAR.y + 3 + app.L.button_h
    local rect = ui.button(right, BAR.y + 3, setup_w, app.L.button_h, "SETUP",
      { slot = "gold", hot = hot })
    self.hotspots[#self.hotspots + 1] = { rect = rect, action = function() settings.toggle() end }
  end
  right = right - 6

  -- Each of these is dropped rather than drawn on top of its neighbour when
  -- the row runs out: at three times the font size a 360-pixel bar holds the
  -- name, one number and the buttons, and nothing else.
  local function fits(label, gap)
    return right - text.width(label) - (gap or 0) > left_end
  end

  local stats = app.stats or {}
  local count = string.format("%d/%d", harness.equipped_count(), harness.count())
  if fits(count, c) then
    right = text.right(count, right, ty, "magenta") - c - 2
    text.icon("shield", right, ty, "magenta")
    right = right - 6
  end

  if stats.decode_tps and stats.decode_tps > 0 then
    local tps = string.format("%.1f tok/s", stats.decode_tps)
    if fits(tps, 8) then right = text.right(tps, right, ty, "cyan") - 8 end
  end
  if app.cached and app.cached > 0 then
    local cached = string.format("%d cached", app.cached)
    if right - text.width(cached) - 8 > left_end + c * 12 then
      right = text.right(cached, right, ty, "gray") - 8
    end
  end

  local state, slot = "IDLE", "lime"
  if not app.ready then state, slot = "MOUNTING", "orange"
  elseif app.avatar.state == "think" then state, slot = "THINKING", "cyan"
  elseif app.avatar.state == "speak" then state, slot = "SPEAKING", "yellow"
  elseif app.avatar.state == "hurt" then state, slot = "DAMAGED", "red" end
  if fits(state, 8) then right = text.right(state, right, ty, slot) - 8 end

  local model = app.model or {}
  local name = app.demo and "DEMO - RECORDED" or tostring(model.alias or "?")
  local room = math.floor((right - left_end) / c)
  if room >= 4 then text.print(text.clip(name, room), left_end, ty, "silver") end
end

function S:draw_log()
  local LOG = app.L.log

  -- EXPORT and COPY, cut into the top rail. Measured before the panel is
  -- drawn, because what is left over is the title's; drawn after it, because
  -- the masonry would paint over them.
  local limit, tools = rail_fit(app.L.log_rail, {
    { label = "EXPORT", slot = "lime", action = function() self:export_all() end },
    { label = "COPY", slot = "cyan", action = function() self:copy_log() end },
  })

  local x, y, w, h = ui.panel(LOG.x, LOG.y, LOG.w, LOG.h,
    { title = rail_title(app.L.log_rail, limit, "TRANSCRIPT"),
      rail = true, slot = "silver", fill = 0.88 })
  self:rail_draw(app.L.log_rail, tools)

  local visible = self:visible_lines()
  local flat = {}
  for _, entry in ipairs(self.log) do
    local role = ROLES[entry.role] or ROLES.system
    flat[#flat + 1] = { header = true, role = role, entry = entry }
    for _, line in ipairs(entry.lines) do
      flat[#flat + 1] = { text = line, role = role, entry = entry }
    end
  end

  local first = math.max(1, #flat - visible - self.scroll + 1)
  local last = math.min(#flat, first + visible - 1)
  local ly = y + 2

  local c = app.L.cell
  for i = first, last do
    local row = flat[i]
    local slot = row.entry.slot or row.role.slot
    if row.header then
      text.icon(row.role.glyph, x + 2, ly, slot)
      local label_x = x + 4 + c
      text.print(row.role.label, label_x, ly, slot, 0.85)
      local rule = label_x + text.width(row.role.label) + 3
      palette.set(slot, 0.25)
      love.graphics.rectangle("fill", rule, ly + math.floor(text.height() / 2),
        math.max(0, x + w - 2 - rule), 1)
    else
      text.print(row.text, x + 2 + c, ly, slot)
    end
    ly = ly + app.L.line
  end

  -- The cursor at the end of a streaming reply.
  if self.streaming and self.scroll == 0 and math.floor(self.blink * 3) % 2 == 0 then
    local tail = self.streaming.lines[#self.streaming.lines] or ""
    palette.set("white", 0.9)
    love.graphics.rectangle("fill", x + 2 + app.L.cell + text.width(tail),
      ly - app.L.line + 1, math.max(3, app.L.cell - 2), text.height() - 1)
  end

  -- Scroll position, as a rail down the right edge.
  local total = self:total_lines()
  if total > visible then
    local rail_h = h - 4
    local thumb = math.max(6, rail_h * visible / total)
    local fraction = 1 - self.scroll / math.max(self:max_scroll(), 1)
    palette.set("gray", 0.35)
    love.graphics.rectangle("fill", x + w - 2, y + 2, 2, rail_h)
    palette.set(self.scroll > 0 and "yellow" or "silver", 0.9)
    love.graphics.rectangle("fill", x + w - 2, y + 2 + (rail_h - thumb) * fraction, 2, thumb)
  end
end

function S:draw_stage()
  -- No panel here: the street is the panel. Night over it alone, because the
  -- transcript has its own ground and does not want to be blue.
  local STAGE, THINK = app.L.stage, app.L.think
  palette.set("deep", 0.14)
  love.graphics.rectangle("fill", STAGE.x, STAGE.y, STAGE.w, STAGE.h)

  app.bg_fx:draw()
  harness.draw(self.time)
  app.avatar:draw()
  app.fx:draw()

  -- What it is doing to your prompt, while it is doing it.
  if self.prefill then
    local done, total = self.prefill.done, self.prefill.total
    local px, py = STAGE.x + 6, STAGE.y + 6
    local step = text.height() + 2
    text.print("READING PROMPT", px, py, "cyan")
    ui.gauge(px, py + step, math.min(STAGE.w - 12, 22 * app.L.cell), 4,
      done / total, { ramp = "arcane", back = "gray" })
    text.print(string.format("%d / %d", done, total), px, py + step + 7, "gray")
  end

  -- The reasoning, in its own window, while there is any.
  if self.show_reasoning > 0.01 then
    local height = math.floor(THINK.h * self.show_reasoning)
    local y = THINK.y + THINK.h - height
    local ix, iy = ui.panel(THINK.x, y, THINK.w, height,
      { title = "THOUGHT", slot = "cyan", title_slot = "cyan", fill = 0.86, glow = "cyan" })
    local step = text.height() + 1
    local rows = math.floor((height - 14) / step)
    local first = math.max(1, #self.reasoning_lines - rows + 1)
    local ly = iy + 1
    for i = first, #self.reasoning_lines do
      text.print(self.reasoning_lines[i], ix + 2, ly, "cyan", 0.75)
      ly = ly + step
    end
  end
end

function S:draw_input()
  local busy = app.busy
  local INPUT, HINTS = app.L.input, app.L.hints

  -- PASTE, on the input box's own rail. It stays live while the model is
  -- speaking: what you paste then is what ENTER sends the moment it stops,
  -- which is the same deal typing already gets.
  local limit, tools = rail_fit(app.L.input_rail, {
    { label = "PASTE", slot = "cyan", action = function() self:paste() end },
  })

  local x, y, w = ui.panel(INPUT.x, INPUT.y, INPUT.w, INPUT.h, {
    title = rail_title(app.L.input_rail, limit,
      busy and "SPEAKING" or "SAY SOMETHING"),
    rail = true,
    slot = busy and "gold" or "silver",
    title_slot = busy and "gold" or "yellow",
    fill = 0.86,
  })
  self:rail_draw(app.L.input_rail, tools)

  local prompt = busy and "  " or "> "
  local room = math.floor(w / app.L.cell) - 3
  -- Folded for the screen only: what is sent is what was typed, so a model
  -- that understands more than ninety-five glyphs still gets them.
  local shown = text.ascii(self.input)
  if #shown > room then shown = shown:sub(#shown - room + 1) end

  text.print(prompt, x + 2, y + 2, busy and "gray" or "lime")
  text.print(shown, x + 2 + text.width(prompt), y + 2, busy and "gray" or "white")

  if not busy and math.floor(self.blink * 2) % 2 == 0 then
    palette.set("lime", 0.9)
    love.graphics.rectangle("fill", x + 2 + text.width(prompt) + text.width(shown),
      y + 2, math.max(3, app.L.cell - 2), text.height())
  end

  -- The key strip, which is where a manual would have gone, and the two
  -- window buttons at the end of it.
  palette.set("black", 0.7)
  love.graphics.rectangle("fill", 0, HINTS.y, app.W, HINTS.h)

  local hints = busy and "{gray}ESC{} stop the answer" or
    "{gray}TAB{} harness  {gray}1-8{} plates  {gray}F9{} suit up  {gray}F10{} take a hit  {gray}F1{} keys"
  text.print(text.clip(hints, math.floor(HINTS.w / app.L.cell)),
    HINTS.x, HINTS.y + 2, "silver", 0.9)
end

function S:draw_overlay()
  if not self.overlay then return end
  local t = self.overlay_t
  local eased = require("src.ease").outBack(math.min(t, 1))

  palette.set("black", 0.72 * math.min(t * 2, 1))
  love.graphics.rectangle("fill", 0, 0, app.W, app.H)

  if self.overlay == "harness" then
    local c, lh = app.L.cell, text.height()
    local n = #harness.all()
    local title_h = lh + 3
    local overhead = title_h + lh + 8 + (lh + 1) * 2 + 8
    local room = (app.H - 20) - overhead

    -- Two lines a module where there is room for two, one where there is not.
    -- The height used to be worked out from the font alone and then clamped to
    -- the screen, which on a letterboxed band meant the last module and both
    -- footers were drawn through the bottom of the panel.
    local two_line = app.L.text_scale <= 2 and room / n >= lh * 2 + 4
    local row_h = (two_line and lh * 2 or lh) + 4
    -- Fifty-four columns rather than forty-four: half the descriptions ran
    -- past forty-four and ended in a `~`, and the canvas has had the room for
    -- them since the scale stopped being taken at its coarsest.
    local pw = math.min(math.max(54 * c, 300), app.W - 12)
    local ph = math.min(overhead + n * row_h, app.H - 20)
    local h = math.floor(ph * eased)
    local x, y, w = ui.panel(math.floor((app.W - pw) / 2), math.floor((app.H - h) / 2), pw, h,
      { title = "THE HARNESS", slot = "gold", glow = "gold" })
    if h < 40 then return end

    text.print(text.clip("A bare model continues text. The rest is bolted on.",
      math.floor(w / c)), x + 2, y, "silver", 0.85)
    ui.divider(x + 2, y + lh + 3, w - 4, "gray")

    -- Everything is placed in character widths, so it holds together at any
    -- font size. Fixed pixel offsets put the whole card on top of itself the
    -- first time the letters got bigger.
    local name_x = x + 2 + c * 5
    local top = y + lh + 8
    for i, module in ipairs(harness.all()) do
      local row = top + (i - 1) * row_h
      local on = module.equipped
      palette.set(on and module.slot or "gray", on and 0.14 or 0.06)
      love.graphics.rectangle("fill", x + 1, row - 2, w - 2, row_h - 2)

      text.print("[" .. (module.key or "-") .. "]", x + 2, row, on and "yellow" or "gray")
      text.icon(module.glyph, x + 2 + c * 3.6, row, on and module.slot or "gray")

      -- The state is only worth its width if the name still has room for its
      -- own; below that the colour says it instead.
      local state = on and "ONLINE" or "EMPTY"
      local state_w = text.width(state) + c
      local name_room = math.floor((x + w - 2 - name_x - state_w) / c)
      if name_room >= #module.name then
        text.print(state, x + w - 2 - text.width(state), row, on and "lime" or "gray",
          on and 1 or 0.6)
      else
        name_room = math.floor((x + w - 2 - name_x) / c)
      end
      text.print(text.clip(module.name, name_room), name_x, row,
        on and module.slot or "gray")

      if two_line then
        text.print(text.clip(module.blurb, math.floor((x + w - 2 - name_x) / c)),
          name_x, row + lh, "silver", on and 0.8 or 0.4)
      end
    end

    local foot = top + #harness.all() * row_h + 2
    text.center(text.clip("F9 all of it  F10 lose one  TAB back", math.floor(w / c)),
      x, w, foot, "silver")
    text.center(text.clip("the hooks fire; nothing behind them is wired yet",
      math.floor(w / c)), x, w, foot + lh + 1, "orange", 0.75)

  elseif self.overlay == "help" then
    local c, lh = app.L.cell, text.height()
    local row_h = lh + 3
    local key_w = 11 * c
    -- Forty-four columns rather than thirty-eight: the commands underneath run
    -- to forty-two, and at thirty-eight the last two of every line were a `~`.
    local pw = math.min(math.max(44 * c, 260), app.W - 16)

    -- The command lines at the bottom are the first thing to go when the
    -- screen is short: the keys themselves are why the card is open.
    local body = (lh + 3) + #HELP * row_h + 6
    local footer = (lh + 1) * #COMMANDS + 4
    local ceiling = app.H - 24
    local with_footer = body + footer <= ceiling
    local ph = math.min(body + (with_footer and footer or 0), ceiling)

    local h = math.floor(ph * eased)
    local x, y, w = ui.panel(math.floor((app.W - pw) / 2), math.floor((app.H - h) / 2), pw, h,
      { title = "KEYS", slot = "cyan", glow = "cyan" })
    if h < 40 then return end
    local room = math.floor((w - key_w - 4) / c)
    local fits = math.max(1, math.floor((h - (lh + 3) - 6 -
      (with_footer and footer or 0)) / row_h))
    for i = 1, math.min(#HELP, fits) do
      local ly = y + (i - 1) * row_h
      text.print(HELP[i][1], x + 2, ly, "yellow")
      text.print(text.clip(HELP[i][2], room), x + 2 + key_w, ly, "silver")
    end
    if with_footer then
      local foot = y + #HELP * row_h + 2
      for i, line in ipairs(COMMANDS) do
        text.center(text.clip(line, math.floor(w / c)), x, w,
          foot + (i - 1) * (lh + 1), "gray")
      end
    end

  elseif self.overlay == "export" then
    -- What the last export wrote, and where. The card exists for the path:
    -- it is sixty characters, the toast that announced it is gone in two
    -- seconds, and nothing else on this screen can be selected and read at
    -- leisure.
    local result = self.export_result or { written = {}, failed = {}, folder = "?" }
    local c, lh = app.L.cell, text.height()

    local pw = math.min(math.max(46 * c, 260), app.W - 12)
    -- The folder is wrapped rather than clipped: cutting it is cutting the one
    -- thing the card is for. `pw` is only a proposal until the wrap is known,
    -- because the number of lines it takes decides the height.
    local cols = math.floor((pw - 8) / c) - 1
    local folder = text.wrap(result.folder .. "/", cols)
    local rows = #result.written + #result.failed

    local body = lh + 2 + rows * lh + 4 + lh + #folder * lh
    local ph = math.min((lh + 3) + body + lh + 8, app.H - 20)
    local h = math.floor(ph * eased)
    local x, y, w = ui.panel(math.floor((app.W - pw) / 2), math.floor((app.H - h) / 2),
      pw, h, { title = "EXPORTED", slot = "lime", glow = "lime" })
    if h < 40 then return end
    local room = math.floor(w / c)

    text.print(text.clip(string.format("%d message%s, %d file%s", result.count or 0,
      (result.count or 0) == 1 and "" or "s", #result.written,
      #result.written == 1 and "" or "s"), room), x + 2, y, "silver", 0.85)

    local ly = y + lh + 2
    for _, name in ipairs(result.written) do
      text.print(text.clip(name, room), x + 2, ly, "white")
      ly = ly + lh
    end
    for _, why in ipairs(result.failed) do
      text.print(text.clip(why, room), x + 2, ly, "red")
      ly = ly + lh
    end

    ly = ly + 4
    text.print("IN", x + 2, ly, "gray")
    ly = ly + lh
    for _, line in ipairs(folder) do
      text.print(line, x + 2, ly, "cyan", 0.9)
      ly = ly + lh
    end

    text.center(text.clip("ESC closes this", room), x, w, ly + 2, "gray")
  end
end

function S:draw()
  -- Collected fresh every frame: a button that has moved is hit-tested where
  -- it was last drawn, which is where the pointer saw it.
  self.hotspots = {}

  local plate = art.plate(self.plate)
  art.draw(self.plate, self.pan.x, self.pan.y, (plate and plate.night or 0.24) * 0.35)

  -- The hall darkens a little while it is working, so the core is the
  -- brightest thing on the screen exactly when it should be.
  if app.busy then
    palette.set("black", 0.10)
    love.graphics.rectangle("fill", 0, 0, app.W, app.H)
  end

  self:status_bar()
  self:draw_stage()
  self:draw_log()
  self:draw_input()
  self:draw_overlay()
  settings.draw(self.hotspots)
end

return S
