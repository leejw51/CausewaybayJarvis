local Theme = require("src.theme")
local Font = require("src.font")
local UI = require("src.ui")
local Layout = require("src.layout")
local Audio = require("src.audio")
local Sprites = require("src.sprites")
local Agents = require("src.agents")
local Chat = require("src.chat")
local Input = require("src.input")
local FX = require("src.fx")
local World = require("src.world")
local Fleet = require("src.fleet")
local Commands = require("src.commands")
local Central = require("src.central")
local Ease = require("src.ease")
local Tween = require("src.tween")
local Settings = require("src.settings")
local Ollama = require("src.ollama")
local Comms = require("src.comms")
local Autopilot = require("src.autopilot")
local Robots = require("src.robots")
local Backend = require("src.backend")

local Dash = {
  t = 0,
  view = { x = 0, y = 0, w = 640, h = 280 },
  chrome = nil, -- packed dock: cmd / comms / input, filled by layoutMap
  drag = false,
  dragged = false,
  lmx = 0, lmy = 0,
  clickT = -1,
  lock = { s = 20, ts = 8 },
  inspect = 0,
  banner = 1,
  mark = nil,
  search = "",
  searchFocus = false,
  searchClickT = -1,
  screen = "map",
  -- Set to "page" or "face" when the operator clicks one of the robot
  -- buttons; main.lua takes it and switches screen. The dashboard does not
  -- own the state machine, so it asks rather than jumps.
  request = nil,
}

local HEADER = 20
local SEARCH = 16   -- portrait find-row under the header
local FOOTER = 14
local INPUT_H = 16
local LAND_DOCK = 62 -- command strip + input, landscape
local COMMS_ROWS_PORT = 4
local CHIP_ROW = 14

local function chipRows(maxW)
  local cx, rows = 0, 1
  for _, c in ipairs(Commands.list) do
    local ww = #c.label * 8 + 10
    if cx > 0 and cx + ww > maxW then
      rows = rows + 1
      cx = 0
    end
    cx = cx + ww + 3
  end
  return rows
end

local function agentColor(key)
  local a = Agents.byId(key)
  if a then return a.color end
  local map = {
    amber = Theme.amber, cyan = Theme.cyan, magenta = Theme.magenta, teal = Theme.teal,
  }
  return map[key] or Theme.cyan
end

function Dash.enter()
  Comms.reset()
  Autopilot.reset()
  Dash.t = 0
  Dash.banner = 1
  Dash.inspect = 0
  Dash.mark = nil
  Dash.drag = false
  Audio.setHum(false)
  if not World.ready then World.build() end
  Fleet.spawn()
  Commands.reset()
  Central.reset()
  for _, u in ipairs(Fleet.units) do
    Central.assign(u.id, u.squad)
  end
  World.cam.x = World.hangarX
  World.cam.y = World.SKY - 8
  World.cam.zoom = 0.85
  Tween.kill(World.cam)
  Tween.to(World.cam, { zoom = 1.08 }, 0.22, "inOutSine")
  FX.wave(World.hangarX, World.hangarY, Theme.gold, 80)
  FX.kick(5)
  Audio.play("sting", 0.92, 0.75)
  Dash.search = ""
  Dash.searchFocus = false
  Dash.screen = "map"
  FX.toast(Agents.roster
    and string.format("%d AI AGENTS  //  ONE FOLDER EACH", Fleet.COUNT)
    or string.format("%d AGENTS  //  TOWER", Fleet.COUNT), Theme.gold)
end

-- The roster arrived, or changed: the tower is rebuilt to hold exactly it.
-- One robot, one floor, one folder. Called from main.lua's roster watcher,
-- so the tests — which never load a roster — keep the swarm they had.
function Dash.roster(list)
  local n = #(list or {})
  if n == 0 then return false end
  Fleet.COUNT = n
  Settings.agents = n
  World.build(n)
  Central.reset()
  if #Fleet.units > 0 then
    Fleet.spawn()
    for _, u in ipairs(Fleet.units) do
      Central.assign(u.id, u.squad)
    end
  end
  return true
end

-- Back to no selection at all: no locked unit, no wing, no camera chase,
-- and the command scope opens back up to the whole swarm.
function Dash.deselect()
  local had = Fleet.selected or Agents.selected or Fleet.filter ~= 0 or Robots.selected
  Fleet.unlock()
  Fleet.setFilter(0)
  World.chase = nil
  Dash.mark = nil
  Dash.inspect = 0
  Audio.play("toggle")
  if had then FX.toast("DESELECT  //  NO AGENT", Theme.dim) end
end

function Dash.nothingSelected()
  return Fleet.selected == nil and Agents.selected == nil and Fleet.filter == 0
    and Robots.selected == nil
end

function Dash.selectUnit(u)
  if not u then return end
  Fleet.lock(u)
  Dash.lock.s = 26
  Dash.lock.ts = 8
  Audio.play("click")
  local rec = Central.record(u)
  u.ctx = Central.query(u, "memory")
  local look = Agents.lookOf(u)
  if u.robot and look then
    Chat.reply(string.format("%s LOCKED. %s. FOLDER %s.", look.name, look.role,
      tostring(look.folder or ""):upper()), look)
  else
    Chat.reply(string.format("%s LOCKED. %s  %s. CONTEXT ONLY — CENTRAL HAS THE FILE.", rec.id, look.name, rec.task), look)
  end
  FX.burstWorld(u.x, u.y, Agents.colorOf(u), 8)
end

function Dash.selectSquad(i)
  local h = Fleet.hero(i)
  if h then Dash.selectUnit(h) end
end

function Dash.toggleCompact()
  Layout.toggleCompact()
  Dash.searchFocus = false
  Audio.play("whoosh")
  FX.toast(Layout.compact and "COMPACT  //  MAP" or "HUD  //  FULL", Theme.gold)
end

-- One stack for both orientations: map eats leftover pixels, chrome packs
-- against the bottom (and left, in landscape). Portrait used to pin the map
-- at 236px and park comms at h-100, which left a black void between them.
local function layoutMap()
  local w, h = Layout.vw, Layout.vh
  if Layout.compact then
    Dash.view.x, Dash.view.y = 0, 0
    Dash.view.w, Dash.view.h = w, h
    Dash.chrome = nil
    World.mapViewH = h
    return
  end
  if Layout.isPortrait() then
    local rows = chipRows(w - 12)
    local cmdH = 14 + rows * CHIP_ROW + 4
    local commsH = Comms.height(COMMS_ROWS_PORT)
    local inputY = h - FOOTER - 2 - INPUT_H
    local commsY = inputY - 2 - commsH
    local cmdY = commsY - cmdH
    local mapY = HEADER + SEARCH + 2
    Dash.view.x, Dash.view.y = 4, mapY
    Dash.view.w = w - 8
    Dash.view.h = math.max(120, cmdY - 2 - mapY)
    Dash.chrome = {
      cmdY = cmdY,
      cmdH = cmdH,
      commsY = commsY,
      commsH = commsH,
      commsRows = COMMS_ROWS_PORT,
      inputY = inputY,
    }
  else
    local left = 124
    local insp = (Dash.inspect or 0) > 0.08 and 168 or 0
    local rows = chipRows(w - 12)
    local cmdH = 14 + rows * CHIP_ROW + 4
    local inputY = h - FOOTER - 2 - INPUT_H
    local cmdY = inputY - 2 - cmdH
    Dash.view.x, Dash.view.y = left, HEADER
    Dash.view.w = w - left - 4 - insp
    Dash.view.h = math.max(120, cmdY - HEADER)
    Dash.chrome = {
      cmdY = cmdY,
      cmdH = cmdH,
      commsY = nil,
      commsRows = 3,
      inputY = inputY,
    }
  end
  World.mapViewH = Dash.view.h
end

local function compactHudHit(mx, my)
  if not Layout.compact or not mx then return false end
  return my >= Layout.vh - 36
end

local function inspectorOverlayRect()
  if not Layout.isPortrait() then return nil end
  if (Dash.inspect or 0) < 0.08 then return nil end
  local a = Dash.inspect
  local pw = Layout.vw - 8
  local ph = 118
  local px = 4
  local py = Dash.view.y + Dash.view.h - ph * a
  return px, py, pw, ph
end

local function inspectorHit(mx, my)
  local px, py, pw, ph = inspectorOverlayRect()
  if not px then return false end
  return mx >= px and my >= py and mx < px + pw and my < py + ph
end

function Dash.update(dt)
  if Dash.screen == "settings" then
    local act = Settings.update(dt)
    if act == "apply" or act == "back" then
      Dash.screen = "map"
      if act == "apply" then Dash.banner = 1 end
    end
    return
  end
  Dash.t = Dash.t + dt
  Dash.banner = math.max(0, Dash.banner - dt * 0.45)
  Dash.lock.s = Ease.smooth(Dash.lock.s, Dash.lock.ts, dt, 10)
  Dash.inspect = Ease.smooth(Dash.inspect, Fleet.selected and 1 or 0, dt, 9)

  layoutMap()
  World.update(dt)
  Fleet.update(dt)
  Agents.update(dt)
  Chat.update(dt)
  Comms.update(dt)
  Autopilot.update(dt, Input.any())
  if Dash.searchFocus then
    if Input.text ~= "" then
      local add = Input.text:upper()
      if #Dash.search + #add <= 12 then Dash.search = Dash.search .. add end
    end
    if Input.backspace then
      Dash.search = Dash.search:sub(1, -2)
    end
    if Input.wasKey("escape") then
      Dash.search = ""
      Dash.searchFocus = false
    end
    if Input.wasKey("return") then
      local hits = Fleet.search(Dash.search, 1)
      if hits[1] then
        Dash.selectUnit(hits[1])
        World.focus(hits[1].x, hits[1].y - 16, 1.15, 0.18)
        Dash.searchFocus = false
      end
    end
  else
    local before = #Chat.lines
    Chat.handleInput(Input)
    if #Chat.lines > before and Dash.inputX then
      Comms.punch(Dash.inputX + 6, Dash.inputY + 2, Theme.amber)
    end
  end
  Commands.update(dt)

  local mx, my = Layout.mouse()
  local view = Dash.view
  local overMap = mx and mx >= view.x and my >= view.y and mx < view.x + view.w and my < view.y + view.h
      and not compactHudHit(mx, my) and not inspectorHit(mx, my)

  if Input.wheel ~= 0 and overMap then
    local f = Input.wheel > 0 and 1.18 or 0.84
    World.zoomAt(f, mx, my, view)
    Audio.play("blip", 1.2, 0.25)
  end

  if Chat.draft == "" and not Dash.searchFocus then
    local pan = 520 / World.cam.zoom * dt
    if love.keyboard.isDown("a") or love.keyboard.isDown("left") then World.pan(-pan, 0) end
    if love.keyboard.isDown("d") or love.keyboard.isDown("right") then World.pan(pan, 0) end
    if love.keyboard.isDown("w") or love.keyboard.isDown("up") then World.pan(0, -pan) end
    if love.keyboard.isDown("s") or love.keyboard.isDown("down") then World.pan(0, pan) end
  end

  if Input.wasKey("=") or Input.wasKey("kp+") then
    World.zoomAt(1.2, view.x + view.w * 0.5, view.y + view.h * 0.5, view)
  end
  if Input.wasKey("-") or Input.wasKey("kp-") then
    World.zoomAt(0.82, view.x + view.w * 0.5, view.y + view.h * 0.5, view)
  end
  if Input.wasKey("g") then
    World.focus(World.hangarX, World.SKY - 8, 1.08, 0.12)
  end
  if Input.wasKey("f2") then
    Dash.screen = "settings"
    Settings.enter()
    return
  end
  if Input.wasKey("f3") then
    Dash.toggleCompact()
  end
  if Input.wasKey("h") and Chat.draft == "" and not Dash.searchFocus then
    Commands.run("home")
  end

  if Chat.draft == "" and Input.text == "" and not Dash.searchFocus then
    for i = 1, Agents.wings() do
      if Input.wasKey(tostring(i)) then
        local u = Fleet.units[i]
        if u then
          Dash.selectUnit(u)
          Fleet.summonToRoof(u)
        end
      end
    end
    if Input.wasKey("0") then
      Dash.deselect()
    end
    if Input.wasKey("tab") then
      local hits = Fleet.search(Dash.search, 8)
      local cur = 0
      for i, u in ipairs(hits) do
        if Fleet.selected == u then cur = i break end
      end
      local nxt = hits[(cur % math.max(1, #hits)) + 1]
      if nxt then
        Dash.selectUnit(nxt)
        World.focus(nxt.x, nxt.y - 16, 1.1, 0.16)
      end
    end
  end

  -- drag pan
  if Dash.drag and mx and Input.down then
    local dx = mx - Dash.lmx
    local dy = my - Dash.lmy
    if math.abs(dx) + math.abs(dy) > 1 then
      World.pan(-dx / World.cam.zoom, -dy / World.cam.zoom)
      Dash.dragged = true
    end
  end
  Dash.lmx, Dash.lmy = mx or Dash.lmx, my or Dash.lmy
end

local function drawHeader()
  local w = Layout.vw
  local port = Layout.isPortrait()
  love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.92))
  love.graphics.rectangle("fill", 0, 0, w, 20)
  love.graphics.setColor(Theme.gold)
  love.graphics.rectangle("fill", 0, 19, w, 1)
  -- Portrait keeps the title to two letters: the brain badge beside it has
  -- to fit a whole word, and that word matters more than the name.
  Font.print(port and "J2" or "CWB JARVIS 2", 5, 6, Theme.gold, 1)

  local n = Fleet.stats.online
  local live = string.format("%d", n)
  local lx = port and 26 or 118
  UI.led(lx, 8, n == Fleet.COUNT, n > Fleet.COUNT * 0.8 and Theme.jade or Theme.amber)
  Font.print(live, lx + 8, 6, n == Fleet.COUNT and Theme.jade or Theme.amber, 1)
  if not port then
    Font.print("/" .. tostring(Fleet.COUNT), lx + 8 + #live * 8, 6, Theme.dim, 1)
  end

  -- Who answers the console, on every frame. With the backend up that is
  -- the agent brain — the same answer as the `AI …` chip in the footer —
  -- and only a checkout with no backend built falls back to the .env link.
  local st = Ollama.status()
  local word, col = "AI OFF", Theme.crimson
  if st.enabled then
    if st.cloud then word, col = port and "CLOUD" or "CLOUD AI", Theme.magenta
    else word, col = port and "ON-DEV" or "ON-DEVICE AI", Theme.jade end
  end

  local bx = port and (w - 228) or (w - 248)
  local hx = port and 64 or 190
  -- A filled badge rather than coloured text: the block is the signal and
  -- the whole word sits in it, so it reads from across the room.
  local room = math.max(0, math.floor((bx - 8 - hx) / 8))
  local shown = word:sub(1, room)
  local bw = #shown * 8 + 8
  love.graphics.setColor(col)
  love.graphics.rectangle("fill", hx, 3, bw, 14)
  Font.print(shown, hx + 4, 6, Theme.void, 1)
  if not port then
    local rest = st.model:upper()
    local spec = st.via == "curl" and Ollama.info and Ollama.info.params or nil
    if spec then rest = rest .. "  " .. spec end
    local left = math.max(0, math.floor((bx - 12 - hx - bw) / 8))
    Font.print(rest:sub(1, left), hx + bw + 6, 6, col, 1)
  end

  if UI.button("set", bx, 3, 32, 14, "SET", { stroke = Theme.gold, on = Dash.screen == "settings" }) then
    Dash.screen = "settings"
    Settings.enter()
  end
  if UI.button("lay", bx + 36, 3, 44, 14, Layout.isPortrait() and "VERT" or "HORZ", { stroke = Theme.teal }) then
    Layout.toggleOrientation()
    Audio.play("whoosh")
  end
  if UI.button("full", bx + 82, 3, 44, 14, Layout.fullscreen and "FULL" or "WIND", { stroke = Theme.cyan }) then
    Layout.toggleFullscreen()
    Audio.play("toggle")
  end
  if UI.button("mute", bx + 128, 3, 40, 14, Audio.muted and "MUTE" or "SFX", { stroke = Theme.magenta, on = Audio.muted }) then
    Audio.toggleMute()
  end
  if UI.button("comp", bx + 172, 3, 40, 14, "COMP", { stroke = Theme.gold, on = Layout.compact }) then
    Dash.toggleCompact()
  end
end

local function pickSearchUnit(u, fly)
  if not u then return end
  Dash.selectUnit(u)
  World.focus(u.x, u.y - 18, 1.12, 0.16)
  if fly then
    Fleet.summonToRoof(u)
    FX.toast("LAUNCH  U" .. string.format("%04d", u.id), Agents.colorOf(u))
  end
end

local function drawSearchHits(x, y, w, hits, rowH)
  for i, u in ipairs(hits) do
    local a = Agents.lookOf(u)
    local on = Fleet.selected == u
    local flying = u.phase == "fly" or u.phase == "exit" or u.phase == "hover"
      or u.phase == "wait" or u.phase == "align"
    -- An AI agent is listed by name, with its head beside it; a catalog
    -- drone by its number.
    local label = Fleet.tag(u)
    if u.robot then label = "  " .. label end
    if UI.button("sr" .. u.id, x, y, w, rowH - 2, label:sub(1, math.floor((w - 4) / 8)),
        { stroke = Agents.colorOf(u) or a.color, on = on }) then
      local now = Dash.t
      local dbl = (now - Dash.searchClickT) < 0.32
      Dash.searchClickT = now
      pickSearchUnit(u, dbl)
    end
    if u.robot and Sprites.head(a.key) then
      Sprites.drawHead(a.key, x + 2, y + 1, rowH - 4, 1)
    end
    local under = flying and "FLY" or (u.robot and (a.role or ""):sub(1, 14) or a.name:sub(1, 4))
    Font.print(string.format("F%03d %s", u.homeFloor or u.id, under), x, y + rowH - 1, flying and Theme.gold or Theme.dim, 1)
    y = y + rowH + 8
  end
  return y
end

local function drawAgentList()
  local port = Layout.isPortrait()
  local hits = Fleet.search(Dash.search, port and 4 or 8)

  if port then
    local y = 22
    local x = 4
    local boxW = 88
    local focused = Dash.searchFocus
    local shown = Dash.search
    if shown == "" and not focused then shown = "FIND..." end
    if focused and math.floor(Dash.t * 2) % 2 == 0 then shown = Dash.search .. "_" end
    love.graphics.setColor(Theme.navy)
    love.graphics.rectangle("fill", x, y, boxW, 12)
    love.graphics.setColor(focused and Theme.gold or Theme.teal)
    love.graphics.rectangle("line", x + 0.5, y + 0.5, boxW - 1, 11)
    Font.print(shown:sub(1, 10), x + 3, y + 2, focused and Theme.gold or Theme.dim, 1)
    if Layout.hit(x, y, boxW, 12) and Input.pressed then
      Dash.searchFocus = true
    end
    x = x + boxW + 4
    local none = Dash.nothingSelected()
    if UI.button("desel", x, y, 40, 12, "NONE",
        { stroke = none and Theme.dim or Theme.magenta, on = none }) then
      Dash.deselect()
    end
    x = x + 44
    for i, u in ipairs(hits) do
      local a = Agents.lookOf(u)
      local on = Fleet.selected == u
      local lab = u.robot and Fleet.tag(u):sub(1, 5) or string.format("U%02d", u.id)
      local ww = #lab * 8 + 8
      if UI.button("ag" .. u.id, x, y, ww, 12, lab, { stroke = Agents.colorOf(u) or a.color, on = on }) then
        local now = Dash.t
        local dbl = (now - Dash.searchClickT) < 0.32
        Dash.searchClickT = now
        pickSearchUnit(u, dbl)
      end
      x = x + ww + 3
    end
    return
  end

  love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.88))
  local listH = (Dash.chrome and Dash.chrome.cmdY or (Layout.vh - LAND_DOCK)) - HEADER
  love.graphics.rectangle("fill", 0, HEADER, 122, listH)
  love.graphics.setColor(Theme.gold)
  love.graphics.rectangle("fill", 121, HEADER, 1, listH)

  local x = 4
  local y = 24
  Font.print(Agents.roster and "AI AGENTS" or "AGENTS", x, y, Theme.dim, 1)
  Font.print(tostring(Fleet.COUNT), x + (Agents.roster and 80 or 56), y, Theme.gold, 1)
  y = y + 12

  local focused = Dash.searchFocus
  local shown = Dash.search
  if shown == "" and not focused then shown = Agents.roster and "NAME / FLOOR" or "ID / FLOOR" end
  if focused and math.floor(Dash.t * 2) % 2 == 0 then shown = Dash.search .. "_" end
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", x, y, 114, 14)
  love.graphics.setColor(focused and Theme.gold or Theme.teal)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, 113, 13)
  Font.print(shown:sub(1, 13), x + 3, y + 3, focused and Theme.gold or Theme.dim, 1)
  if Layout.hit(x, y, 114, 14) and Input.pressed then
    Dash.searchFocus = true
  end
  y = y + 18
  local none = Dash.nothingSelected()
  if UI.button("desel", x, y, 114, 13, none and "NO AGENT" or "DESELECT",
      { stroke = none and Theme.dim or Theme.magenta, on = none }) then
    Dash.deselect()
  end
  y = y + 17
  Font.print("CLICK LOCK  2X FLY", x, y, Theme.dim, 1)
  y = y + 12
  drawSearchHits(x, y, 114, hits, 12)
  if Agents.roster then
    -- How many fit above the command strip; the rest are a search away.
    local bottom = (Dash.chrome and Dash.chrome.cmdY or (Layout.vh - LAND_DOCK)) - 12
    if #hits < Fleet.COUNT then
      Font.print(string.format("+%d MORE", Fleet.COUNT - #hits), x, bottom, Theme.dim, 1)
    end
  end
end

local function drawLock(view)
  local u = Fleet.selected
  if not u then return end
  local sx, sy = World.toScreen(u.x, u.y, view)
  if sx < view.x or sy < view.y or sx > view.x + view.w or sy > view.y + view.h then return end
  local r = Dash.lock.s
  local col = Agents.colorOf(u)
  love.graphics.setColor(col)
  local t = 4
  love.graphics.rectangle("fill", sx - r, sy - r, t, 1)
  love.graphics.rectangle("fill", sx - r, sy - r, 1, t)
  love.graphics.rectangle("fill", sx + r - t, sy - r, t, 1)
  love.graphics.rectangle("fill", sx + r, sy - r, 1, t)
  love.graphics.rectangle("fill", sx - r, sy + r, t, 1)
  love.graphics.rectangle("fill", sx - r, sy + r - t, 1, t)
  love.graphics.rectangle("fill", sx + r - t, sy + r, t, 1)
  love.graphics.rectangle("fill", sx + r, sy + r - t, 1, t)
  local label = u.robot and Fleet.tag(u) or string.format("U%04d %s", u.id, Agents.lookOf(u).name)
  Font.print(label, sx + r + 4, sy - 4, col, 1)
  if u.house then
    Font.print(u.house.name .. " " .. u.house.job, sx + r + 4, sy + 6, Theme.gold, 1)
    local hx, hy = World.toScreen(u.house.x, u.house.y, view)
    love.graphics.setColor(col[1], col[2], col[3], 0.45)
    love.graphics.line(sx, sy, hx, hy)
    love.graphics.rectangle("line", hx - 4, hy - 4, 8, 8)
  end
end

local function drawMark(view)
  if not Dash.mark then return end
  local sx, sy = World.toScreen(Dash.mark.x, Dash.mark.y, view)
  local pulse = 0.5 + 0.5 * math.sin(Dash.t * 6)
  love.graphics.setColor(Theme.gold[1], Theme.gold[2], Theme.gold[3], 0.4 + 0.5 * pulse)
  love.graphics.rectangle("fill", sx - 3, sy, 7, 1)
  love.graphics.rectangle("fill", sx, sy - 3, 1, 7)
  love.graphics.circle("line", sx, sy, 5 + pulse * 2)
end

local function drawMinimap()
  local view = Dash.view
  local s = Layout.isPortrait() and 44 or 56
  local x = view.x + 4
  local y = view.y + view.h - s - 4
  if Layout.isPortrait() and (Dash.inspect or 0) > 0.08 then
    y = y - 118 * Dash.inspect
  end
  World.drawMinimap(x, y, s)
  Fleet.drawMinimapDots(x, y, s)
  if Layout.hit(x, y, s, s) and Input.pressed then
    local mx, my = Layout.mouse()
    World.hitMinimap(mx, my, x, y, s)
    Audio.play("whoosh")
  end
  if UI.button("zp", x + s + 3, y, 14, 14, "+", { stroke = Theme.gold }) then
    World.zoomAt(1.22, view.x + view.w * 0.5, view.y + view.h * 0.5, view)
  end
  if UI.button("zm", x + s + 3, y + 16, 14, 14, "-", { stroke = Theme.cyan }) then
    World.zoomAt(0.82, view.x + view.w * 0.5, view.y + view.h * 0.5, view)
  end
  Font.print(string.format("Z%.1f", World.cam.zoom), x + s + 3, y + s - 10, Theme.dim, 1)
end

local function drawInspector()
  local u = Fleet.selected
  local a = Dash.inspect
  if a < 0.02 then return end
  local port = Layout.isPortrait()
  local w = Layout.vw
  local pw, ph, px, py
  if port then
    pw = w - 8
    ph = 118
    px = 4
    py = Dash.view.y + Dash.view.h - ph * a
  else
    pw = 168
    ph = Dash.view.h - 8
    px = w - 4 - pw * a
    py = Dash.view.y + 4
  end

  love.graphics.setColor(Theme.withAlpha(Theme.panel, 0.88))
  love.graphics.rectangle("fill", px, py, pw, ph)
  love.graphics.setColor(u and Agents.colorOf(u) or Theme.gold)
  love.graphics.rectangle("line", px + 0.5, py + 0.5, pw - 1, ph - 1)
  if not u then return end

  local look = Agents.lookOf(u)
  local col = Agents.colorOf(u) or look.color
  Font.print(u.robot and "AI AGENT" or "UNIT", px + 6, py + 4, Theme.dim, 1)
  Font.print(u.robot and string.format("F%03d", u.homeFloor or u.id) or string.format("U%04d", u.id), px + 6, py + 14, col, 1)
  Sprites.drawFit(Sprites.agent(u.lookKey or look.key, true), px + pw - 58, py + 4, 52, 64, 0.95)
  Font.print(look.name, px + 6, py + 26, Theme.paper, 1)
  Font.print(look.role, px + 6, py + 36, Theme.dim, 1)

  local rec = {
    id = string.format("U%04d", u.id),
    task = u.ctx and u.ctx[2] or "PATROL",
    sector = look.territory or "GRID",
    link = u.online and "LIVE" or "IDLE",
  }
  Font.print(rec.sector, px + 6, py + 48, Theme.cyan, 1)
  local houseName = u.house and u.house.name or "ROOF"
  local job = u.house and u.house.job or rec.task
  local busy = "ON FLOOR"
  if u.phase == "fly" or u.phase == "exit" then busy = "FLIGHT"
  elseif u.phase == "hover" then busy = "HOVER"
  elseif u.phase == "align" then busy = "ALIGN"
  elseif u.house then busy = "AT " .. houseName end
  Font.print(houseName .. "  " .. job, px + 6, py + 58, Theme.gold, 1)
  Font.print(u.house and u.house.name or "ROOF", px + 6, py + 68, Theme.dim, 1)
  Font.print(busy, px + 6, py + 78, u.state == Fleet.STATE.WORK and Theme.jade or Theme.amber, 1)
  UI.bar(px + 6, py + 90, pw - 14, 4, u.state == Fleet.STATE.WORK and 0.85 or 0.4, col)

  if u.robot then
    -- The folder is the agent: say where it is, and open the two doors
    -- into it from here.
    Font.print("ONE FOLDER", px + 6, py + 100, Theme.magenta, 1)
    Font.print(tostring(look.folder or ""):upper():sub(1, math.floor((pw - 12) / 8)), px + 6, py + 110, Theme.dim, 1)
    if not port then
      Font.print(tostring(u.ctx and u.ctx[1] or ""):sub(1, 16), px + 6, py + 120, Theme.dim, 1)
    end
  else
    Font.print("CTX ONLY", px + 6, py + 100, Theme.magenta, 1)
    if u.ctx then
      Font.print(tostring(u.ctx[1] or ""):sub(1, 16), px + 6, py + 110, Theme.dim, 1)
      if not port then
        Font.print("CENTRAL HOLDS DB", px + 6, py + 120, Theme.gold, 1)
      end
    end
  end

  if not port then
    if u.robot then
      if UI.button("iface", px + 6, py + ph - 72, 74, 14, "FACE", { stroke = Theme.gold }) then
        Dash.request = "face"
      end
      if UI.button("ipage", px + 84, py + ph - 72, 74, 14, "PAGE", { stroke = Theme.cyan }) then
        Dash.request = "page"
      end
    end
    if UI.button("ip", px + 6, py + ph - 36, 74, 14, "PING", { stroke = Theme.cyan }) then
      Commands.run("ping")
    end
    if UI.button("if", px + 84, py + ph - 36, 74, 14, "FOCUS", { stroke = Theme.gold }) then
      Commands.run("focus")
    end
    if UI.button("il", px + 6, py + ph - 54, 74, 14, "FLY", { stroke = Theme.gold }) then
      Fleet.summonToRoof(u)
      FX.toast("LAUNCH  U" .. string.format("%04d", u.id), col)
    end
    if UI.button("ih", px + 84, py + ph - 54, 74, 14, "HOME", { stroke = Theme.magenta }) then
      Fleet.sendHome(u)
      World.chase = u
      World.rush = 1
      FX.toast("HOME  U" .. string.format("%04d", u.id), col)
    end
    if UI.button("ix", px + 6, py + ph - 18, 152, 14, "CLEAR LOCK", { stroke = Theme.dim }) then
      Fleet.unlock()
      Audio.play("toggle")
    end
  end
end

local function placeChips(x, y, maxW, rowH)
  local cx, cy = x, y
  local row = 0
  for i, c in ipairs(Commands.list) do
    local ww = #c.label * 8 + 10
    if cx + ww > x + maxW then
      cx = x
      cy = cy + rowH
      row = row + 1
    end
    c.tx, c.ty = cx, cy
    if c.x == 0 and c.y == 0 then c.x, c.y = cx, cy end
    cx = cx + ww + 3
  end
  return cy + 12
end

local function drawCommands(x, y, maxW)
  placeChips(x, y, maxW, 14)
  for _, c in ipairs(Commands.list) do
    local ww = #c.label * 8 + 10
    if UI.button("c" .. c.id, c.x, c.y, ww, 12, c.label, { stroke = c.stroke, on = false }) then
      Commands.run(c.id)
    end
  end
end

-- Countdown to the handover, or the live autopilot badge. Click to arm/disarm.
local function drawAutoChip(x, y)
  local col = Autopilot.color()
  local label = Autopilot.label()
  local pulse = 0.5 + 0.5 * math.sin(Dash.t * 5)
  if Autopilot.active then
    love.graphics.setColor(col[1], col[2], col[3], 0.10 + 0.16 * pulse)
    love.graphics.rectangle("fill", x - 2, y - 2, 94, 16)
  end
  if UI.button("auto", x, y, 90, 12, label, { stroke = col, on = Autopilot.active }) then
    Autopilot.toggle()
  end
end

-- One output line: latest JARVIS / EXEC / LINK row, including THINKING.
local function drawCompactOutput(x, y, w)
  local ln = Chat.recent(1)[1]
  love.graphics.setColor(Theme.navy[1], Theme.navy[2], Theme.navy[3], 0.88)
  love.graphics.rectangle("fill", x, y, w, 16)
  local col = ln and Comms.color(ln.colorKey) or Theme.dim
  love.graphics.setColor(col[1], col[2], col[3], 0.7)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, 15)
  love.graphics.setColor(col)
  love.graphics.rectangle("fill", x, y, 2, 16)
  local text = "READY"
  if ln then
    text = Comms.prefix(ln.who) .. (ln.text or "")
  end
  local room = math.floor((w - 10) / 8)
  Font.print(text:sub(1, room), x + 6, y + 4, ln and Theme.paper or Theme.dim, 1)
end

local function drawInput(x, y, w)
  Dash.inputX, Dash.inputY = x, y
  local live = Chat.draft ~= "" and not Dash.searchFocus
  local busy = Chat.awaiting ~= nil
  local pulse = 0.5 + 0.5 * math.sin(Dash.t * (busy and 7 or 3))
  local edge = live and Theme.gold or (busy and Theme.cyan or Theme.teal)

  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", x, y, w - 50, 16)
  -- a slow bar drifting behind the text, brighter while the link is thinking
  local sweep = (Dash.t * (busy and 0.7 or 0.25)) % 1
  love.graphics.setColor(edge[1], edge[2], edge[3], (busy and 0.16 or 0.07))
  love.graphics.rectangle("fill", x + sweep * (w - 50), y + 1, 18, 14)
  love.graphics.setColor(edge[1], edge[2], edge[3], 0.55 + 0.45 * (live and pulse or 0.4))
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 51, 15)

  if Layout.hit(x, y, w - 50, 16) and Input.pressed then
    Dash.searchFocus = false
  end

  local room = math.floor((w - 62) / 8)
  local shown = Chat.draft:sub(-room)
  Font.print(">" .. shown, x + 4, y + 4, Theme.amber, 1)
  local blink = Ease.inOutExpo(0.5 + 0.5 * math.sin(Dash.t * 8))
  love.graphics.setColor(Theme.amber[1], Theme.amber[2], Theme.amber[3], 0.25 + 0.75 * blink)
  love.graphics.rectangle("fill", x + 4 + (#shown + 1) * 8, y + 4, 6, 8)

  if UI.button("send", x + w - 46, y, 44, 16, "SAY", { stroke = Theme.gold }) then
    Chat.send()
    Comms.punch(x + 6, y + 2, Theme.amber)
  end
end

local function drawCompactHud()
  local w, h = Layout.vw, Layout.vh
  drawCompactOutput(4, h - 36, w - 52)
  if UI.button("comp", w - 44, h - 36, 40, 16, "COMP", { stroke = Theme.gold, on = true }) then
    Dash.toggleCompact()
  end
  drawInput(4, h - 18, w - 8)
end

-- The robot rail: who is chosen, and the two ways into the robot system.
--
-- It sits in the footer rather than the header because the header is already
-- full and because this is the one control that is about the *archive* rather
-- than about the swarm on the map.
local TONE_COLOR = { good = Theme.jade, info = Theme.sky, warn = Theme.crimson }

--- Where every button on the rail is, from the canvas width alone.
---
--- The same arithmetic the drawing uses, so a test can click these buttons
--- without a screenshot and without guessing — and so that "the button is
--- there" and "the button is where the click lands" cannot drift apart.
--- Returns nil for FACE when there is no robot to have a face.
function Dash.railRects(w)
  local h = Layout.vh
  local x, y = 4, h - 13
  local robot = Robots.current()
  local label = (robot and Robots.name(robot) or "NO AGENT")
  local bw = math.min(120, #label * 8 + 22)
  local out = { pick = { x = x, y = y, w = bw, h = 12 } }
  local px = x + bw + 3
  out.page = { x = px, y = y, w = 44, h = 12 }
  px = px + 47
  -- FACE is always here, because F4 always works. It used to appear only
  -- once a robot was chosen, on the reasoning that a menu should not
  -- advertise a face that is not there — but there always is one: with
  -- nobody chosen it is the open face, where the words pick the robot. A
  -- key that works and a button that is missing is the worse of the two.
  out.face = { x = px, y = y, w = 44, h = 12 }
  px = px + 47

  -- The brain switch takes what is left. Its label carries the wish as
  -- well as the outcome, which is longer — so when the rest of the rail
  -- has eaten the room, the parenthetical is dropped rather than the
  -- button being drawn off the edge where it cannot be clicked.
  local full = Layout.isPortrait() and Backend.providerShort() or Backend.providerLabel()
  local room = w - px - 4
  local plabel = full
  if #plabel * 8 + 10 > room then plabel = (full:gsub("%s*%b()%s*$", "")) end
  out.label = plabel
  out.provider = { x = px, y = y, w = math.min(#plabel * 8 + 10, math.max(24, room)), h = 12 }
  -- How wide the rail came out, for the hint text beside it.
  out.used = (px - x) + out.provider.w + 3
  return out
end

-- Drawn from `Dash.railRects`, not from a second copy of the same
-- arithmetic. They were two copies, and two copies of where a button is
-- are two chances for the button to be somewhere the click is not.
local function drawRobotRail()
  local rects = Dash.railRects(Layout.vw)
  local robot = Robots.current()
  local accent = Robots.color(robot)
  local label = (robot and Robots.name(robot) or "NO AGENT")

  local b = rects.pick
  if UI.button("robotpick", b.x, b.y, b.w, b.h, "", { stroke = Theme.dim, hot = accent }) then
    Robots.cycle(1)
    Audio.play("toggle")
  end
  if robot and Sprites.head(robot.sprite) then
    Sprites.drawHead(robot.sprite, b.x + 2, b.y + 1, 10, 1)
  else
    UI.led(b.x + 5, b.y + 4, Robots.loaded, accent)
  end
  Font.print(label, b.x + 14, b.y + 2, accent, 1)

  b = rects.page
  if UI.button("robotpage", b.x, b.y, b.w, b.h, "PAGE", { stroke = Theme.cyan }) then
    Dash.request = "page"
  end

  -- FACE, always: with nobody chosen it is the open face, which is a real
  -- screen and the one F4 opens.
  b = rects.face
  if UI.button("robotface", b.x, b.y, b.w, b.h, "FACE",
    { stroke = robot and Theme.gold or Theme.dim }) then
    Dash.request = "face"
  end

  -- The brain switch: auto / on-device / cloud, changeable mid-session. The
  -- label shows the wish and — when they differ — the outcome, because a
  -- toggle that shows only the wish is how on-device quietly becomes a
  -- cloud call, and one that shows only the outcome does not appear to
  -- work at all on the step from auto to on-device.
  local pcolor = TONE_COLOR[Backend.providerTone()] or Theme.dim
  b = rects.provider
  if UI.button("provider", b.x, b.y, b.w, b.h, rects.label,
    { stroke = pcolor, fill = Theme.withAlpha(pcolor, 0.85), labelColor = Theme.void, hot = pcolor }) then
    Dash.request = "provider"
  end
  return rects.used
end

local function drawFooter()
  local w, h = Layout.vw, Layout.vh
  love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.95))
  love.graphics.rectangle("fill", 0, h - 14, w, 14)
  love.graphics.setColor(Theme.magenta)
  love.graphics.rectangle("fill", 0, h - 14, w, 1)
  local used = drawRobotRail()
  local hint = Layout.isPortrait()
      and "F2 PAGE  F4 FACE  F6 NEXT"
      or "F2 PAGE  F4 FACE  F6 NEXT AGENT  CLICK ONE ON THE TOWER"
  local room = math.floor((w - used - 12) / 8)
  if room > 12 then
    Font.print(hint:sub(1, room), used + 8, h - 11, Theme.dim, 1)
  end
end

local function drawBanner()
  if Dash.banner <= 0 then return end
  local a = math.min(1, Dash.banner)
  if Dash.banner < 0.3 then a = Dash.banner / 0.3 end
  local w, h = Layout.vw, Layout.vh
  local bw = 280
  local bx = math.floor((w - bw) / 2)
  local by = math.floor(h * 0.42)
  love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.7 * a)
  love.graphics.rectangle("fill", bx, by, bw, 36)
  love.graphics.setColor(Theme.gold[1], Theme.gold[2], Theme.gold[3], a)
  love.graphics.rectangle("line", bx + 0.5, by + 0.5, bw - 1, 35)
  Font.print("TOWER PROTOCOL", bx + 40, by + 8, { Theme.gold[1], Theme.gold[2], Theme.gold[3], a }, 1)
  Font.print(Agents.roster
    and string.format("%d AI AGENTS  //  ONE FOLDER EACH", Fleet.COUNT)
    or string.format("%d AGENTS  //  ONE ROBOT PER FLOOR", Fleet.COUNT), bx + 4, by + 20, { Theme.cyan[1], Theme.cyan[2], Theme.cyan[3], a }, 1)
end

local function drawToasts()
  local y = Dash.view.y + 6
  local x = Layout.isPortrait() and (Dash.view.x + 4) or (Dash.view.x + 4)
  -- skip if comms hud is there - put toasts top-right of map
  x = Dash.view.x + Dash.view.w - 180
  for i, t in ipairs(FX.toasts) do
    local a = 1
    if t.t < 0.15 then a = t.t / 0.15 end
    if t.t > t.life - 0.4 then a = (t.life - t.t) / 0.4 end
    local ty = y + (i - 1) * 12
    love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.65 * a)
    local tw = #t.text * 8 + 8
    love.graphics.rectangle("fill", x + (180 - tw), ty, tw, 10)
    Font.print(t.text, x + (180 - tw) + 4, ty + 1, { t.color[1], t.color[2], t.color[3], a }, 1)
  end
end

local function handleMapClick()
  local mx, my = Layout.mouse()
  local view = Dash.view
  if not mx then return end
  if UI.isHot() or compactHudHit(mx, my) or inspectorHit(mx, my) then
    Dash.drag = false
    return
  end
  local over = mx >= view.x and my >= view.y and mx < view.x + view.w and my < view.y + view.h
  if Input.pressed and over then
    Dash.searchFocus = false
    Dash.drag = true
    Dash.dragged = false
    Dash.lmx, Dash.lmy = mx, my
  end
  if Input.released then
    if Dash.drag and over and not Dash.dragged then
      local wx, wy = World.toWorld(mx, my, view)
      local now = Dash.t
      local dbl = (now - Dash.clickT) < 0.32
      Dash.clickT = now
      local kind, hit = Fleet.probe(wx, wy, World.cam.zoom)
      if kind == "unit" then
        Dash.selectUnit(hit)
        if dbl then
          Fleet.summonToRoof(hit)
          FX.toast("SUMMON  " .. Fleet.tag(hit), Agents.colorOf(hit))
        end
      else
        local fl = World.pickHouse(wx, wy)
        Dash.mark = { x = wx, y = fl and fl.y or wy }
        Commands.lastPoint = Dash.mark
        Audio.play("blip", 0.8, 0.4)
        if dbl then
          if Fleet.selected then
            local dest = fl or { x = World.hangarX, y = World.SKY }
            Fleet.summon(Fleet.selected, dest.x, dest.y)
            World.chase = Fleet.selected
            World.rush = 1
            FX.toast("FLY  " .. (fl and fl.name or "ROOF"), Theme.gold)
          else
            Commands.run("rally", Dash.mark)
          end
        else
          Fleet.unlock()
        end
      end
    end
    Dash.drag = false
    Dash.dragged = false
  end
end

function Dash.draw()
  if Dash.screen == "settings" then
    local act = Settings.draw()
    if act == "apply" or act == "back" then
      Dash.screen = "map"
      if act == "apply" then Dash.banner = 1 end
    end
    FX.draw()
    return
  end

  local w, h = Layout.vw, Layout.vh
  local port = Layout.isPortrait()
  layoutMap()
  local view = Dash.view

  local sx = (FX.shake or 0) > 0 and ((love.math.random() * 2 - 1) * FX.shake) or 0
  local sy = (FX.shake or 0) > 0 and ((love.math.random() * 2 - 1) * FX.shake * 0.5) or 0
  love.graphics.push()
  love.graphics.translate(sx, sy)

  love.graphics.setColor(Theme.void)
  love.graphics.rectangle("fill", 0, 0, w, h)

  World.draw(view)
  Fleet.draw(view)
  FX.drawWorld()
  World.finish(view)
  Fleet.drawClusterLabels(view)

  drawMark(view)
  drawLock(view)

  if Layout.compact then
    drawToasts()
    drawCompactHud()
  else
    drawMinimap()
    if not port then
      Comms.draw(view.x + 56, view.y + 6, 364, 3)
    end
    drawToasts()

    if Dash.banner > 0.15 then
      -- scan sweep on map
      local scanY = view.y + ((Dash.t * 50) % view.h)
      love.graphics.setColor(Theme.withAlpha(Theme.cyan, 0.10 * math.min(1, Dash.banner)))
      love.graphics.rectangle("fill", view.x, scanY, view.w, 3)
    end

    drawHeader()
    drawAgentList()
    drawInspector()
    drawFooter()
    drawBanner()

    local chrome = Dash.chrome
    if port then
      local cy = chrome.cmdY
      love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.94))
      love.graphics.rectangle("fill", 0, cy, w, h - cy - FOOTER)
      love.graphics.setColor(Theme.magenta)
      love.graphics.rectangle("fill", 0, cy, w, 1)
      Font.print("COMMAND  " .. Fleet.scopeLabel(), 6, cy + 2, Theme.magenta, 1)
      drawAutoChip(w - 96, cy)
      drawCommands(6, cy + 14, w - 12)
      Comms.draw(6, chrome.commsY, w - 12, chrome.commsRows)
      drawInput(4, chrome.inputY, w - 8)
    else
      love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.94))
      love.graphics.rectangle("fill", 0, chrome.cmdY, w, h - chrome.cmdY - FOOTER)
      love.graphics.setColor(Theme.magenta)
      love.graphics.rectangle("fill", 0, chrome.cmdY, w, 1)
      Font.print("COMMAND", 6, chrome.cmdY + 2, Theme.magenta, 1)
      Font.print(Fleet.scopeLabel(), 78, chrome.cmdY + 2, Theme.gold, 1)
      Font.print("USAGE SORT", 78 + #Fleet.scopeLabel() * 8 + 12, chrome.cmdY + 2, Theme.dim, 1)
      drawAutoChip(w - 96, chrome.cmdY)
      drawCommands(6, chrome.cmdY + 14, w - 12)
      drawInput(4, chrome.inputY, w - 8)
    end
  end

  FX.draw()
  love.graphics.pop()

  handleMapClick()
end

return Dash
