-- Side-view 100-floor tower. Rooftop in the clouds. Genesis 8-bit.
local Theme = require("src.theme")
local Tween = require("src.tween")
local Font = require("src.font")
local Layout = require("src.layout")

local JOBS = {
  "ARCHIVE", "SHOP", "CAFE", "CLINIC", "GARAGE", "LEDGER",
  "RELAY", "STUDIO", "WAREHOUSE", "KITCHEN", "WATCH", "DOCK",
}

local World = {
  FLOORS = 100,
  FLOOR_H = 32,
  TILE = 32,
  BX = 216,
  BW = 288,
  SKY = 200,
  cam = { x = 360, y = 200, zoom = 1.0 },
  hangarX = 360,
  hangarY = 200,
  neons = {},
  labels = {},
  districts = {},
  houses = {},
  floors = {},
  img = true,
  ready = false,
  t = 0,
  chase = nil,
  rush = 0,
  width = 720,
  height = 4500,
  size = 4500,
  sky = nil,
  tiles = nil,
}

function World.floorY(n)
  n = math.max(1, math.min(World.FLOORS, n))
  return World.SKY + (World.FLOORS - n + 1) * World.FLOOR_H
end

function World.standY(n)
  -- Slab is drawn at floorY-4. Feet sit just above it.
  return World.floorY(n) - 6
end

function World.flatX()
  return World.hangarX
end

function World.randInFlat(floor)
  floor = math.max(1, math.min(World.FLOORS, floor or love.math.random(World.FLOORS)))
  local x = World.BX + 36 + love.math.random() * (World.BW - 72)
  return x, World.standY(floor), floor
end

function World.floorAtY(y)
  local n = World.FLOORS - math.floor((y - World.SKY) / World.FLOOR_H) + 1
  return math.max(1, math.min(World.FLOORS, n))
end

function World.insideX(x)
  return x > World.BX + 8 and x < World.BX + World.BW - 8
end

function World.exitX(x)
  local mid = World.BX + World.BW * 0.5
  if x < mid then return World.BX - 36 end
  return World.BX + World.BW + 36
end

-- Roof formation pitch. An agent draws 22px tall with its origin at the feet,
-- and fires a rocket plume from just below them, so the vertical pitch has to
-- clear the body AND leave air underneath or the boost is hidden behind the
-- unit standing in the next row down.
local FORM_GAP_X_MIN, FORM_GAP_X_MAX = 20, 28
local FORM_GAP_Y_MIN, FORM_GAP_Y_MAX = 34, 42

function World.roofGrid(i, n)
  n = math.max(1, n or World.FLOORS)
  local cols = math.min(24, math.max(1, math.ceil(math.sqrt(n))))
  local gapX = cols <= 1 and 0
    or math.max(FORM_GAP_X_MIN, math.min(FORM_GAP_X_MAX, (World.BW - 16) / (cols - 1)))
  local rows = math.max(1, math.ceil(n / cols))
  local gapY = math.max(FORM_GAP_Y_MIN, math.min(FORM_GAP_Y_MAX, 200 / rows))
  -- High floors sit just above the deck; lower floors stack into the sky.
  local idx = n - math.max(1, math.min(n, i or 1))
  local row = math.floor(idx / cols)
  local col = idx % cols
  local x = World.hangarX - (cols - 1) * 0.5 * gapX + col * gapX
  local y = World.SKY - 28 - row * gapY
  return x, y
end

function World.roofSlot(slot)
  return World.roofGrid(slot, World.FLOORS)
end

function World.alignSlot(floor, slot, count)
  slot = slot or 1
  if not floor or floor >= World.FLOORS then
    return World.roofSlot(slot)
  end
  local y = World.floorY(floor)
  local x = World.BX + 48 + ((slot - 1) % 5) * 44
  return x, y
end

function World.snapRoad(x, y)
  local n = World.floorAtY(y or World.SKY)
  local fy = (y and y < World.SKY + 8) and World.SKY or World.floorY(n)
  local x0 = World.BX + 24
  local x1 = World.BX + World.BW - 24
  local nx = math.max(x0, math.min(x1, x or World.hangarX))
  return nx, fy
end

function World.pickHouse(x, y)
  local n = World.floorAtY(y or World.cam.y)
  return World.floors[n] or World.houses[1]
end

function World.pickFloor(n)
  return World.floors[n or love.math.random(World.FLOORS)]
end

local function isKey(r, g, b, a)
  if (a or 1) < 0.12 then return true end
  return r > 0.62 and b > 0.62 and g < 0.48
end

local function loadArt()
  if not World.sky then
    local skyPath = "assets/bg/bg_prague.png"
    if not love.filesystem.getInfo(skyPath) then
      skyPath = "assets/bg/bg_tower_sky.png"
    end
    if love.filesystem.getInfo(skyPath) then
      World.sky = love.graphics.newImage(skyPath)
      World.sky:setFilter("nearest", "nearest")
    end
  end
  if World.tiles then return end
  local path = "assets/kit/tile_tower.png"
  if not love.filesystem.getInfo(path) then return end
  local data = love.image.newImageData(path)
  local w, h = data:getWidth(), data:getHeight()
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r, g, b, a = data:getPixel(x, y)
      if isKey(r, g, b, a) then data:setPixel(x, y, 0, 0, 0, 0) end
    end
  end
  local cols, rows = 4, 3
  local tw, th = World.TILE, World.TILE
  local cw = math.floor(w / cols)
  local ch = math.floor(h / rows)
  local atlas = love.image.newImageData(cols * tw, rows * th)
  local quads = {}
  local n = 0
  for r = 1, rows do
    for c = 1, cols do
      n = n + 1
      local px, py = (c - 1) * cw, (r - 1) * ch
      -- nearest-neighbor into 32x32
      for j = 0, th - 1 do
        local sy = py + math.min(ch - 1, math.floor(j * ch / th))
        for i = 0, tw - 1 do
          local sx = px + math.min(cw - 1, math.floor(i * cw / tw))
          atlas:setPixel((c - 1) * tw + i, (r - 1) * th + j, data:getPixel(sx, sy))
        end
      end
      quads[n] = love.graphics.newQuad((c - 1) * tw, (r - 1) * th, tw, th, cols * tw, rows * th)
    end
  end
  local img = love.graphics.newImage(atlas)
  img:setFilter("nearest", "nearest")
  World.tiles = { img = img, q = quads }
end

function World.build(floors)
  if floors then
    World.FLOORS = math.max(1, math.min(1000, math.floor(floors)))
  end
  World.floors = {}
  World.houses = {}
  World.neons = {}
  World.labels = {}
  World.districts = {}
  World.SKY = 200
  World.height = World.SKY + World.FLOORS * World.FLOOR_H + 80
  World.width = 720
  World.size = World.height
  World.hangarX = World.BX + World.BW * 0.5
  World.hangarY = World.SKY

  for n = 1, World.FLOORS do
    local y = World.floorY(n)
    local job = JOBS[((n - 1) % #JOBS) + 1]
    local fl = {
      id = n,
      floor = n,
      name = string.format("F%03d", n),
      job = job,
      x = World.hangarX,
      y = y,
      doorX = (n % 2 == 0) and (World.BX - 8) or (World.BX + World.BW + 8),
      doorY = y,
    }
    World.floors[n] = fl
    World.houses[n] = fl
  end

  local top = World.FLOORS
  local mid = math.max(1, math.floor(top * 0.5))
  World.labels = {
    { string.format("F%03d", 1), World.hangarX, World.floorY(1) - 10, Theme.amber },
  }
  if top >= 10 then
    World.labels[#World.labels + 1] = { string.format("F%03d", mid), World.hangarX, World.floorY(mid) - 10, Theme.magenta }
  end
  if top >= 3 then
    World.labels[#World.labels + 1] = { string.format("F%03d", top), World.hangarX, World.floorY(top) - 10, Theme.gold }
  end

  local function fl(n)
    return math.max(1, math.min(World.FLOORS, n))
  end
  World.districts = {
    { name = "ROOF", x = World.hangarX, y = World.SKY, r = 80 },
    { name = "HIGH", x = World.hangarX, y = World.floorY(fl(math.floor(top * 0.9))), r = 120 },
    { name = "MID", x = World.hangarX, y = World.floorY(fl(mid)), r = 120 },
    { name = "LOW", x = World.hangarX, y = World.floorY(fl(math.max(1, math.floor(top * 0.2)))), r = 120 },
    { name = "LOBBY", x = World.hangarX, y = World.floorY(1), r = 80 },
    { name = "GRID", x = World.hangarX, y = World.floorY(fl(math.floor(top * 0.7))), r = 80 },
  }

  if not World.ready then
    World.cam.x = World.hangarX
    World.cam.y = World.SKY - 10
    World.cam.zoom = 1.0
  end
  loadArt()
  World.ready = true
  World.img = true
  World.chase = nil
end

function World.clampCam()
  local z = World.cam.zoom
  -- The roof formation stacks into the sky above y=0, so the ceiling has to
  -- follow the topmost slot or the upper ranks are unreachable.
  local _, top = World.roofGrid(1, World.FLOORS)
  local ceil = math.min(8, top - 40)
  World.cam.x = math.max(80, math.min(World.width - 80, World.cam.x))
  World.cam.y = math.max(ceil, math.min(World.height - 40, World.cam.y))
  World.cam.zoom = math.max(0.38, math.min(2.8, z))
end

function World.viewAABB(view)
  local hw = (view.w * 0.5) / World.cam.zoom
  local hh = (view.h * 0.5) / World.cam.zoom
  return World.cam.x - hw, World.cam.y - hh, World.cam.x + hw, World.cam.y + hh
end

function World.toScreen(wx, wy, view)
  local z = World.cam.zoom
  local sx = view.x + view.w * 0.5 + (wx - World.cam.x) * z
  local sy = view.y + view.h * 0.5 + (wy - World.cam.y) * z
  return sx, sy
end

function World.toWorld(sx, sy, view)
  local z = World.cam.zoom
  local wx = World.cam.x + (sx - view.x - view.w * 0.5) / z
  local wy = World.cam.y + (sy - view.y - view.h * 0.5) / z
  return wx, wy
end

function World.pan(dx, dy)
  World.chase = nil
  Tween.kill(World.cam)
  World.cam.x = World.cam.x + dx
  World.cam.y = World.cam.y + dy
  World.clampCam()
end

function World.zoomAt(factor, sx, sy, view)
  Tween.kill(World.cam)
  local wx, wy = World.toWorld(sx, sy, view)
  World.cam.zoom = World.cam.zoom * factor
  World.clampCam()
  local nx, ny = World.toWorld(sx, sy, view)
  World.cam.x = World.cam.x + (wx - nx)
  World.cam.y = World.cam.y + (wy - ny)
  World.clampCam()
end

function World.focus(x, y, zoom, dur)
  World.chase = nil
  World.rush = 0
  Tween.kill(World.cam)
  Tween.to(World.cam, { x = x, y = y, zoom = zoom or 1.2 }, dur or 0.14, "outExpo")
end

-- A curved camera move. X and Y ride different eases, so the eye travels an
-- arc instead of a straight ruled line, while the lens pulls back at the top
-- of the swing and settles on arrival.
function World.swoop(x, y, zoom, dur)
  dur = math.max(0.2, dur or 0.9)
  zoom = zoom or 1.0
  World.chase = nil
  World.rush = 0
  Tween.kill(World.cam)
  Tween.to(World.cam, { x = x }, dur, "inOutSine")
  Tween.to(World.cam, { y = y }, dur, "outExpo")
  local pull = math.max(0.55, zoom * 0.78)
  Tween.to(World.cam, { zoom = pull }, dur * 0.42, "outSine", function()
    Tween.to(World.cam, { zoom = zoom }, dur * 0.58, "inOutSine")
  end)
end

-- Put the roof deck and the formation standing on it in one shot. A big
-- swarm stacks far past what any zoom can hold, so when it cannot all fit the
-- shot is anchored on the roofline and the ranks run off the top of frame --
-- never the other way round, which would leave the deck below the screen.
function World.viewHeight()
  if World.mapViewH and World.mapViewH > 40 then return World.mapViewH end
  local Layout = require("src.layout")
  local h = Layout.vh or 360
  if Layout.compact then return h end
  if Layout.isPortrait() then return math.max(160, h - 180) end
  return math.max(160, h - 82)
end

function World.frameRoof(dur)
  local _, top = World.roofGrid(1, World.FLOORS)
  local bottom = World.SKY + 46          -- a strip of deck under the formation
  local span = math.max(160, bottom - top)
  local viewH = World.viewHeight()
  local zoom = math.max(0.42, math.min(1.05, viewH / span))
  local half = (viewH * 0.5) / zoom

  local y
  if span <= half * 2 then
    y = (top + bottom) * 0.5             -- the whole formation fits
  else
    y = bottom - half                    -- roof pinned to the bottom edge
  end
  World.swoop(World.hangarX, y, zoom, dur or 0.95)
end

function World.setChase(unit)
  World.chase = unit
  Tween.kill(World.cam)
  if unit and unit.x then
    World.cam.x = unit.x
    World.cam.y = unit.y - 12
    World.cam.zoom = 1.0
  end
  World.rush = 1
end

function World.update(dt)
  World.t = World.t + dt
  if World.chase and World.chase.x then
    local u = World.chase
    local lookX = u.x + (u.vx or 0) * 0.06
    local lookY = u.y + (u.vy or 0) * 0.04 - 12
    -- hard lock — no exponential crawl
    World.cam.x = lookX
    World.cam.y = lookY
    local spd = math.sqrt((u.vx or 0) ^ 2 + (u.vy or 0) ^ 2)
    local fly = u.phase == "fly" or u.phase == "exit"
    World.rush = fly and math.min(1, 0.35 + spd / 1400) or math.max(0, (World.rush or 0) - dt * 4)
    local wantZ = fly and 0.86 or 1.12
    World.cam.zoom = World.cam.zoom + (wantZ - World.cam.zoom) * math.min(1, dt * 14)
  else
    World.rush = math.max(0, (World.rush or 0) - dt * 5)
  end
  World.clampCam()
end

local function blitTile(id, x, y)
  local t = World.tiles
  if not t or not t.q[id] then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(t.img, t.q[id], x, y)
end

local function drawParallax(view)
  love.graphics.setColor(6 / 255, 8 / 255, 22 / 255, 1)
  love.graphics.rectangle("fill", view.x, view.y, view.w, view.h)
  if not World.sky then return end
  local iw, ih = World.sky:getWidth(), World.sky:getHeight()
  local s = math.max(view.w / iw, view.h / ih) * 1.2
  local px = (World.cam.x - World.hangarX) * 0.08
  local py = (World.cam.y - World.SKY) * 0.035
  local dw, dh = iw * s, ih * s
  local ox = view.x + (view.w - dw) * 0.5 - px
  local oy = view.y + (view.h - dh) * 0.12 - py
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(World.sky, ox, oy, 0, s, s)
end

-- tile ids: 1 wall 2 lit 3 dark 4 pad 5 cornice 6 neon 7 antenna 8 balcony 9 vent 10 wide 11 pillar 12 penthouse
-- only opaque facade tiles as walls — railings/antennas punch holes in the sky
local function facadeTile(n, col, cols)
  if n == World.FLOORS then
    if col <= 1 or col >= cols - 2 then return 1 end
    return 12
  end
  if n == 1 then
    if col == 0 or col == cols - 1 then return 11 end
    return 10
  end
  local k = (n * 13 + col * 7) % 9
  if k == 0 then return 2 end
  if k == 1 then return 10 end
  if k == 2 then return 3 end
  if k == 3 then return 6 end
  if k == 4 then return 9 end
  if k == 5 then return 2 end
  return 1
end

local function drawRoom(x, y, w, h, lit, seed)
  if lit then
    love.graphics.setColor(42 / 255, 28 / 255, 16 / 255, 1)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setColor(255 / 255, 196 / 255, 78 / 255, 0.55)
    love.graphics.rectangle("fill", x, y, w, 3)
    love.graphics.setColor(18 / 255, 12 / 255, 8 / 255, 0.85)
    local g = (seed % 3)
    if g == 0 then
      love.graphics.rectangle("fill", x + 2, y + h - 7, 5, 7)
      love.graphics.rectangle("fill", x + w - 8, y + 3, 6, 4)
    elseif g == 1 then
      love.graphics.rectangle("fill", x + 3, y + 4, 8, 3)
      love.graphics.rectangle("fill", x + w - 6, y + h - 8, 4, 8)
    else
      love.graphics.rectangle("fill", x + 2, y + h - 5, w - 4, 3)
      love.graphics.rectangle("fill", x + 4, y + 3, 3, 6)
    end
  else
    love.graphics.setColor(10 / 255, 9 / 255, 18 / 255, 1)
    love.graphics.rectangle("fill", x, y, w, h)
    love.graphics.setColor(16 / 255, 18 / 255, 28 / 255, 1)
    love.graphics.rectangle("fill", x + 2, y + 3, w - 4, 2)
  end
end

local function drawTower(x1, y1, x2, y2)
  local bx, bw, fh, tile = World.BX, World.BW, World.FLOOR_H, World.TILE
  local cols = math.floor(bw / tile)
  local shaftH = World.FLOORS * fh
  local f0 = World.floorAtY(y2 + fh)
  local f1 = World.floorAtY(math.max(World.SKY, y1) - fh)
  if f0 > f1 then f0, f1 = f1, f0 end
  f0 = math.max(1, f0 - 1)
  f1 = math.min(World.FLOORS, f1 + 1)

  -- solid apartment mass — sky never shows through rooms
  love.graphics.setColor(14 / 255, 12 / 255, 26 / 255, 1)
  love.graphics.rectangle("fill", bx - 4, World.SKY, bw + 8, shaftH)
  love.graphics.setColor(22 / 255, 18 / 255, 40 / 255, 1)
  love.graphics.rectangle("fill", bx, World.SKY, bw, shaftH)
  -- inner living space (warm, closed rooms)
  love.graphics.setColor(18 / 255, 16 / 255, 32 / 255, 1)
  love.graphics.rectangle("fill", bx + 4, World.SKY + 2, bw - 8, shaftH - 4)
  -- left/right structural fins
  love.graphics.setColor(10 / 255, 9 / 255, 20 / 255, 1)
  love.graphics.rectangle("fill", bx - 6, World.SKY, 6, shaftH)
  love.graphics.rectangle("fill", bx + bw, World.SKY, 6, shaftH)
  love.graphics.setColor(Theme.withAlpha(Theme.cyan, 0.18))
  love.graphics.rectangle("fill", bx - 5, World.SKY, 1, shaftH)
  love.graphics.rectangle("fill", bx + bw + 4, World.SKY, 1, shaftH)

  for n = f0, f1 do
    local fy = World.floorY(n)
    local y = fy - tile

    -- room interiors behind windows so glass never opens to the moon
    for col = 1, cols - 2 do
      local wx = bx + col * tile + 6
      local wy = y + 6
      local lit = ((n * 13 + col * 7) % 9) < 4 or n % 10 == 0
      if n == 1 then lit = true end
      drawRoom(wx, wy, tile - 10, tile - 12, lit, n * 3 + col)
    end

    if World.tiles then
      for col = 0, cols - 1 do
        blitTile(facadeTile(n, col, cols), bx + col * tile, y)
      end
      -- balconies as overlays on a solid wall, never as the wall itself
      if n % 4 == 2 and n > 1 and n < World.FLOORS then
        blitTile(1, bx, y)
        blitTile(8, bx, y)
        blitTile(1, bx + (cols - 1) * tile, y)
        blitTile(8, bx + (cols - 1) * tile, y)
      end
    end

    -- floor slab / ceiling of the apartment below
    love.graphics.setColor(32 / 255, 28 / 255, 48 / 255, 1)
    love.graphics.rectangle("fill", bx - 4, fy - 4, bw + 8, 5)
    love.graphics.setColor(Theme.withAlpha(Theme.gold, 0.16))
    love.graphics.rectangle("fill", bx, fy - 4, bw, 1)
    if n % 10 == 0 or n == 1 or n == World.FLOORS then
      local tag = string.format("F%03d", n)
      love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.7)
      love.graphics.rectangle("fill", bx + 4, fy - 14, #tag * 8 + 4, 9)
      Font.print(tag, bx + 6, fy - 13, n == 1 and Theme.amber or Theme.cyan, 1)
    end
  end

  -- roof deck
  love.graphics.setColor(16 / 255, 14 / 255, 28 / 255, 1)
  love.graphics.rectangle("fill", bx - 10, World.SKY - 10, bw + 20, 12)
  love.graphics.setColor(28 / 255, 24 / 255, 46 / 255, 1)
  love.graphics.rectangle("fill", bx - 8, World.SKY - 7, bw + 16, 7)
  if World.tiles then
    for col = 0, cols - 1 do
      blitTile(5, bx + col * tile, World.SKY - tile + 10)
    end
    blitTile(7, bx + bw - tile, World.SKY - tile * 2)
    blitTile(7, bx, World.SKY - tile * 2)
  end

  local pads = math.min(8, World.FLOORS)
  for slot = 1, pads do
    local px, py = World.roofSlot(slot)
    love.graphics.setColor(Theme.gold[1], Theme.gold[2], Theme.gold[3], 0.35)
    love.graphics.rectangle("fill", px - 6, py - 1, 12, 2)
  end

  local pulse = 0.45 + 0.55 * math.sin(World.t * 4)
  love.graphics.setColor(Theme.gold[1], Theme.gold[2], Theme.gold[3], 0.25 + 0.35 * pulse)
  love.graphics.circle("line", World.hangarX, World.SKY - 4, 18 + pulse * 2)
  love.graphics.setColor(Theme.gold)
  Font.print("ROOF", World.hangarX - 16, World.SKY - 28, Theme.gold, 1)
end

function World.draw(view)
  love.graphics.setScissor(view.x, view.y, view.w, view.h)
  drawParallax(view)

  love.graphics.push()
  love.graphics.translate(view.x + view.w * 0.5, view.y + view.h * 0.5)
  love.graphics.scale(World.cam.zoom)
  love.graphics.translate(-World.cam.x, -World.cam.y)

  local x1, y1, x2, y2 = World.viewAABB(view)
  drawTower(x1, y1, x2, y2)
  return true
end

function World.finish(view)
  love.graphics.pop()

  if World.cam.zoom >= 0.7 then
    for _, lb in ipairs(World.labels) do
      local sx, sy = World.toScreen(lb[2], lb[3], view)
      if sx > view.x + 8 and sy > view.y + 8 and sx < view.x + view.w - 8 and sy < view.y + view.h - 10 then
        love.graphics.setColor(Theme.void[1], Theme.void[2], Theme.void[3], 0.55)
        local tw = #lb[1] * 8
        love.graphics.rectangle("fill", sx - tw * 0.5 - 2, sy - 2, tw + 4, 10)
        Font.print(lb[1], sx - tw * 0.5, sy, lb[4], 1)
      end
    end
  end

  love.graphics.setColor(Theme.gold)
  local x, y, w, h = view.x, view.y, view.w, view.h
  local t = 7
  love.graphics.rectangle("fill", x, y, t, 1)
  love.graphics.rectangle("fill", x, y, 1, t)
  love.graphics.rectangle("fill", x + w - t, y, t, 1)
  love.graphics.rectangle("fill", x + w - 1, y, 1, t)
  love.graphics.rectangle("fill", x, y + h - 1, t, 1)
  love.graphics.rectangle("fill", x, y + h - t, 1, t)
  love.graphics.rectangle("fill", x + w - t, y + h - 1, t, 1)
  love.graphics.rectangle("fill", x + w - 1, y + h - t, 1, t)
  love.graphics.setColor(Theme.withAlpha(Theme.cyan, 0.35))
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
  love.graphics.setScissor()
end

function World.drawMinimap(x, y, s)
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", x, y, s, s)
  love.graphics.setColor(22 / 255, 18 / 255, 40 / 255, 1)
  local tx = x + s * 0.42
  local tw = math.max(6, s * 0.16)
  love.graphics.rectangle("fill", tx, y + 4, tw, s - 8)
  love.graphics.setColor(Theme.gold)
  love.graphics.rectangle("fill", tx - 2, y + 4, tw + 4, 3)
  local scale = (s - 8) / World.height
  local cy = y + 4 + World.cam.y * scale
  love.graphics.setColor(Theme.cyan)
  love.graphics.rectangle("fill", tx - 3, cy - 2, tw + 6, 4)
  love.graphics.setColor(Theme.gold)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, s - 1, s - 1)
end

function World.hitMinimap(mx, my, x, y, s)
  if not mx then return false end
  if mx < x or my < y or mx >= x + s or my >= y + s then return false end
  local scale = (s - 8) / World.height
  local wy = (my - y - 4) / scale
  World.focus(World.hangarX, wy, World.cam.zoom, 0.12)
  return true
end

return World
