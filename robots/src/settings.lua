-- Settings page. Three tabs:
--
--   AGENTS the roster: one AI agent, one folder, one floor — read-only here,
--          because a robot is made where its folder is. (With no backend it
--          is the old TOWER page: a drone count for the demo swarm.)
--   LOOK   which sprite set the roster wears: anime robots, Tropic Run, Astral War.
--   AI     which brain answers, and the setup behind each — the on-device
--          engine (MLX, or a local ollama daemon holding qwen3.8), its host
--          and tag, and the cloud host, model and key. Every value is kept
--          in the backend's space, so the CLI sees the same setup.
local Theme = require("src.theme")
local Font = require("src.font")
local UI = require("src.ui")
local Layout = require("src.layout")
local Input = require("src.input")
local Audio = require("src.audio")
local FX = require("src.fx")
local World = require("src.world")
local Fleet = require("src.fleet")
local Agents = require("src.agents")
local Chat = require("src.chat")
local Central = require("src.central")
local Commands = require("src.commands")
local Tween = require("src.tween")
local Store = require("src.store")
local Backend = require("src.backend")
local Env = require("src.env")
local Sprites = require("src.sprites")
local Looks = require("src.looks")

local Settings = {
  MIN = 1,
  MAX = 1000,
  agents = 100,
  draft = "100",
  t = 0,
  focus = true,
  -- "tower" | "look" | "ai". Opens on AI: which brain answers is the
  -- setting people come here for; the others are a click away.
  tab = "ai",
  -- The AI tab's own state: the drafts being typed, the field that has the
  -- cursor, and the last answer from the backend.
  ai = {
    field = nil,      -- "od_host" | "od_model" | "cloud_host" | "cloud_model" | "cloud_key"
    draft = {},       -- field -> text
    engine = "auto",
    think = "low",
    clearKey = false, -- APPLY sends cloud.key="" when set
    keyOrigin = nil,  -- the key preloaded from .env, so APPLY can tell an edit from it
    status = "",      -- one line under the buttons
    tone = "dim",
    loading = false,
    dirty = false,
    leave = false,    -- set when APPLY has been kept: the page closes itself
  },
}

local PRESETS = { 1, 10, 25, 50, 100, 250, 500, 1000 }

-- Which draft feeds which settings-table key.
local FIELDS = {
  od_host = "ondevice.host",
  od_model = "ondevice.model",
  cloud_host = "cloud.host",
  cloud_model = "cloud.model",
  cloud_key = "cloud.key",
}
local FIELD_ORDER = { "od_host", "od_model", "cloud_host", "cloud_model", "cloud_key" }
local ENGINES = { "auto", "mlx", "ollama", "off" }
local THINKS = { "low", "medium", "high", "off" }
local TONE_COLOR = { good = Theme.jade, info = Theme.sky, warn = Theme.crimson, dim = Theme.dim }

local function clamp(n)
  n = math.floor(tonumber(n) or Settings.agents or 100)
  if n ~= n then n = 100 end
  return math.max(Settings.MIN, math.min(Settings.MAX, n))
end

function Settings.clamp(n)
  return clamp(n)
end

function Settings.load()
  local raw = Store.read("settings.txt")
  if not raw then
    -- carry over a count saved by an earlier build, then keep to the store
    raw = love.filesystem.read("settings.txt")
    if raw then Store.write("settings.txt", raw) end
  end
  if raw then
    local n = tonumber(raw:match("%d+"))
    if n then Settings.agents = clamp(n) end
  end
  Settings.draft = tostring(Settings.agents)
  World.FLOORS = Settings.agents
  Fleet.COUNT = Settings.agents
end

function Settings.save()
  Store.write("settings.txt", tostring(Settings.agents) .. "\n")
end

-- ------------------------------------------------------------------ AI ----

--- Fill the drafts from a `config` reply. Pure over the reply, so a test can
--- feed it a fixture; `envKey` stands in for `.env` there.
---
--- The backend never echoes a secret, but the client can read `.env` for
--- itself, so a key set there is preloaded into the field — masked — and
--- remembered as the origin: APPLY sends it back only if it was edited, so
--- the `.env` value is not silently copied into the space every time.
function Settings.loadAI(data, envKey)
  local ai = Settings.ai
  ai.draft = {}
  ai.clearKey = false
  ai.dirty = false
  ai.keyOrigin = nil
  if envKey == nil then envKey = Env.get("OLLAMA_API_KEY") end
  if envKey == "" then envKey = nil end
  local setup = data and data.setup or {}
  for field, key in pairs(FIELDS) do
    local entry = setup[key]
    if entry and entry.secret then
      -- The masked value from the backend is the placeholder; the draft is
      -- the .env key when there is one, and empty otherwise.
      ai.draft[field] = envKey or ""
      ai.keyOrigin = envKey
    else
      ai.draft[field] = entry and tostring(entry.value or "") or ""
    end
  end
  local engine = setup["ondevice.engine"]
  ai.engine = engine and tostring(engine.value or "auto") or "auto"
  local think = setup["think"]
  ai.think = think and tostring(think.value or "low") or "low"
end

--- What APPLY would send: every non-secret value, the key only when typed,
--- and a blank key when CLEAR was pressed. Pure, for the tests.
function Settings.aiValues()
  local ai = Settings.ai
  local values = {
    ["ondevice.engine"] = ai.engine,
    ["think"] = ai.think,
  }
  for field, key in pairs(FIELDS) do
    if field == "cloud_key" then
      local draft = ai.draft[field] or ""
      if ai.clearKey then
        values[key] = ""
      elseif draft ~= "" and draft ~= ai.keyOrigin then
        values[key] = draft
      end
    else
      values[key] = ai.draft[field] or ""
    end
  end
  return values
end

--- One headline, one detail line and a colour for who answers the next
--- prompt. Pure over the provider picture, so the tests can pin it.
function Settings.answering(p)
  if not p then return "ASKING AGENTD...", "NO ANSWER FROM THE BACKEND YET", Theme.amber end
  if p.effective == "ondevice" then
    local od = p.ondevice or {}
    local via = od.engine == "ollama" and ("OLLAMA DAEMON  " .. tostring(od.host or ""):upper())
      or "MLX ENGINE, THIS MAC"
    return "ON-DEVICE", tostring(od.model or "?"):upper() .. "  " .. via .. "  NOTHING LEAVES THIS MAC", Theme.jade
  end
  if p.effective == "cloud" then
    local c = p.cloud or {}
    return "CLOUD", tostring(c.model or "?"):upper() .. "  " .. tostring(c.host or ""):upper()
      .. "  PROMPTS LEAVE THIS MAC", Theme.sky
  end
  return "NOBODY", tostring(p.why or "OFFLINE"):upper(), Theme.crimson
end

local function refreshAI()
  local ai = Settings.ai
  if not Backend.ready then
    ai.status = "ARCHIVE OFFLINE  " .. tostring(Backend.reason or ""):upper()
    ai.tone = "warn"
    return
  end
  ai.loading = true
  ai.status = "ASKING THE BACKEND..."
  ai.tone = "info"
  Backend.askConfig(function(data, err)
    ai.loading = false
    if err then
      ai.status = "SETUP  " .. tostring(err):upper():sub(1, 50)
      ai.tone = "warn"
      return
    end
    Settings.loadAI(data)
    ai.status = "SETUP LOADED"
    ai.tone = "good"
  end)
end

--- Write `values` into the space. On success the drafts are refreshed from
--- the reply and, when `andLeave` is set, the page closes itself on the
--- next frame — APPLY is one click, not APPLY then BACK.
local function write(values, andLeave)
  local ai = Settings.ai
  if not Backend.ready then
    ai.status = "ARCHIVE OFFLINE  " .. tostring(Backend.reason or ""):upper()
    ai.tone = "warn"
    return
  end
  ai.loading = true
  ai.status = "WRITING..."
  ai.tone = "info"
  Backend.setConfig(values, function(data, err)
    ai.loading = false
    if err then
      ai.status = "REFUSED  " .. tostring(err):upper():sub(1, 50)
      ai.tone = "warn"
      Audio.play("blip", 0.7, 0.6)
      return
    end
    Settings.loadAI(data)
    ai.status = "SETUP KEPT.  " .. Backend.providerLabel()
    ai.tone = Backend.providerTone()
    FX.toast(Backend.providerLabel(), TONE_COLOR[Backend.providerTone()] or Theme.dim)
    Audio.play("sting", 0.92, 0.75)
    if andLeave then ai.leave = true end
  end)
end

--- APPLY: every field, then back to the dashboard.
function Settings.applyAI()
  write(Settings.aiValues(), true)
end

--- A radio choice is kept the moment it is clicked — one value, nothing
--- else — so the engine or the think level never needs APPLY.
local function applyOne(key, value)
  write({ [key] = value }, false)
end

local function setProvider(name)
  Backend.setProvider(name, function(data, err)
    if err then
      Settings.ai.status = "AI  " .. tostring(err):upper():sub(1, 50)
      Settings.ai.tone = "warn"
      return
    end
    Settings.ai.status = Backend.providerLabel()
    Settings.ai.tone = Backend.providerTone()
    Audio.play("toggle")
  end)
end

local function nextField(dir)
  local ai = Settings.ai
  local at = 0
  for i, f in ipairs(FIELD_ORDER) do
    if f == ai.field then at = i end
  end
  at = ((at - 1 + dir) % #FIELD_ORDER) + 1
  ai.field = FIELD_ORDER[at]
end

local function pasteWanted()
  local mod = love.keyboard.isDown("lgui") or love.keyboard.isDown("rgui")
    or love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")
  return mod and Input.wasKey("v")
end

-- Typing, backspace, paste and tab, into whichever field has the cursor.
local function updateAI()
  local ai = Settings.ai
  if ai.field then
    local d = ai.draft[ai.field] or ""
    if Input.text ~= "" then
      local add = Input.text:gsub("[%c]", "")
      d = d .. add
      ai.dirty = true
      if ai.field == "cloud_key" then ai.clearKey = false end
    end
    if Input.backspace then
      d = d:sub(1, -2)
      ai.dirty = true
    end
    if pasteWanted() and love.system and love.system.getClipboardText then
      local clip = love.system.getClipboardText() or ""
      d = d .. clip:gsub("[%c]", "")
      ai.dirty = true
      if ai.field == "cloud_key" then ai.clearKey = false end
    end
    ai.draft[ai.field] = d
  end
  if Input.wasKey("tab") then
    local back = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
    nextField(back and -1 or 1)
    Audio.play("click")
  end
  if ai.leave then
    ai.leave = false
    return "apply"
  end
  if Input.wasKey("escape") then return "back" end
  if Input.wasKey("return") then
    Settings.applyAI()
  end
  return nil
end

-- ------------------------------------------------------------- lifecycle --

function Settings.enter(tab)
  Settings.t = 0
  Settings.focus = (tab or Settings.tab or "ai") == "tower"
  Settings.draft = tostring(Settings.agents)
  Settings.tab = tab or Settings.tab or "ai"
  Settings.ai.field = nil
  if Settings.tab == "ai" then refreshAI() end
  Audio.play("blip")
end

local function switchTab(tab)
  if Settings.tab == tab then return end
  Settings.tab = tab
  Settings.ai.field = nil
  Settings.focus = tab == "tower"
  if tab == "ai" then refreshAI() end
  Audio.play("click")
end

function Settings.commit()
  local n = clamp(tonumber(Settings.draft) or Settings.agents)
  Settings.agents = n
  Settings.draft = tostring(n)
  Settings.save()
  World.FLOORS = n
  Fleet.COUNT = n
  World.build()
  Fleet.resize(n)
  FX.wave(World.hangarX, World.cam.y, Theme.gold, 70)
  Audio.play("sting", 0.92, 0.75)
  FX.toast(string.format("%d AGENTS  //  %d FLOORS", n, n), Theme.gold)
  Chat.reply(string.format("TOWER REBUILT. %d FLOORS. %d AGENTS. THEY FLY TO STATION.", n, n), Agents.voice())
  return n
end

local function setDraft(n)
  Settings.draft = tostring(clamp(n))
  Audio.play("click")
end

local function nudge(d)
  local n = tonumber(Settings.draft) or Settings.agents
  setDraft(n + d)
end

-- returns "apply" | "back" | "regen" | nil
function Settings.update(dt)
  Settings.t = Settings.t + dt

  if Settings.tab == "ai" then
    return updateAI()
  end
  if Settings.tab == "look" then
    if Input.wasKey("escape") then return "back" end
    if Input.wasKey("left") then
      Looks.cycle(-1)
      Audio.play("toggle")
      FX.toast("LOOK  " .. Looks.label(), Theme.gold)
    end
    if Input.wasKey("right") then
      Looks.cycle(1)
      Audio.play("toggle")
      FX.toast("LOOK  " .. Looks.label(), Theme.gold)
    end
    if Input.wasKey("return") then return "back" end
    return nil
  end

  if Settings.focus then
    if Input.text ~= "" then
      local add = Input.text:gsub("%D", "")
      local next = (Settings.draft .. add):gsub("^0+", "")
      if next == "" then next = "0" end
      if #next <= 4 then Settings.draft = next end
    end
    if Input.backspace then
      Settings.draft = Settings.draft:sub(1, -2)
      if Settings.draft == "" then Settings.draft = "0" end
    end
  end

  if Input.wasKey("escape") then
    return "back"
  end
  if Agents.roster then
    -- Nothing to apply: the roster is the backend's to change.
    if Input.wasKey("return") then return "back" end
    return nil
  end
  if Input.wasKey("return") then
    Settings.commit()
    return "apply"
  end
  if Input.wasKey("left") then nudge(-1) end
  if Input.wasKey("right") then nudge(1) end
  if Input.wasKey("up") then nudge(10) end
  if Input.wasKey("down") then nudge(-10) end

  return nil
end

-- --------------------------------------------------------------- drawing --

local function drawChrome(w, h, subtitle, footer)
  love.graphics.setColor(Theme.void)
  love.graphics.rectangle("fill", 0, 0, w, h)

  love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.95))
  love.graphics.rectangle("fill", 0, 0, w, 20)
  love.graphics.setColor(Theme.gold)
  love.graphics.rectangle("fill", 0, 19, w, 1)
  Font.print("SETTINGS", 6, 6, Theme.gold, 1)

  -- the tabs
  local tx = 90
  if UI.button("tabtower", tx, 3, 52, 14, Agents.roster and "AGENT" or "TOWER", { stroke = Theme.teal, on = Settings.tab == "tower" }) then
    switchTab("tower")
  end
  if UI.button("tablook", tx + 56, 3, 40, 14, "LOOK", { stroke = Theme.teal, on = Settings.tab == "look" }) then
    switchTab("look")
  end
  if UI.button("tabai", tx + 100, 3, 36, 14, "AI", { stroke = Theme.teal, on = Settings.tab == "ai" }) then
    switchTab("ai")
  end
  if not Layout.isPortrait() then Font.print(subtitle, tx + 144, 6, Theme.dim, 1) end

  love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.95))
  love.graphics.rectangle("fill", 0, h - 14, w, 14)
  love.graphics.setColor(Theme.magenta)
  love.graphics.rectangle("fill", 0, h - 14, w, 1)
  Font.print(footer, 6, h - 11, Theme.dim, 1)

  if UI.button("sback", w - 52, 3, 46, 14, "BACK", { stroke = Theme.cyan }) then
    return "back"
  end
  return nil
end

--- One text field. Click focuses it; the tail of a long value is shown.
local function field(id, x, y, w, value, placeholder, focused, secret)
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", x, y, w, 14)
  love.graphics.setColor(focused and Theme.gold or Theme.teal)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, 13)
  local room = math.floor((w - 10) / 8)
  local shown, color = value, Theme.paper
  if secret and shown ~= "" then
    -- Masked the way the backend masks: enough of the tail to recognise it.
    shown = #shown > 12 and (string.rep("*", 8) .. shown:sub(-4)) or string.rep("*", #shown)
  end
  if shown == "" and placeholder and placeholder ~= "" then
    shown, color = placeholder, Theme.dim
  end
  if focused and math.floor(Settings.t * 2) % 2 == 0 then shown = shown .. "_" end
  Font.print(shown:sub(-room), x + 5, y + 3, color, 1)
  if Layout.hit(x, y, w, 14) and Input.pressed then
    Settings.ai.field = id
    Audio.play("click")
  end
end

--- A row of exclusive choices, drawn as radio buttons: a box before each
--- label, and the chosen one filled, ticked and lit — a stroke colour alone
--- is not a selection anyone can read at a glance. Returns the one clicked,
--- or nil, and the x after the row.
local function choices(prefix, x, y, options, current, stroke)
  stroke = stroke or Theme.teal
  local picked
  for _, opt in ipairs(options) do
    local lab = opt:upper()
    local on = current == opt
    local ww = #lab * 8 + 24
    if UI.button(prefix .. opt, x, y, ww, 13, "   " .. lab, {
      stroke = stroke, on = on, onColor = stroke,
      fill = on and Theme.withAlpha(stroke, 0.28) or nil,
      labelColor = on and Theme.paper or Theme.dim,
    }) then
      picked = opt
    end
    -- the box, and the tick when chosen
    local bx, by = x + 5, y + 3
    love.graphics.setColor(on and stroke or Theme.dim)
    love.graphics.rectangle("line", bx + 0.5, by + 0.5, 7, 7)
    if on then
      love.graphics.setColor(stroke)
      love.graphics.setLineWidth(2)
      love.graphics.line(bx + 1.5, by + 4, bx + 3.5, by + 6.5, bx + 7.5, by + 1)
      love.graphics.setLineWidth(1)
    end
    x = x + ww + 4
  end
  return picked, x
end

local function srcTag(setup, key)
  local entry = setup and setup[key] or nil
  local src = entry and entry.source or nil
  -- A value this client handed the backend when it opened it. Named
  -- rather than falling through to DEFAULT, which would be a lie about
  -- the one source the operator cannot change from this screen.
  if src == "caller" then return "FROM CLIENT", Theme.violet end
  if src == "env" then return "FROM ENV", Theme.amber end
  if src == "space" then return "KEPT", Theme.jade end
  if src == "dotenv" then return "FROM .ENV", Theme.cyan end
  return "DEFAULT", Theme.dim
end

--- One labelled field: the label and where the value came from on one
--- line, the field itself under them. Returns the next row's y.
local function labelled(id, x, y, w, label, key, setup, placeholder, secret, extraW)
  local tag, tc = srcTag(setup, key)
  if secret then
    local entry = setup and setup[key] or nil
    if not (entry and entry.set) then tag, tc = "NOT SET", Theme.amber end
    if Settings.ai.clearKey then tag, tc = "CLEARING", Theme.crimson end
  end
  Font.print(label, x, y, Theme.cyan, 1)
  Font.print(tag, x + w - #tag * 8, y, tc, 1)
  field(id, x, y + 10, w - (extraW or 0), Settings.ai.draft[id] or "", placeholder,
    Settings.ai.field == id, secret)
  return y + 26
end

local function verdict(x, y, w, ok, headline, detail, why)
  local room = math.floor(w / 8)
  if ok then
    Font.print(headline:sub(1, room), x, y, Theme.jade, 1)
    Font.print(detail:sub(1, room), x, y + 10, Theme.dim, 1)
  else
    why = tostring(why or "unavailable"):upper()
    Font.print(why:sub(1, room), x, y, Theme.crimson, 1)
    Font.print(why:sub(room + 1, room * 2), x, y + 10, Theme.crimson, 1)
    Font.print(why:sub(room * 2 + 1, room * 3), x, y + 20, Theme.crimson, 1)
  end
end

--- The width a `choices` row takes, so a caller can tell whether it fits
--- beside its label or has to go under it.
local function choicesWidth(options)
  local w = 0
  for _, opt in ipairs(options) do w = w + #opt * 8 + 24 + 4 end
  return w - 4
end

--- The on-device or cloud column: a title, the engine or key row, the two
--- fields, and the brain's own verdict on the result. Returns its height.
local function drawColumn(x, y, w, which, setup, p)
  local ai = Settings.ai
  local yy = y

  local answering = p and p.effective == which
  if which == "ondevice" then
    -- The engine row goes beside its label when the column is wide enough
    -- and under it when it is not; the panel grows to match.
    local wrap = 56 + choicesWidth(ENGINES) > w
    local height = wrap and 134 or 122
    UI.panel(x - 6, y - 14, w + 12, height, answering and "ON-DEVICE AI  << ANSWERING" or "ON-DEVICE AI",
      answering and Theme.jade or Theme.teal)
    Font.print("ENGINE", x, yy + 3, Theme.cyan, 1)
    if wrap then yy = yy + 12 end
    local picked = choices("eng", wrap and x or (x + 56), yy, ENGINES, ai.engine, Theme.jade)
    if picked then ai.engine = picked; Audio.play("click"); applyOne("ondevice.engine", picked) end
    yy = yy + 18
    yy = labelled("od_host", x, yy, w, "HOST", "ondevice.host", setup, "http://localhost:11434")
    yy = labelled("od_model", x, yy, w, "MODEL", "ondevice.model", setup, "qwen3.8:27b-mlx")
    local od = p and p.ondevice or nil
    if od then
      local host = od.engine == "ollama" and tostring(od.host or ""):upper() or "MLX ENGINE, THIS MAC"
      verdict(x, yy + 2, w, od.ready, "READY  " .. Backend.ondeviceLabel(p), host, od.why)
    else
      Font.print("NOT ASKED YET", x, yy + 2, Theme.dim, 1)
    end
    return height
  else
    UI.panel(x - 6, y - 14, w + 12, 122, answering and "OLLAMA AI  (CLOUD)  << ANSWERING" or "OLLAMA AI  (CLOUD)",
      answering and Theme.magenta or Theme.violet)
    yy = labelled("cloud_host", x, yy, w, "HOST", "cloud.host", setup, "https://ollama.com")
    yy = labelled("cloud_model", x, yy, w, "MODEL", "cloud.model", setup, "gpt-oss:20b")
    local keyEntry = setup and setup["cloud.key"] or nil
    local placeholder = (keyEntry and keyEntry.set and not ai.clearKey)
      and tostring(keyEntry.value) or "PASTE  CMD+V  OR SET IT IN .ENV"
    local clearW = 44
    local keyY = yy
    yy = labelled("cloud_key", x, yy, w, "KEY", "cloud.key", setup, placeholder, true, clearW + 4)
    if UI.button("keyclear", x + w - clearW, keyY + 10, clearW, 14, "CLEAR", { stroke = Theme.crimson }) then
      ai.clearKey = not ai.clearKey
      ai.draft.cloud_key = ""
      ai.dirty = true
    end
    local c = p and p.cloud or nil
    if c then
      verdict(x, yy + 2, w, c.ready, "READY  " .. tostring(c.model or ""):upper(),
        tostring(c.provenance or ""):upper() .. "  PROMPTS LEAVE THIS MAC", c.why)
    else
      Font.print("NOT ASKED YET", x, yy + 2, Theme.dim, 1)
    end
    return 122
  end
end

local function drawAI(w, h)
  local port = Layout.isPortrait()
  local act = drawChrome(w, h, "WHICH BRAIN ANSWERS",
    "ENTER APPLY & BACK   TAB NEXT FIELD   ESC BACK   CHOICES ARE KEPT ON CLICK")
  if act then return act end

  local ai = Settings.ai
  local px = port and 8 or 20
  local pw = w - px * 2
  local py = 30
  local p = Backend.provider
  local setup = Backend.config and Backend.config.setup or nil

  -- The choice: the wish on the buttons, the outcome spelled out under
  -- them, because "auto" says nothing about where the next prompt goes.
  Font.print("BRAIN", px, py + 3, Theme.gold, 1)
  local current = p and p.current or "auto"
  local picked, endx = choices("prov", px + 56, py, { "auto", "ondevice", "cloud" }, current, Theme.gold)
  if picked then setProvider(picked) end
  local ty = py
  if port then ty = py + 18; endx = px - 8 end
  Font.print("THINK", endx + 8, ty + 3, Theme.gold, 1)
  local tk = choices("think", endx + 56, ty, THINKS, ai.think, Theme.gold)
  if tk then ai.think = tk; Audio.play("click"); applyOne("think", tk) end

  local sy = ty + 20
  local room = math.floor(pw / 8)
  local headline, detail, color = Settings.answering(p)
  Font.print("ANSWERING  " .. headline, px, sy, color, 1)
  local first, rest = detail, nil
  if #detail > room then
    -- A narrow screen gets the rest on a second line, broken at a space.
    local cut = detail:sub(1, room):match("^.*()%s") or (room + 1)
    first, rest = detail:sub(1, cut - 1), detail:sub(cut):gsub("^%s+", "")
  end
  Font.print(first, px, sy + 10, color, 1)
  local dy = sy + 20
  if rest and rest ~= "" then
    Font.print(rest:sub(1, room), px, dy, color, 1)
    dy = dy + 10
  end
  local wish = tostring(current):upper()
  if wish == "ONDEVICE" then wish = "ON-DEVICE" end
  Font.print(("CHOICE  " .. wish .. (p and ("  ->  " .. headline) or "")):sub(1, room), px, dy, Theme.dim, 1)

  -- the two columns
  local cy = dy + 26
  if port then
    local cw = pw - 12
    local h1 = drawColumn(px + 6, cy, cw, "ondevice", setup, p)
    local h2 = drawColumn(px + 6, cy + h1 + 12, cw, "cloud", setup, p)
    cy = cy + h1 + 12 + h2 + 12
  else
    local cw = math.floor((pw - 24) / 2)
    local h1 = drawColumn(px + 6, cy, cw - 12, "ondevice", setup, p)
    local h2 = drawColumn(px + 6 + cw + 12, cy, cw - 12, "cloud", setup, p)
    cy = cy + math.max(h1, h2)
  end

  -- the buttons, and the last word from the backend
  local by = cy + 4
  if UI.button("aiapply", px, by, 112, 16, ai.dirty and "APPLY & BACK *" or "APPLY & BACK", { stroke = Theme.gold }) then
    Settings.applyAI()
  end
  if UI.button("aitest", px + 120, by, 96, 16, "RE-CHECK", { stroke = Theme.jade }) then
    refreshAI()
  end
  if UI.button("aicancel", px + 224, by, 96, 16, "CANCEL", { stroke = Theme.dim }) then
    return "back"
  end
  local status = tostring(ai.status or "")
  if ai.loading and math.floor(Settings.t * 3) % 2 == 0 then status = status .. " ." end
  Font.print(status:upper():sub(1, math.floor(pw / 8)), px, by + 22, TONE_COLOR[ai.tone] or Theme.dim, 1)
  Font.print("AGENTD CONFIG  SHOWS THE SAME SETUP FROM A TERMINAL", px, by + 34, Theme.dim, 1)
  return nil
end

-- The agents, as the tower holds them. With the backend up this is the
-- roster — one robot, one folder — read-only here because a robot is made
-- and unmade where its folder is (`agentd agents.create`, `agents.delete`),
-- not by a number on a slider. Without a backend the old drone count is
-- still editable, because a demo swarm is all there is to set.
local function drawRoster(px, py, pw, ph)
  local Robots = require("src.robots")
  local root = Backend.health and tostring(Backend.health.root or "") or ""
  Font.print("ONE AI AGENT  =  ONE FOLDER  =  ONE FLOOR", px + 12, py + 16, Theme.cyan, 1)
  local room = math.floor((pw - 24) / 8)
  Font.print(("IN " .. root):sub(1, room), px + 12, py + 28, Theme.dim, 1)

  local rowH = 22
  local y = py + 44
  local rows = math.max(1, math.floor((ph - 44 - 40) / rowH))
  local list = Agents.list
  local first = 1
  local sel = 0
  for i, a in ipairs(list) do
    if a.id == Robots.selected then sel = i end
  end
  if #list > rows and sel > rows then first = sel - rows + 1 end
  for i = first, math.min(#list, first + rows - 1) do
    local a = list[i]
    local on = a.id == Robots.selected
    if UI.button("ros" .. i, px + 8, y, pw - 16, rowH - 3, "", { stroke = on and a.color or Theme.dim, hot = a.color, on = on, onColor = a.color }) then
      Robots.select(on and nil or a.id)
      Audio.play("click")
    end
    if Sprites.head(a.key) then Sprites.drawHead(a.key, px + 12, y + 2, rowH - 7, 1) end
    Font.print(string.format("F%03d", i), px + 12 + rowH - 2, y + 3, Theme.dim, 1)
    Font.print(a.name, px + 12 + rowH + 40, y + 3, a.color, 1)
    Font.print(tostring(a.role or ""):sub(1, math.max(4, room - 22)), px + 12 + rowH + 40, y + 12, Theme.paper, 1)
    local folder = tostring(a.folder or "")
    local fw = math.min(#folder, math.max(8, math.floor((pw - 24) / 8) - 26))
    Font.print(folder:sub(1, fw), px + pw - 12 - fw * 8, y + 3, Theme.dim, 1)
    y = y + rowH
  end
  if #list > rows then
    Font.print(string.format("%d-%d OF %d", first, math.min(#list, first + rows - 1), #list), px + 12, y + 2, Theme.dim, 1)
  end
  Font.print("ADD ONE:  AGENTD AGENTS.CREATE <SLUG>", px + 12, py + ph - 28, Theme.magenta, 1)
  Font.print("CLICK ONE TO CHOOSE IT   ESC BACK", px + 12, py + ph - 16, Theme.dim, 1)
end

local function drawTower(w, h)
  local port = Layout.isPortrait()
  local act = drawChrome(w, h, Agents.roster and "AI AGENTS" or "TOWER / FLEET",
    Agents.roster and "ONE AGENT PER FOLDER, ONE FOLDER PER FLOOR" or "AGENT COUNT SETS FLOOR COUNT")
  if act then return act end

  local pw = port and (w - 16) or 420
  local ph = port and 460 or 340
  local px = math.floor((w - pw) / 2)
  local py = port and 36 or 40

  UI.panel(px, py, pw, ph, "AI AGENTS", Theme.gold)

  if Agents.roster then
    drawRoster(px, py, pw, ph)
    return nil
  end

  Font.print("ONE ROBOT  =  ONE FLOOR  =  ONE FLAT", px + 12, py + 16, Theme.cyan, 1)
  Font.print("MIN 1     MAX 1000     (NO BACKEND: DEMO SWARM)", px + 12, py + 28, Theme.dim, 1)

  local n = clamp(tonumber(Settings.draft) or 0)
  local live = clamp(Settings.agents)
  Font.print("NOW  " .. tostring(live) .. " LIVE", px + 12, py + 44, live == n and Theme.jade or Theme.amber, 1)

  -- stepper
  local sy = py + 64
  local sx = px + 12
  if UI.button("sm100", sx, sy, 44, 16, "-100", { stroke = Theme.magenta }) then nudge(-100) end
  if UI.button("sm10", sx + 48, sy, 36, 16, "-10", { stroke = Theme.magenta }) then nudge(-10) end
  if UI.button("sm1", sx + 88, sy, 28, 16, "-1", { stroke = Theme.magenta }) then nudge(-1) end

  local boxx = sx + 122
  local boxw = port and 88 or 110
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", boxx, sy, boxw, 16)
  love.graphics.setColor(Settings.focus and Theme.gold or Theme.teal)
  love.graphics.rectangle("line", boxx + 0.5, sy + 0.5, boxw - 1, 15)
  local shown = Settings.draft
  if Settings.focus and math.floor(Settings.t * 2) % 2 == 0 then shown = shown .. "_" end
  Font.print(shown:sub(-12), boxx + 6, sy + 4, Theme.gold, 1)
  if Layout.hit(boxx, sy, boxw, 16) and Input.pressed then
    Settings.focus = true
  end

  if UI.button("sp1", boxx + boxw + 6, sy, 28, 16, "+1", { stroke = Theme.jade }) then nudge(1) end
  if UI.button("sp10", boxx + boxw + 38, sy, 36, 16, "+10", { stroke = Theme.jade }) then nudge(10) end
  if UI.button("sp100", boxx + boxw + 78, sy, 44, 16, "+100", { stroke = Theme.jade }) then nudge(100) end

  -- slider
  local barx, bary, barw, barh = px + 12, sy + 28, pw - 24, 10
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", barx, bary, barw, barh)
  love.graphics.setColor(Theme.dim)
  love.graphics.rectangle("line", barx + 0.5, bary + 0.5, barw - 1, barh - 1)
  local t = (n - Settings.MIN) / (Settings.MAX - Settings.MIN)
  local fill = math.max(1, math.floor(barw * t))
  love.graphics.setColor(Theme.gold)
  love.graphics.rectangle("fill", barx, bary, fill, barh)
  love.graphics.setColor(Theme.cyan)
  love.graphics.rectangle("fill", barx + fill - 2, bary - 2, 4, barh + 4)
  if Layout.hit(barx - 2, bary - 4, barw + 4, barh + 8) and Input.down then
    local mx = Layout.mouse()
    if mx then
      local k = (mx - barx) / barw
      Settings.draft = tostring(clamp(math.floor(Settings.MIN + k * (Settings.MAX - Settings.MIN) + 0.5)))
    end
  end

  Font.print("FLOORS  " .. tostring(n), px + 12, bary + 18, Theme.paper, 1)
  Font.print("EACH FLAT HOLDS ONE AGENT", px + 12, bary + 30, Theme.dim, 1)

  Font.print("PRESETS", px + 12, bary + 48, Theme.magenta, 1)
  local cx, cy = px + 12, bary + 62
  for _, p in ipairs(PRESETS) do
    local lab = tostring(p)
    local ww = math.max(36, #lab * 8 + 10)
    if cx + ww > px + pw - 12 then
      cx = px + 12
      cy = cy + 16
    end
    if UI.button("pr" .. p, cx, cy, ww, 14, lab, { stroke = Theme.teal, on = n == p }) then
      setDraft(p)
    end
    cx = cx + ww + 4
  end

  local ry = cy + 20
  Font.print("LOADED TYPES  " .. tostring(#(Agents.loaded or {})), px + 12, ry, Theme.gold, 1)
  local names = Agents.poolNames()
  local room = math.floor((pw - 24) / 8)
  Font.print(names:sub(1, room), px + 12, ry + 12, Theme.cyan, 1)
  if #names > room then
    Font.print(names:sub(room + 1, room * 2), px + 12, ry + 24, Theme.cyan, 1)
  end
  Font.print("A BACKEND REPLACES THESE WITH THE ROSTER", px + 12, ry + 40, Theme.dim, 1)

  local by = py + ph - 36
  if UI.button("sapply", px + 12, by, 120, 18, "APPLY", { stroke = Theme.gold }) then
    Settings.commit()
    return "apply"
  end
  if UI.button("scancel", px + 140, by, 120, 18, "CANCEL", { stroke = Theme.dim }) then
    return "back"
  end
  Font.print("ENTER APPLY   ESC BACK", px + 12, by + 22, Theme.dim, 1)

  return nil
end

local function pickLook(id)
  if not Looks.apply(id) then return end
  Audio.play("sting", 0.92, 0.75)
  FX.toast("LOOK  " .. Looks.label(), Theme.gold)
end

local function drawLookCard(look, x, y, w, h)
  local on = Looks.current == look.id
  UI.panel(x, y, w, h, look.name, on and Theme.gold or Theme.teal)
  Font.print(look.console, x + 8, y + 16, Theme.magenta, 1)
  local room = math.floor((w - 16) / 8)
  Font.print(look.blurb:sub(1, room), x + 8, y + 28, Theme.paper, 1)
  Font.print(tostring(look.sprites) .. " SPRITES", x + 8, y + 40, Theme.cyan, 1)

  local hx, hy = x + 8, y + 54
  local size = 22
  for i, face in ipairs(Looks.ROSTER) do
    local pk = Sprites.ensurePreview(look.id, face.id)
    if pk then
      Sprites.drawHead(pk, hx, hy, size, 1)
    else
      love.graphics.setColor(Theme.navy)
      love.graphics.rectangle("fill", hx, hy, size, size)
      love.graphics.setColor(Theme.dim)
      love.graphics.rectangle("line", hx + 0.5, hy + 0.5, size - 1, size - 1)
    end
    hx = hx + size + 3
    if hx + size > x + w - 8 then
      hx = x + 8
      hy = hy + size + 3
    end
    if i == 12 then break end
  end

  local by = y + h - 24
  local lab = on and "ON" or "WEAR"
  if UI.button("look" .. look.id, x + 8, by, w - 16, 16, lab, {
    stroke = on and Theme.gold or Theme.jade, on = on,
  }) then
    pickLook(look.id)
  end
end

local function drawLook(w, h)
  local port = Layout.isPortrait()
  local act = drawChrome(w, h, "WHICH SPRITES THE ROSTER WEARS",
    "LEFT/RIGHT CYCLE   ENTER BACK   ESC BACK")
  if act then return act end

  local n = #Looks.CATALOG
  local gap = 8
  local px = port and 8 or 12
  local py = 28
  local pw = w - px * 2
  local ph = h - py - 20
  if port then
    local ch = math.floor((ph - gap * (n - 1)) / n)
    for i, look in ipairs(Looks.CATALOG) do
      drawLookCard(look, px, py + (i - 1) * (ch + gap), pw, ch)
    end
  else
    local cw = math.floor((pw - gap * (n - 1)) / n)
    for i, look in ipairs(Looks.CATALOG) do
      drawLookCard(look, px + (i - 1) * (cw + gap), py, cw, ph)
    end
  end
  return nil
end

function Settings.draw()
  local w, h = Layout.vw, Layout.vh
  if Settings.tab == "ai" then
    return drawAI(w, h)
  end
  if Settings.tab == "look" then
    return drawLook(w, h)
  end
  return drawTower(w, h)
end

-- Reached by tests/, so the drafts and the payload can be checked without a
-- window.
Settings._test = {
  FIELDS = FIELDS,
  ENGINES = ENGINES,
  THINKS = THINKS,
}

return Settings
