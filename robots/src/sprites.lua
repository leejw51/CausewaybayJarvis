local Sprites = { img = {}, q = {}, box = {} }

local function knockout(data)
  local w, h = data:getWidth(), data:getHeight()
  local function isBg(x, y)
    local r, g, b, a = data:getPixel(x, y)
    if a < 0.16 then return true end
    if r > 0.66 and b > 0.66 and g < 0.40 then return true end
    local lum = 0.299 * r + 0.587 * g + 0.114 * b
    return lum < 0.11
  end

  local seen = {}
  local qx, qy = {}, {}
  local n, i = 0, 1
  local function push(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return end
    local k = y * w + x
    if seen[k] then return end
    if not isBg(x, y) then return end
    seen[k] = true
    n = n + 1
    qx[n], qy[n] = x, y
  end

  for x = 0, w - 1, 2 do
    push(x, 0)
    push(x, h - 1)
  end
  for y = 0, h - 1, 2 do
    push(0, y)
    push(w - 1, y)
  end

  while i <= n do
    local x, y = qx[i], qy[i]
    i = i + 1
    data:setPixel(x, y, 0, 0, 0, 0)
    push(x + 1, y)
    push(x - 1, y)
    push(x, y + 1)
    push(x, y - 1)
  end
end

local function measureBox(data)
  local w, h = data:getWidth(), data:getHeight()
  local minx, miny, maxx, maxy = w, h, 0, 0
  local found = false
  for y = 0, h - 1, 2 do
    for x = 0, w - 1, 2 do
      local _, _, _, a = data:getPixel(x, y)
      if a > 0.12 then
        found = true
        if x < minx then minx = x end
        if y < miny then miny = y end
        if x > maxx then maxx = x end
        if y > maxy then maxy = y end
      end
    end
  end
  if not found then
    return { cx = w * 0.5, feet = h * 0.92, h = h * 0.72,
             head = { cx = w * 0.5, top = h * 0.2, side = h * 0.3 } }
  end
  local bh = math.max(8, maxy - miny + 1)

  -- The head, measured rather than assumed. Every robot in the catalog is a
  -- different silhouette -- some are top-heavy, some are all shoulders -- and
  -- a fixed fraction of the sprite crops one of them through the visor. So the
  -- top band of the *opaque* box is measured for its own width and centre,
  -- which is what face mode and the page header frame on.
  -- Narrow on purpose. Measured over a third of the body the band catches the
  -- shoulders, and a robot with big pauldrons then centres on its armour
  -- rather than on its face. The top sixth is head and nothing else.
  local HEAD_BAND = 0.16
  local hminx, hmaxx = w, 0
  local bandBottom = miny + bh * HEAD_BAND
  for y = miny, math.min(h - 1, math.floor(bandBottom)), 2 do
    for x = 0, w - 1, 2 do
      local _, _, _, a = data:getPixel(x, y)
      if a > 0.12 then
        if x < hminx then hminx = x end
        if x > hmaxx then hmaxx = x end
      end
    end
  end
  if hmaxx < hminx then hminx, hmaxx = minx, maxx end

  return {
    cx = (minx + maxx) * 0.5,
    feet = maxy,
    h = bh,
    minx = minx, miny = miny, maxx = maxx, maxy = maxy,
    head = {
      cx = (hminx + hmaxx) * 0.5,
      top = miny,
      -- Square, and at least a third of the body: wide enough that a small
      -- head is a portrait rather than a close-up on a visor.
      side = math.max(bh * 0.30, (hmaxx - hminx + 1) * 1.1),
    },
  }
end

Sprites.data = {}

local AGENT_KEYS = {}

local function rgbToHsv(r, g, b)
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local d = maxc - minc
  local h = 0
  if d > 0.001 then
    if maxc == r then h = ((g - b) / d) % 6
    elseif maxc == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
    if h < 0 then h = h + 1 end
  end
  local s = maxc > 0.001 and (d / maxc) or 0
  return h, s, maxc
end

local function hsvToRgb(h, s, v)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then return v, t, p end
  if i == 1 then return q, v, p end
  if i == 2 then return p, v, t end
  if i == 3 then return p, q, v end
  if i == 4 then return t, p, v end
  return v, p, q
end

local function hueShift(data, shift)
  if not shift or shift == 0 then return data end
  local w, h = data:getWidth(), data:getHeight()
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r, g, b, a = data:getPixel(x, y)
      if a > 0.12 then
        local hh, ss, vv = rgbToHsv(r, g, b)
        if ss > 0.12 then
          hh = (hh + shift) % 1
          r, g, b = hsvToRgb(hh, ss, vv)
          data:setPixel(x, y, r, g, b, a)
        end
      end
    end
  end
  return data
end

local function loadImg(key, path, punch)
  if not love.filesystem.getInfo(path) then return end
  local measure = punch or AGENT_KEYS[key]
  if measure then
    local data = love.image.newImageData(path)
    if not punch and AGENT_KEYS[key] then
      local w, h = data:getWidth(), data:getHeight()
      local _, _, _, a0 = data:getPixel(0, 0)
      local _, _, _, a1 = data:getPixel(w - 1, 0)
      local _, _, _, a2 = data:getPixel(0, h - 1)
      punch = a0 > 0.9 and a1 > 0.9 and a2 > 0.9
    end
    if punch then knockout(data) end
    local img = love.graphics.newImage(data)
    img:setFilter("nearest", "nearest")
    Sprites.img[key] = img
    Sprites.box[key] = measureBox(data)
    Sprites.data[key] = data
  else
    local img = love.graphics.newImage(path)
    img:setFilter("nearest", "nearest")
    Sprites.img[key] = img
  end
end

-- Palette-swap a loaded agent (and its fly pose, if any) into a new key.
-- Session boots only derive the four on-duty looks, so a 100-model catalog
-- does not pay for 100 copies of a 1024px sheet.
function Sprites.derive(dst, src, hue)
  if not src or not dst or dst == src then return end
  if Sprites.img[dst] then return end
  local function one(from, to)
    if Sprites.img[to] then return end
    local data = Sprites.data[from]
    if not data then return end
    local sw, sh = data:getWidth(), data:getHeight()
    local tw, th = 256, 256
    local copy = love.image.newImageData(tw, th)
    for y = 0, th - 1 do
      for x = 0, tw - 1 do
        local r, g, b, a = data:getPixel(
          math.min(sw - 1, math.floor(x * sw / tw)),
          math.min(sh - 1, math.floor(y * sh / th)))
        copy:setPixel(x, y, r, g, b, a)
      end
    end
    hueShift(copy, hue)
    local img = love.graphics.newImage(copy)
    img:setFilter("nearest", "nearest")
    Sprites.img[to] = img
    local box = Sprites.box[from]
    if box then
      local sx, sy = tw / sw, th / sh
      local scaled = { cx = box.cx * sx, feet = box.feet * sy, h = box.h * sy }
      if box.head then
        scaled.head = {
          cx = box.head.cx * sx,
          top = box.head.top * sy,
          side = box.head.side * math.min(sx, sy),
        }
      end
      Sprites.box[to] = scaled
    else
      Sprites.box[to] = Sprites.box[from]
    end
    Sprites.data[to] = copy
  end
  one(src, dst)
  one(src .. "Fly", dst .. "Fly")
end

function Sprites.prepare(list)
  for _, a in ipairs(list or {}) do
    if a.hue and a.hue ~= 0 and a.key and a.base and a.key ~= a.base then
      Sprites.derive(a.key, a.base, a.hue)
    end
  end
end

-- Load standing + fly sheets for the session pool only (10 types => 20 images).
function Sprites.loadAgents(list)
  for _, a in ipairs(list or {}) do
    local key = a.base or a.key
    if key then
      AGENT_KEYS[key] = true
      AGENT_KEYS[key .. "Fly"] = true
      if not Sprites.img[key] then
        loadImg(key, "assets/agent_" .. key .. ".png", false)
      end
      if not Sprites.img[key .. "Fly"] then
        loadImg(key .. "Fly", "assets/agent_" .. key .. "_fly.png", false)
      end
    end
  end
end

function Sprites.load()
  loadImg("hangar", "assets/bg_hangar.png")
  loadImg("hangarP", "assets/bg_hangar_portrait.png")
  loadImg("emblem", "assets/emblem_jarvis.png", true)
  -- The Jarvis sprite is loaded again here under its own key, measured, so
  -- the boot screen can cut it into pieces even when the session pool did
  -- not roll Jarvis. It is the one sprite every boot screen shows.
  AGENT_KEYS.jarvis = true
  AGENT_KEYS.jarvisFly = true
  loadImg("jarvis", "assets/agent_jarvis.png", false)
  loadImg("bays", "assets/sheet_suit_bays.png")
  loadImg("idle", "assets/sheet_jarvis_idle.png")
  loadImg("power", "assets/sheet_powerup.png")
  loadImg("corners", "assets/ui_corners.png")
  loadImg("icons", "assets/sheet_ui_icons.png")

  local idle = Sprites.img.idle
  if idle then
    local iw, ih = idle:getWidth(), idle:getHeight()
    local cw, ch = math.floor(iw / 2), math.floor(ih / 2)
    Sprites.q.idle = {}
    for row = 0, 1 do
      for col = 0, 1 do
        Sprites.q.idle[#Sprites.q.idle + 1] =
          love.graphics.newQuad(col * cw, row * ch, cw, ch, iw, ih)
      end
    end
  end

  local power = Sprites.img.power
  if power then
    local iw, ih = power:getWidth(), power:getHeight()
    local cw, ch = math.floor(iw / 2), math.floor(ih / 2)
    Sprites.q.power = {}
    for row = 0, 1 do
      for col = 0, 1 do
        Sprites.q.power[#Sprites.q.power + 1] =
          love.graphics.newQuad(col * cw, row * ch, cw, ch, iw, ih)
      end
    end
  end
end

function Sprites.drawCover(img, x, y, w, h, alpha)
  if not img then return end
  alpha = alpha or 1
  local iw, ih = img:getWidth(), img:getHeight()
  local s = math.max(w / iw, h / ih)
  local dw, dh = iw * s, ih * s
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.draw(img, x + (w - dw) / 2, y + (h - dh) / 2, 0, s, s)
end

function Sprites.drawFit(img, x, y, w, h, alpha)
  if not img then return end
  alpha = alpha or 1
  local iw, ih = img:getWidth(), img:getHeight()
  local s = math.min(w / iw, h / ih)
  local dw, dh = iw * s, ih * s
  love.graphics.setColor(1, 1, 1, alpha)
  love.graphics.draw(img, x + (w - dw) / 2, y + (h - dh) / 2, 0, s, s)
end

function Sprites.agent(key, flying)
  local base = (key or "jarvis"):gsub("_c%d+$", "")
  if flying then
    return Sprites.img[key .. "Fly"]
      or Sprites.img[base .. "Fly"]
      or Sprites.img[key]
      or Sprites.img[base]
  end
  return Sprites.img[key]
    or Sprites.img[base]
    or Sprites.img[key .. "Fly"]
    or Sprites.img[base .. "Fly"]
end

-- Origin at the sprite's actual feet (opaque bbox bottom).
-- `height` is world pixels. A floor slab is 32px; agents stand ~22px tall.
function Sprites.drawAgent(key, wx, wy, opts)
  opts = opts or {}
  local flying = opts.flying
  local base = (key or "jarvis"):gsub("_c%d+$", "")
  local boxKey = flying and (key .. "Fly") or key
  local img = Sprites.img[boxKey]
    or (flying and Sprites.img[base .. "Fly"])
    or Sprites.agent(key, flying)
  if not img then return end
  local box = Sprites.box[boxKey] or Sprites.box[base .. (flying and "Fly" or "")] or Sprites.box[base] or Sprites.box[key]
  local iw, ih = img:getWidth(), img:getHeight()
  local bh = box and box.h or (ih * 0.82)
  local ox = box and box.cx or (iw * 0.5)
  local oy = box and box.feet or (ih * 0.90)
  local target = opts.height or 22
  local s = target / bh
  local t = opts.t or 0
  local id = opts.id or 1
  local bob = math.sin(t * 2.8 + id * 1.7) * (flying and 0.8 or 1.2)
  local rot = 0.03 * math.sin(t * 1.6 + id)
  if flying then
    local vx, vy = opts.vx or 0, opts.vy or 0
    rot = math.max(-0.35, math.min(0.35, vx * 0.0008)) - 0.16
    if vy > 20 then rot = rot + 0.08 end
  end
  local x, y = wx, wy + bob
  if flying and ((opts.vx or 0) ^ 2 + (opts.vy or 0) ^ 2) > 400 then
    local vx, vy = opts.vx, opts.vy
    local sp = math.sqrt(vx * vx + vy * vy)
    for g = 3, 1, -1 do
      local k = g * 4
      love.graphics.setColor(1, 1, 1, 0.10 * g)
      love.graphics.draw(img, x - vx / sp * k, y - vy / sp * k, rot, s, s, ox, oy)
    end
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(img, x, y, rot, s, s, ox, oy)
end


-- Just the head, blown up into a box: what face mode and the page header draw.
--
-- The sprites are whole robots at 256x256 with a lot of empty air, so the crop
-- is taken from the *opaque* bounding box rather than from the image: the top
-- half of what is actually drawn, squared off around the sprite's own centre
-- line. Without that, a tall robot and a squat one come out at different sizes
-- and neither is centred.
function Sprites.head(key)
  local img = Sprites.agent(key, false)
  if not img then return nil end
  local base = (key or "jarvis"):gsub("_c%d+$", "")
  local box = Sprites.box[key] or Sprites.box[base]
  local iw, ih = img:getWidth(), img:getHeight()
  if not box or not box.head then
    return img, 0, 0, iw, ih * 0.5
  end
  -- A little air around the measured band, so the crop is a portrait and not
  -- a passport photo.
  local side = math.max(8, math.min(iw, ih, box.head.side * 1.15))
  local x = math.max(0, math.min(iw - side, box.head.cx - side * 0.5))
  local y = math.max(0, math.min(ih - side, box.head.top - side * 0.10))
  return img, x, y, side, side
end

--- Draw that head to fill `size` pixels at `x, y`.
function Sprites.drawHead(key, x, y, size, alpha)
  local img, sx, sy, sw, sh = Sprites.head(key)
  if not img then return false end
  local scale = size / math.max(sw, sh)
  local quad = love.graphics.newQuad(sx, sy, sw, sh, img:getWidth(), img:getHeight())
  love.graphics.setColor(1, 1, 1, alpha or 1)
  love.graphics.draw(img, quad, x, y, 0, scale, scale)
  return true
end

return Sprites
