local Theme = require("src.theme")
local Store = require("src.store")
local Json = require("src.json")

local Layout = {
  mode = "landscape", -- landscape | portrait
  fullscreen = true,
  compact = false,    -- map fills the window; chrome collapses to input + output
  pendingWindow = false,
  vw = Theme.landW,
  vh = Theme.landH,
  scale = 2,
  ox = 0,
  oy = 0,
  canvas = nil,
}

-- Display state persists as a jsonl log in the store folder
-- (~/.causewaybayjarvis2/display.jsonl). One object per line, appended on
-- every toggle; the last readable line wins on the next launch. Keeping the
-- history makes the file greppable, so it is trimmed rather than truncated.
Layout.LOG = "display.jsonl"
local LOG_MAX = 200
local LOG_KEEP = 40

local function record()
  return {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    mode = Layout.mode,
    fullscreen = Layout.fullscreen and true or false,
    compact = Layout.compact and true or false,
  }
end

local function trim()
  local lines = Store.lines(Layout.LOG)
  if #lines <= LOG_MAX then return end
  local keep = {}
  for i = #lines - LOG_KEEP + 1, #lines do keep[#keep + 1] = lines[i] end
  Store.write(Layout.LOG, table.concat(keep, "\n") .. "\n")
end

-- Append the current orientation / window mode.
function Layout.save()
  local ok = Store.append(Layout.LOG, Json.encode(record()) .. "\n")
  if ok then trim() end
  return ok
end

-- Restore from the last usable line. Returns true when something was applied.
function Layout.load()
  local lines = Store.lines(Layout.LOG)
  for i = #lines, 1, -1 do
    local rec = Json.decode(lines[i])
    if type(rec) == "table" then
      local applied = false
      if rec.mode == "portrait" or rec.mode == "landscape" then
        Layout.mode = rec.mode
        applied = true
      end
      if type(rec.fullscreen) == "boolean" then
        Layout.fullscreen = rec.fullscreen
        applied = true
      end
      if type(rec.compact) == "boolean" then
        Layout.compact = rec.compact
        applied = true
      end
      if applied then return true end
    end
  end
  return false
end

-- macOS screen capture (Shift+Cmd+5, screencapture, QuickTime) cannot see a
-- window in exclusive fullscreen: SDL parks it above the shielding window
-- level, so the recorder overlay never opens over the app and the grab comes
-- back as the bare desktop. Borderless "desktop" fullscreen draws the same
-- picture and stays capturable, so that is the default. It costs the menu bar
-- / notch band on a notched panel (1280x803 of an 1280x832 desktop), so
-- JARVIS_FULLSCREEN=exclusive opts back into edge-to-edge for anyone who
-- would rather have the pixels than the screen recorder.
local FULLSCREEN_TYPES = { desktop = true, exclusive = true }
Layout.fullscreenPref = nil

function Layout.fullscreenType()
  local want = Layout.fullscreenPref or os.getenv("JARVIS_FULLSCREEN") or ""
  want = tostring(want):lower()
  if FULLSCREEN_TYPES[want] then return want end
  return "desktop"
end

local function windowFlags()
  return {
    fullscreen = false,
    resizable = not Layout.fullscreen,
    vsync = 1,
    msaa = 0,
    minwidth = 640,
    minheight = 360,
    centered = true,
  }
end

function Layout.applyWindow()
  -- Window mode cannot change while a Canvas is bound.
  if love.graphics.getCanvas() then
    love.graphics.setCanvas()
  end
  local flags = windowFlags()
  if Layout.fullscreen then
    local ftype = Layout.fullscreenType()
    local dw, dh = love.window.getDesktopDimensions()
    local ww, wh, cur = love.window.getMode()
    -- Exclusive snaps to the video mode nearest the size it is handed, and the
    -- conf size (1280x720) lands on a shorter 16:10 mode the OS then
    -- letterboxes, so ask for the panel's own desktop mode by name. Desktop
    -- fullscreen sizes itself and ignores the request.
    local sized = ftype == "desktop" or (ww == dw and wh == dh)
    if not (cur.fullscreen and cur.fullscreentype == ftype and sized) then
      love.window.setMode(dw, dh, {
        fullscreen = true,
        fullscreentype = ftype,
        vsync = 1,
        msaa = 0,
        highdpi = false,
      })
    end
  else
    love.window.setFullscreen(false)
    local dw, dh = love.window.getDesktopDimensions()
    if Layout.mode == "portrait" then
      local h = math.min(1280, math.max(640, dh - 100))
      local w = math.max(360, math.floor(h * Theme.portW / Theme.portH))
      love.window.setMode(w, h, flags)
    else
      local ww = math.min(1280, math.max(640, dw - 80))
      local wh = math.max(360, math.floor(ww * Theme.landH / Theme.landW))
      love.window.setMode(ww, wh, flags)
    end
  end
  Layout.updateViewport()
end

function Layout.flush()
  if not Layout.pendingWindow then return end
  Layout.pendingWindow = false
  Layout.applyWindow()
end

function Layout.toggleFullscreen()
  Layout.fullscreen = not Layout.fullscreen
  Layout.pendingWindow = true
  Layout.save()
end

function Layout.toggleCompact()
  Layout.compact = not Layout.compact
  Layout.save()
end

-- How far the virtual viewport may stretch past its design size to fill the
-- display. Keeps ultrawide panels from smearing the layout across the screen.
local MAX_STRETCH = 1.6

local function baseSize()
  if Layout.mode == "portrait" then return Theme.portW, Theme.portH end
  return Theme.landW, Theme.landH
end

function Layout.ensureCanvas()
  local w, h = math.floor(Layout.vw), math.floor(Layout.vh)
  if Layout.canvas and Layout.canvas:getWidth() == w and Layout.canvas:getHeight() == h then
    return
  end
  if Layout.canvas then Layout.canvas:release() end
  Layout.canvas = love.graphics.newCanvas(w, h)
  Layout.canvas:setFilter("nearest", "nearest")
end

-- Pick the pixel scale and the virtual resolution that together cover as much
-- of the window as possible. Above 2x we snap the scale to an integer (crisp
-- pixels) and hand the leftover room back to the layout as extra virtual
-- pixels, rather than letterboxing it away. Compact drops the stretch cap so
-- the map owns the whole window.
--- Which orientation a window of this shape wants. Used only when the
--- operator has never said: a preference, once given, is theirs.
function Layout.orientationFor(ww, wh)
  return wh > ww and "portrait" or "landscape"
end

--- The scale and virtual size for a window, given the base size. Pure, so
--- the arithmetic that decides how much of the screen is used can be
--- checked without a window.
---
--- The last branch used to hand back the base size unchanged, which
--- letterboxed away everything left over: a 640x360 canvas in a tall
--- window filled a band across the middle and left the rest black. It now
--- stretches like the branch above it — up to `MAX_STRETCH`, so a layout
--- is never asked to fill a shape it was not designed for — and never
--- shrinks below the base.
function Layout.viewport(ww, wh, bw, bh, compact)
  local s = math.min(ww / bw, wh / bh)
  if compact and s >= 1 then
    local scale = math.max(1, math.floor(s))
    return scale, math.floor(ww / scale), math.floor(wh / scale)
  end
  local scale = s >= 2 and math.floor(s) or math.max(0.5, s)
  local vw = math.min(math.floor(ww / scale), math.floor(bw * MAX_STRETCH))
  local vh = math.min(math.floor(wh / scale), math.floor(bh * MAX_STRETCH))
  return scale, math.max(bw, vw), math.max(bh, vh)
end

function Layout.updateViewport()
  local ww, wh = love.graphics.getDimensions()
  local bw, bh = baseSize()
  Layout.scale, Layout.vw, Layout.vh = Layout.viewport(ww, wh, bw, bh, Layout.compact)
  Layout.ox = math.floor((ww - Layout.vw * Layout.scale) / 2)
  Layout.oy = math.floor((wh - Layout.vh * Layout.scale) / 2)
  Layout.ensureCanvas()
end

function Layout.init()
  -- A saved preference wins. With none — a first run — the orientation is
  -- taken from the window's own shape, because a landscape canvas on a
  -- portrait screen is a band across the middle with black above and below
  -- it, and nobody's first impression of this should be that.
  if not Layout.load() then
    local ww, wh = love.graphics.getDimensions()
    Layout.mode = Layout.orientationFor(ww, wh)
  end
  Layout.updateViewport()
  Layout.applyWindow()
end

function Layout.toggleOrientation()
  Layout.mode = Layout.mode == "landscape" and "portrait" or "landscape"
  Layout.pendingWindow = true
  Layout.save()
end

function Layout.begin()
  Layout.updateViewport()
  love.graphics.setCanvas(Layout.canvas)
  love.graphics.clear(Theme.void)
end

function Layout.finish()
  love.graphics.setCanvas()
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setDefaultFilter("nearest", "nearest")
  love.graphics.clear(4 / 255, 6 / 255, 12 / 255, 1)
  local dw = Layout.vw * Layout.scale
  local dh = Layout.vh * Layout.scale
  love.graphics.draw(Layout.canvas, Layout.ox, Layout.oy, 0, Layout.scale, Layout.scale)
  if Layout.compact then return end
  -- CRT bezel ticks in the letterbox
  love.graphics.setColor(Theme.gold[1], Theme.gold[2], Theme.gold[3], 0.55)
  love.graphics.rectangle("line", Layout.ox - 1, Layout.oy - 1, dw + 2, dh + 2)
  love.graphics.setColor(Theme.cyan[1], Theme.cyan[2], Theme.cyan[3], 0.25)
  local t = 6
  love.graphics.rectangle("fill", Layout.ox, Layout.oy, t, 1)
  love.graphics.rectangle("fill", Layout.ox, Layout.oy, 1, t)
  love.graphics.rectangle("fill", Layout.ox + dw - t, Layout.oy, t, 1)
  love.graphics.rectangle("fill", Layout.ox + dw - 1, Layout.oy, 1, t)
  love.graphics.rectangle("fill", Layout.ox, Layout.oy + dh - 1, t, 1)
  love.graphics.rectangle("fill", Layout.ox, Layout.oy + dh - t, 1, t)
  love.graphics.rectangle("fill", Layout.ox + dw - t, Layout.oy + dh - 1, t, 1)
  love.graphics.rectangle("fill", Layout.ox + dw - 1, Layout.oy + dh - t, 1, t)
end

function Layout.toVirtual(sx, sy)
  local vx = (sx - Layout.ox) / Layout.scale
  local vy = (sy - Layout.oy) / Layout.scale
  if vx < 0 or vy < 0 or vx >= Layout.vw or vy >= Layout.vh then
    return nil, nil
  end
  return vx, vy
end

function Layout.hit(x, y, w, h)
  local mx, my = love.mouse.getPosition()
  local vx, vy = Layout.toVirtual(mx, my)
  if not vx then return false end
  return vx >= x and vy >= y and vx < x + w and vy < y + h
end

function Layout.mouse()
  return Layout.toVirtual(love.mouse.getPosition())
end

function Layout.isPortrait()
  return Layout.mode == "portrait"
end

return Layout
