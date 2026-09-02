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
local Ollama = require("src.ollama")
local Backend = require("src.backend")

local Boot = {
  phase = "power",
  t = 0,
  flash = 0,
  term = "",
  termTarget = "",
  termAcc = 0,
  suit = 0,
  suitT = 0,
  shake = 0,
  lines = {},
  onDone = nil,
}

local TONE = { good = "jade", info = "cyan", warn = "magenta" }

local TERM_A = "CAUSEWAY BAY NODE 02"
local TERM_B = "J.A.R.V.I.S. KERNEL  //  STANDBY"

function Boot.enter(onDone)
  Boot.onDone = onDone
  Boot.phase = "power"
  Boot.t = 0
  Boot.flash = 1
  Boot.term = ""
  Boot.termTarget = TERM_A
  Boot.termAcc = 0
  Boot.suit = 0
  Boot.suitT = 0
  Boot.shake = 0
  Boot.lines = {}
  -- The roster, when the backend has answered, is what powers up; the
  -- catalog is rolled only when there is nothing else to put in the bays.
  Agents.roll()
  Chat.reset()
  FX.clear()
  Audio.setHum(false)
  Audio.play("crt_on")
end

local function addLine(text)
  Boot.lines[#Boot.lines + 1] = { text = text, t = 0 }
end

--- How the suit bay is divided for `n` agents: columns and rows. Four in a
--- row was the shape for four wings; a roster of twelve gets two rows in
--- landscape and three columns in portrait, so a pod is never narrower
--- than its own name. Pure, for the tests.
function Boot.bayGrid(n, portrait)
  n = math.max(1, n or 1)
  if portrait then
    local cols = n > 6 and 3 or 2
    return cols, math.ceil(n / cols)
  end
  if n > 8 then
    local rows = 2
    return math.ceil(n / rows), rows
  end
  return n, 1
end

-- Where the robot stands on the boot screen.
local function robotRect()
  local w, h = Layout.vw, Layout.vh
  if Layout.isPortrait() then
    return (w - 150) / 2, 52, 150, 170
  end
  return 18, 40, 170, 150
end

function Boot.clap()
  if Boot.phase ~= "wait" and Boot.phase ~= "term" and Boot.phase ~= "power" then return end
  Boot.phase = "clap"
  Boot.t = 0
  Boot.flash = 1
  Boot.shake = 6
  Boot.term = TERM_B
  Audio.play("clap")
  FX.burst(Layout.vw * 0.5, Layout.vh * 0.42, Theme.cyan, 20)
  FX.burst(Layout.vw * 0.5, Layout.vh * 0.42, Theme.gold, 10)
end

function Boot.update(dt)
  Boot.t = Boot.t + dt
  Boot.flash = math.max(0, Boot.flash - dt * 2.4)
  Boot.shake = math.max(0, Boot.shake - dt * 18)
  for _, ln in ipairs(Boot.lines) do ln.t = ln.t + dt end

  local clapKey = Input.wasKey("space") or Input.wasKey("return")
  local qa = love.filesystem.getInfo("QA") ~= nil or os.getenv("JARVIS_QA") == "1"

  if Boot.phase == "power" then
    if clapKey then Boot.clap() end
    if qa and Boot.t > 0.25 then
      Boot.term = TERM_B
      Boot.t = 0
      Boot.phase = "wait"
    elseif Boot.t > 0.55 then
      Boot.phase = "term"
      Boot.t = 0
    end
  elseif Boot.phase == "term" then
    Boot.termAcc = Boot.termAcc + dt
    while Boot.termAcc > 0.045 and #Boot.term < #Boot.termTarget do
      Boot.termAcc = Boot.termAcc - 0.045
      Boot.term = Boot.termTarget:sub(1, #Boot.term + 1)
      Audio.play("type", 1, 0.4)
    end
    if #Boot.term >= #Boot.termTarget then
      if Boot.termTarget == TERM_A and Boot.t > 1.35 then
        Boot.termTarget = TERM_B
        Boot.term = ""
        Boot.t = 0
      elseif Boot.termTarget == TERM_B and Boot.t > 1.1 then
        Boot.phase = "wait"
        Boot.t = 0
      end
    end
    if clapKey then Boot.clap() end
  elseif Boot.phase == "wait" then
    -- The QA walk claps from main.lua, once it has photographed this.
    if clapKey then Boot.clap() end
  elseif Boot.phase == "clap" then
    if Boot.t > 0.18 and Boot.t - dt <= 0.18 then Audio.play("sting") end
    if Boot.t > 0.85 then
      Boot.phase = "report"
      Boot.t = 0
      addLine("GOOD EVENING, SIR.")
      Audio.setHum(false)
    end
  elseif Boot.phase == "report" then
    if Boot.t > 0.75 and #Boot.lines == 1 then
      addLine("ALL SYSTEMS COMING ONLINE.")
      Audio.play("scan")
    end
    if Boot.t > 1.5 and #Boot.lines == 2 then
      addLine("BRINGING THE SUIT BAYS UP.")
    end
    if Boot.t > 2.15 then
      Boot.phase = "suits"
      Boot.t = 0
      Boot.suit = 0
      Boot.suitT = 0
    end
  elseif Boot.phase == "suits" then
    Boot.suitT = Boot.suitT + dt
    -- Twelve agents at the four-agent pace is six seconds of bays; the
    -- whole roster comes up in about three whatever its size.
    local n = Agents.wings()
    local gap = (clapKey or qa) and 0.10 or math.min(0.48, 3.2 / math.max(1, n))
    if Boot.suit < n and Boot.suitT > gap then
      Boot.suitT = 0
      Boot.suit = Boot.suit + 1
      Agents.setOnline(Boot.suit, true)
      local a = Agents.list[Boot.suit]
      addLine(string.format("%s  %s  ........  ONLINE", a.bay, a.name))
      Audio.play("spark")
      Audio.play("online", 0.92 + Boot.suit * 0.06)
      Boot.flash = 0.22
      local w, h = Layout.vw, Layout.vh
      local port = Layout.isPortrait()
      local bayH = port and 210 or 118
      local bayY = h - bayH - 18
      local cols, rows = Boot.bayGrid(n, port)
      local slotW = (w - 24) / cols
      local slotH = (bayH - 16) / rows
      local col = (Boot.suit - 1) % cols
      local row = math.floor((Boot.suit - 1) / cols)
      local cx = 14 + col * slotW + slotW * 0.5
      local cy = bayY + 8 + row * slotH + slotH * 0.45
      FX.burst(cx, cy, a.color, 18)
      FX.flash(14 + col * slotW, bayY + 8 + row * slotH, slotW - 4, slotH - 4, a.color, 0.28)
    end
    if Boot.suit >= n and Boot.suitT > 0.85 then
      addLine(Agents.roster
        and string.format("%d AI AGENTS LIVE. ONE FOLDER EACH.", n)
        or string.format("%d AGENTS LIVE. TOWER GRID ONLINE.", n))
      Boot.phase = "hold"
      Boot.t = 0
      Audio.play("sting", 1.05, 0.7)
    end
  elseif Boot.phase == "hold" then
    if Boot.t > (qa and 0.3 or 1.15) then
      for _, ln in ipairs(Ollama.report()) do
        Chat.push("LINK", ln.text, TONE[ln.tone] or "cyan")
      end
      -- The robot backend's own picture: which brain answers a turn, and
      -- when that is this machine, which engine — MLX or the ollama daemon.
      for _, ln in ipairs(Backend.report()) do
        Chat.push("AGENT", ln.text, TONE[ln.tone] or "cyan")
      end
      Chat.push("JARVIS", Agents.voice().boot, "jarvis")
      Chat.push("JARVIS", "FLEET IS YOURS, SIR. POINT AT THE MAP.", "jarvis")
      if Boot.onDone then Boot.onDone() end
    end
  end

  Agents.update(dt)
end

local function drawHangar(alpha)
  local img = Layout.isPortrait() and Sprites.img.hangarP or Sprites.img.hangar
  Sprites.drawCover(img, 0, 0, Layout.vw, Layout.vh, alpha or 0.42)
end

local function drawToolbar()
  local w = Layout.vw
  Font.print("CAUSEWAY BAY  //  JARVIS 2", 8, 6, Theme.amber, 1)
  Font.print(os.date("%H:%M:%S"), w - 8 - 8 * 8, 6, Theme.dim, 1)
  local x = Layout.isPortrait() and 8 or 220
  local y = Layout.isPortrait() and 18 or 6
  if UI.button("blay", x, y, 42, 12, Layout.isPortrait() and "VERT" or "HORZ", {stroke = Theme.teal}) then
    Layout.toggleOrientation()
    Audio.play("whoosh")
  end
  if UI.button("bfull", x + 46, y, 42, 12, Layout.fullscreen and "FULL" or "WIND", {stroke = Theme.cyan}) then
    Layout.toggleFullscreen()
    Audio.play("toggle")
  end
  if UI.button("bmute", x + 92, y, 36, 12, Audio.muted and "MUTE" or "SFX", {stroke = Theme.magenta, on = Audio.muted}) then
    Audio.toggleMute()
  end
  if UI.button("bcomp", x + 132, y, 40, 12, "COMP", {stroke = Theme.gold, on = Layout.compact}) then
    Layout.toggleCompact()
    Audio.play("whoosh")
  end
end

local function drawPod(a, x, y, w, h, on)
  local cx, cy = x + w / 2, y + h / 2 - 4
  local r = math.min(w, h) * 0.42
  if on then
    love.graphics.setColor(Theme.withAlpha(a.color, 0.16 + 0.08 * a.power))
    UI.hex(cx, cy, r + 3, Theme.withAlpha(a.color, 0.16 + 0.08 * a.power), true)
  end
  UI.hex(cx, cy, r, Theme.withAlpha(on and a.color or Theme.dim, on and 0.9 or 0.4))
  Sprites.drawFit(Sprites.img[a.key], x + 4, y + 2, w - 8, h - 16, on and 1 or 0.22)
  UI.led(x + 3, y + 3, on, on and a.color or Theme.dim)
  Font.print(a.name, x + 10, y + h - 12, on and a.color or Theme.dim, 1)
  if on then
    UI.bar(x + 4, y + h - 6, w - 8, 3, a.power, a.color)
  end
end

-- Who is actually answering: on-device weights or a cloud relay, which
-- model, and how big it is. Redrawn from live state so the specs fill in
-- the moment the probe lands, and the cloud caution never scrolls away.
local function drawLink(x, y, w)
  local rows = Ollama.report()
  local h = 20 + #rows * 10
  local st = Ollama.status()
  local accent = Theme.crimson
  if st.enabled then accent = st.cloud and Theme.magenta or Theme.jade end
  UI.panel(x, y - h, w, h, "AI LINK", accent)
  UI.led(x + w - 8, y - h + 3, st.enabled, accent)
  local cols = { good = Theme.jade, info = Theme.ice, warn = Theme.magenta }
  for i, ln in ipairs(rows) do
    Font.print(ln.text:sub(1, math.floor((w - 12) / 8)), x + 6, y - h + 12 + (i - 1) * 10,
      cols[ln.tone] or Theme.cyan, 1)
  end
  return h
end

function Boot.draw()
  local w, h = Layout.vw, Layout.vh
  local sx = (Boot.shake > 0) and ((love.math.random() * 2 - 1) * Boot.shake) or 0
  local sy = (Boot.shake > 0) and ((love.math.random() * 2 - 1) * Boot.shake * 0.4) or 0
  love.graphics.push()
  love.graphics.translate(sx, sy)

  if Boot.phase == "power" then
    local k = math.min(1, Boot.t / 0.12)
    if Boot.t < 0.12 then
      love.graphics.setColor(Theme.paper)
      love.graphics.rectangle("fill", 0, 0, w, h)
    else
      local line = 1 + (h - 1) * math.min(1, (Boot.t - 0.12) / 0.35)
      love.graphics.setColor(Theme.void)
      love.graphics.rectangle("fill", 0, 0, w, h)
      love.graphics.setColor(Theme.amber)
      love.graphics.rectangle("fill", 0, (h - line) / 2, w, math.max(1, line * 0.04))
      love.graphics.setColor(Theme.withAlpha(Theme.cyan, 0.35))
      love.graphics.rectangle("fill", 0, (h - line) / 2, w, line)
    end
    love.graphics.pop()
    return
  end

  love.graphics.setColor(Theme.void)
  love.graphics.rectangle("fill", 0, 0, w, h)
  drawHangar((Boot.phase == "term" or Boot.phase == "wait") and 0.32 or 0.48)
  love.graphics.setColor(Theme.withAlpha(Theme.void, 0.28))
  love.graphics.rectangle("fill", 0, 0, w, h)

  drawToolbar()

  local port = Layout.isPortrait()
  local cx = port and w / 2 or (w * 0.62)
  local cy = port and (h * 0.34) or (h * 0.42)
  local pulse = 0.5 + 0.5 * math.sin(Boot.t * 2.4)

  if Boot.phase == "term" or Boot.phase == "wait" then
    local px, py, pw, ph = robotRect()
    UI.rings(cx, cy, (port and 88 or 78) + pulse * 6, Boot.t, Theme.cyan, Theme.gold)
    Sprites.drawFit(Sprites.img.jarvis, px, py, pw, ph, 0.92)
    Sprites.drawFit(Sprites.img.emblem, port and (w / 2 - 36) or (w - 84), port and 28 or 28, 72, 40, 0.7 + 0.2 * pulse)

    -- What the brain is doing while the signal is waited for: the model
    -- load, when there is one, in a line under the robot.
    local status = Backend.prepareStatus()
    if status ~= "none" then
      local line = Backend.prepareLine()
      local col = (status == "ready" and Theme.jade) or (status == "failed" and Theme.crimson) or Theme.cyan
      Font.print(line:sub(1, math.floor((w - 20) / 8)), px, py + ph + 6, col, 1)
    end

    local tx = 10
    local ty = port and math.floor(h * 0.60) or 22
    do
    Font.print("> " .. Boot.term, tx, ty, Theme.amber, 1)
    if (math.floor(Boot.t * 4) % 2 == 0) or Boot.phase == "wait" then
      local tw = Font.measure("> " .. Boot.term, 1)
      love.graphics.setColor(Theme.amber)
      love.graphics.rectangle("fill", tx + tw, ty, 8, 8)
    end
    if port then
      Font.print("SIR, THE WORKSHOP AWAITS", tx, ty + 14, Theme.dim, 1)
    end
    end
  end

  if Boot.phase == "wait" then
    local bw, bh = 188, 30
    local bx = math.floor((w - bw) / 2)
    local by = port and math.floor(h * 0.78) or math.floor(h * 0.74)
    love.graphics.setColor(Theme.withAlpha(Theme.magenta, 0.10 + 0.10 * pulse))
    love.graphics.rectangle("fill", bx - 6, by - 6, bw + 12, bh + 12)
    UI.hex(bx + bw / 2, by + bh / 2, 70 + pulse * 10, Theme.withAlpha(Theme.cyan, 0.22))
    UI.hex(bx + bw / 2, by + bh / 2, 52 + pulse * 7, Theme.withAlpha(Theme.gold, 0.28))
    if UI.button("clap", bx, by, bw, bh, "CLAP", {stroke = Theme.magenta, hot = Theme.cyan, scale = 1, silent = true}) then
      Boot.clap()
    end
    Font.print("SPACE  //  ENTER", bx + 36, by + 34, Theme.dim, 1)
    if not port then
      Font.print("SIR, THE WORKSHOP AWAITS YOUR SIGNAL", 12, by - 14, Theme.dim, 1)
    end
  end

  if Boot.phase == "clap" or Boot.phase == "report" or Boot.phase == "suits" or Boot.phase == "hold" then
    if port then
      Sprites.drawFit(Sprites.img.emblem, w / 2 - 70, 30, 140, 64, 0.6 + 0.2 * math.sin(Boot.t * 3))
    else
      Sprites.drawFit(Sprites.img.emblem, w - 148, 24, 130, 60, 0.6 + 0.2 * math.sin(Boot.t * 3))
    end
    local ly = port and 100 or 36
    local maxLog = port and 10 or 5
    local start = math.max(1, #Boot.lines - maxLog + 1)
    local row = 0
    for i = start, #Boot.lines do
      local ln = Boot.lines[i]
      local col = Theme.cyan
      if ln.text:find("ONLINE") then col = Theme.jade end
      if ln.text:find("GOOD") then col = Theme.gold end
      Font.print(ln.text, 12, ly + row * 12, col, 1)
      row = row + 1
    end

    local bayH = port and 220 or 122
    local bayY = h - bayH - 16
    drawLink(8, bayY - 8, w - 16)
    UI.panel(8, bayY, w - 16, bayH, "SUIT BAY", Theme.cyan)
    local n = Agents.wings()
    local cols, rows = Boot.bayGrid(n, port)
    local slotW = (w - 28) / cols
    local slotH = (bayH - 16) / rows
    for i = 1, n do
      local a = Agents.list[i]
      if a then
        local col = (i - 1) % cols
        local rw = math.floor((i - 1) / cols)
        local px = 14 + col * slotW
        local py = bayY + 10 + rw * slotH
        drawPod(a, px, py, slotW - 4, slotH - 4, i <= Boot.suit)
      end
    end
  end

  if Boot.phase == "hold" then
    Font.print("ENTERING WORKSHOP...", 12, h - 14, Theme.gold, 1)
  end

  FX.draw()
  love.graphics.pop()

  if Boot.flash > 0 then
    love.graphics.setColor(1, 1, 1, Boot.flash * 0.85)
    love.graphics.rectangle("fill", 0, 0, w, h)
  end
end

return Boot
