--- The backgrounds.
---
--- Grok paints five plates at 1280x720 (`make art`); this crushes them to the
--- sixteen colours of whichever palette is current and keeps the result in a
--- canvas, so the cost is paid once at load and once more when the palette
--- changes. They are 10% wider than the screen, which is the room the parallax
--- pans them in.
---
--- No plates on disk is a supported state, not a failure: `procedural` draws
--- Hradčany out of rectangles instead, and the client never mentions it.

local palette = require("src.palette")
local shaders = require("src.shaders")

local M = {}

-- The baked size: the canvas plus a margin, which is the room the parallax
-- pans a plate in. `M.size` recomputes it when the screen is turned.
M.W, M.H = 528, 300
M.SCREEN_W, M.SCREEN_H = 480, 270
M.PAN = 24

--- Each plate says how it wants to be graded, because the same sixteen
--- colours have to serve a candlelit library and a storm over a castle.
M.plates = {
  ["medieval-prague"] = {
    file = "assets/bg/medieval-prague.jpg",
    title = "OLD TOWN - THE FOURTEENTH CENTURY",
    grade = { contrast = 1.12, saturation = 1.18, brightness = 0.02,
              tint = { 0.10, 0.12, 0.26 }, tint_amount = 0.14 },
    embers = { ramp = "fire", rate = 5 },
    night = 0.30,
  },
  ["golden-lane"] = {
    file = "assets/bg/golden-lane.jpg",
    title = "GOLDEN LANE - THE ALCHEMISTS",
    grade = { contrast = 1.14, saturation = 1.22, brightness = 0.02,
              tint = { 0.14, 0.11, 0.22 }, tint_amount = 0.12 },
    embers = { ramp = "fire", rate = 7 },
    night = 0.26,
  },
  klementinum = {
    file = "assets/bg/klementinum.jpg",
    title = "KLEMENTINUM - BAROQUE HALL",
    grade = { contrast = 1.14, saturation = 1.24, brightness = 0.03,
              tint = { 0.22, 0.13, 0.05 }, tint_amount = 0.08 },
    embers = { ramp = "fire", rate = 6 },
    night = 0.22,
  },
  ["prague-castle"] = {
    file = "assets/bg/prague-castle.jpg",
    title = "HRADCANY - ACROSS THE VLTAVA",
    grade = { contrast = 1.12, saturation = 1.14, brightness = 0.02,
              tint = { 0.08, 0.10, 0.28 }, tint_amount = 0.16 },
    embers = { ramp = "arcane", rate = 2 },
    storm = true,
    night = 0.30,
  },
  ["astronomical-tower"] = {
    file = "assets/bg/astronomical-tower.jpg",
    title = "KLEMENTINUM - ASTRONOMICAL TOWER",
    grade = { contrast = 1.10, saturation = 1.12, brightness = 0.03,
              tint = { 0.14, 0.14, 0.24 }, tint_amount = 0.10 },
    embers = { ramp = "holy", rate = 3 },
    night = 0.26,
  },
  ["charles-bridge"] = {
    file = "assets/bg/charles-bridge.jpg",
    title = "CHARLES BRIDGE - BEFORE DAWN",
    grade = { contrast = 1.10, saturation = 1.05, brightness = 0.04,
              tint = { 0.16, 0.18, 0.26 }, tint_amount = 0.20 },
    embers = { ramp = "steel", rate = 4 },
    night = 0.18,
  },
  forge = {
    file = "assets/bg/forge.jpg",
    title = "THE ARMOURER - PREPARING HIM",
    grade = { contrast = 1.16, saturation = 1.30, brightness = 0.04,
              tint = { 0.24, 0.12, 0.04 }, tint_amount = 0.10 },
    embers = { ramp = "fire", rate = 12 },
    night = 0.18,
  },
  awakening = {
    file = "assets/bg/awakening.jpg",
    title = "THE HARNESS - GOING ON",
    grade = { contrast = 1.18, saturation = 1.28, brightness = 0.03,
              tint = { 0.14, 0.14, 0.24 }, tint_amount = 0.10 },
    embers = { ramp = "holy", rate = 10 },
    night = 0.20,
  },
  cartridge = {
    file = "assets/bg/cartridge.jpg",
    title = "THE CARTRIDGE",
    grade = { contrast = 1.18, saturation = 1.30, brightness = 0.02,
              tint = { 0.22, 0.14, 0.04 }, tint_amount = 0.10 },
    embers = { ramp = "fire", rate = 8 },
    night = 0.20,
  },
}

M.order = {
  "medieval-prague", "golden-lane", "klementinum", "prague-castle",
  "astronomical-tower", "charles-bridge", "forge", "awakening", "cartridge",
}

-- ------------------------------------------------------ the drawn stand-in --

--- Hradčany, from primitives. Deterministic: the same skyline every launch.
local function procedural(width, height)
  local rng = love.math.newRandomGenerator(0xC0FFEE)
  local horizon = height * 0.66

  -- Sky, in bands, because a gradient is not a thing this palette has.
  local sky = { "black", "navy", "navy", "blue", "navy", "black" }
  local bands = 14
  for i = 0, bands - 1 do
    local slot = sky[math.min(#sky, math.floor(i / bands * #sky) + 1)]
    palette.set(slot, 1)
    love.graphics.rectangle("fill", 0, i * horizon / bands, width, horizon / bands + 1)
  end

  for _ = 1, 150 do
    local x, y = rng:random(0, width), rng:random(0, horizon - 20)
    palette.set(rng:random() < 0.2 and "white" or "silver", 1)
    love.graphics.rectangle("fill", x, y, 1, 1)
  end

  -- The moon, and a ring around it. Everything here is composed for the left
  -- third of the plate: that is the column the chat scene leaves uncovered,
  -- and a skyline centred on the canvas would sit entirely behind the
  -- transcript.
  palette.set("silver", 1)
  love.graphics.circle("fill", width * 0.22, height * 0.15, 13)
  palette.set("navy", 1)
  love.graphics.circle("fill", width * 0.24, height * 0.14, 11)
  palette.set("white", 1)
  love.graphics.circle("line", width * 0.22, height * 0.15, 17)

  -- The castle: a long block with the cathedral rising out of the middle of
  -- it, then towers falling away down the hill on both sides.
  local function tower(x, base, w, h, spire)
    palette.set("black", 1)
    love.graphics.rectangle("fill", x, base - h, w, h)
    if spire then
      love.graphics.polygon("fill", x - 1, base - h, x + w + 1, base - h, x + w / 2, base - h - spire)
      palette.set("gold", 1)
      love.graphics.rectangle("fill", x + w / 2, base - h - spire - 4, 1, 4)
    end
    -- Lit windows.
    palette.set("gold", 1)
    for wy = base - h + 6, base - 6, 7 do
      for wx = x + 2, x + w - 3, 5 do
        if rng:random() < 0.45 then love.graphics.rectangle("fill", wx, wy, 2, 3) end
      end
    end
  end

  palette.set("black", 1)
  love.graphics.rectangle("fill", 0, horizon, width, height - horizon)
  love.graphics.polygon("fill", 0, horizon - 12, width * 0.16, horizon - 28,
    width * 0.44, horizon - 24, width, horizon + 8, width, height, 0, height)

  local base = horizon - 4
  tower(width * 0.05, base, 26, 30)
  tower(width * 0.12, base - 4, 60, 40)
  tower(width * 0.25, base - 6, 16, 62, 26)   -- the cathedral, twice
  tower(width * 0.29, base - 6, 16, 66, 30)
  tower(width * 0.34, base - 4, 54, 42)
  tower(width * 0.48, base, 22, 28, 14)

  -- The river, and the castle upside down in it.
  palette.set("navy", 1)
  love.graphics.rectangle("fill", 0, height * 0.86, width, height * 0.14)
  palette.set("blue", 0.5)
  for y = height * 0.86, height, 3 do
    love.graphics.rectangle("fill", rng:random(0, width * 0.4), y, rng:random(20, 90), 1)
  end
  palette.set("gold", 0.35)
  for _ = 1, 26 do
    local x = rng:random(width * 0.05, width * 0.5)
    love.graphics.rectangle("fill", x, rng:random(height * 0.87, height), rng:random(1, 3), 1)
  end
end

-- ----------------------------------------------------------------- baking --

local baked = {}

local function bake(name)
  local plate = M.plates[name]
  local canvas = love.graphics.newCanvas(M.W, M.H)
  canvas:setFilter("nearest", "nearest")

  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 1)
  love.graphics.setColor(1, 1, 1, 1)

  if plate.image then
    shaders.grade(plate.grade)
    love.graphics.setShader(shaders.quantize)
    local iw, ih = plate.image:getDimensions()
    local scale = math.max(M.W / iw, M.H / ih)
    love.graphics.draw(plate.image, (M.W - iw * scale) / 2, (M.H - ih * scale) / 2, 0, scale, scale)
    love.graphics.setShader()
  else
    procedural(M.W, M.H)
  end

  love.graphics.setCanvas()
  love.graphics.setColor(1, 1, 1, 1)
  baked[name] = canvas
end

--- The baked size for a canvas of this size, without re-baking.
function M.size(width, height)
  M.SCREEN_W, M.SCREEN_H = width, height
  M.PAN = math.floor(math.min(width, height) * 0.09)
  M.W = width + M.PAN * 2
  M.H = height + M.PAN
end

--- Re-bake every plate for a canvas of this size. Called when the screen is
--- turned: a plate baked for a wide screen is the wrong crop for a tall one,
--- and scaling the baked canvas instead would put half a pixel everywhere.
function M.resize(width, height)
  if width == M.SCREEN_W and height == M.SCREEN_H then return false end
  M.size(width, height)
  M.rebake()
  return true
end

--- Load whatever plates are on disk. Missing ones fall through to the drawn
--- skyline, which is why this never fails.
function M.load(width, height)
  if width and height then M.size(width, height) end
  M.painted = 0
  for name, plate in pairs(M.plates) do
    if love.filesystem.getInfo(plate.file) then
      local ok, image = pcall(love.graphics.newImage, plate.file)
      if ok then
        image:setFilter("linear", "linear")
        plate.image = image
        M.painted = M.painted + 1
      end
    end
  end
  M.rebake()
  return M
end

--- Re-quantise every plate. Called when the palette changes.
function M.rebake()
  for name in pairs(M.plates) do bake(name) end
end

function M.has(name) return baked[name] ~= nil end

function M.title(name)
  local plate = M.plates[name]
  if not plate then return "" end
  return plate.title .. (plate.image and "" or " - DRAWN")
end

function M.plate(name) return M.plates[name] end

--- Draw a plate, panned by `px`/`py` in -1..1 and dimmed by `dim`.
function M.draw(name, px, py, dim)
  local canvas = baked[name]
  if not canvas then return end
  local x = -(M.W - M.SCREEN_W) / 2 + (px or 0) * M.PAN
  local y = -(M.H - M.SCREEN_H) / 2 + (py or 0) * (M.PAN / 2)
  local shade = 1 - (dim or 0)
  love.graphics.setColor(shade, shade, shade, 1)
  love.graphics.draw(canvas, math.floor(x), math.floor(y))
  love.graphics.setColor(1, 1, 1, 1)
end

return M
