-- Floor agents. Summon = window exit, then Iron Man climb. Camera chases.
local Theme = require("src.theme")
local Agents = require("src.agents")
local World = require("src.world")
local FX = require("src.fx")
local Sprites = require("src.sprites")
local Audio = require("src.audio")
local Ease = require("src.ease")
local Robots = require("src.robots")

local Fleet = {
  units = {},
  selected = nil,
  filter = 0,
  t = 0,
  COUNT = 100,
  PER = 25,
  heroes = {},
  stats = { online = 0, squad = {}, fly = 0, hold = 0 },
  _clusters = {},
}

local STATE = { IDLE = 1, EXIT = 2, FLY = 3, HOVER = 4, ALIGN = 5, HOLD = 6, WORK = 7 }

-- How long a unit sticks with one idle activity, in seconds.
local ACT_MIN, ACT_MAX = 3.5, 11
local STROLL = 24  -- px/s average: a wander, not a patrol

local function colorOf(u)
  return Agents.colorOf(u) or Theme.cyan
end

local function floorOf(u)
  return (u.house and u.house.floor) or World.floorAtY(u.y)
end

local function standOnFloor(u, floor, slot, count)
  local fl = World.floors[floor] or World.floors[World.FLOORS]
  u.house = fl
  local x, y = World.alignSlot(floor, slot or ((u.id % 8) + 1), count or 8)
  u.x, u.y = x, y
  u.wx, u.wy = x, y
  u.z = 0
  u.phase = "idle"
  u.state = STATE.IDLE
end

local function assignHouse(u, house)
  if not house then house = World.pickHouse(u.x or World.hangarX, u.y or World.cam.y) end
  u.house = house
  if house then
    local Central = require("src.central")
    u.ctx = u.ctx or { "BOOT", house.job, "CTX 3/3" }
    u.ctx[2] = Central.assign(u.id, u.squad, house)
  end
end

local function makeUnit(i, x, y, look)
  local floor = i
  local fl = World.floors[floor]
  local stand = World.standY(floor)
  x = x or World.hangarX
  y = y or stand
  local wings = math.max(1, Agents.wings())
  local squad = ((i - 1) % wings) + 1
  local u = {
    id = i,
    squad = squad,
    hero = i <= wings,
    x = x, y = y,
    z = 0,
    vx = 0, vy = 0,
    heading = 0,
    house = fl,
    homeFloor = floor,
    homeX = World.hangarX,
    homeY = stand,
    wx = x, wy = y,
    pause = 0,
    dwell = 0,
    walkT = 0,
    phase = "idle",
    flyT = 0,
    exitX = World.exitX(x),
    destX = x,
    destY = y,
    speed = 110,
    state = STATE.IDLE,
    ctx = { "ON FLOOR", fl and fl.job or "WATCH", "CTX 3/3" },
    online = true,
    arrived = true,
  }
  local Central = require("src.central")
  u.ctx[2] = Central.assign(i, squad, fl)
  Agents.paint(u, look)
  return u
end

function Fleet.spawn()
  Fleet.units = {}
  Fleet.selected = nil
  Fleet.filter = 0
  Fleet.heroes = {}
  Fleet.leaving = {}
  local looks = Agents.deal(Fleet.COUNT)
  for i = 1, Fleet.COUNT do
    local u = makeUnit(i, nil, nil, looks[i])
    Fleet.units[i] = u
    if i <= Agents.wings() then Fleet.heroes[i] = u end
  end
  -- A robot chosen before the tower was (re)built is still chosen.
  Fleet.selected = Fleet.unitOf(Robots.selected)
end

-- ------------------------------------------------------------ selection --
--
-- One selection. The unit locked on the map, the robot on the rail and the
-- face in face mode are the same choice, held by `Robots`; this side keeps
-- the unit that wears it and nothing more. `lock` and `unlock` go through
-- `Robots.select`, and the watcher below brings a change made anywhere else
-- — F6, the rail, the arrow keys in face mode — back onto the map.

--- The unit that is this robot, or nil.
function Fleet.unitOf(robotId)
  if not robotId then return nil end
  for _, u in ipairs(Fleet.units) do
    if u.robot == robotId then return u end
  end
  return nil
end

--- Lock on to a unit — and so on to the robot it is.
function Fleet.lock(u)
  if not u then return Fleet.unlock() end
  Fleet.selected = u
  Agents.selected = u.squad
  if u.robot then Robots.select(u.robot) end
  return u
end

--- Let go of everything: no unit, no wing, no robot.
function Fleet.unlock()
  Fleet.selected = nil
  Agents.selected = nil
  Robots.select(nil)
  return nil
end

Robots.watch(function(id)
  local u = Fleet.unitOf(id)
  -- A robot with no unit on the tower yet (the roster answered before the
  -- dashboard was entered) is still the selection; the unit follows on
  -- `spawn`. Only a change *to* a robot clears the map lock.
  if u or id == nil then
    Fleet.selected = u
    Agents.selected = u and u.squad or nil
  elseif Fleet.selected and Fleet.selected.robot ~= id then
    Fleet.selected = nil
    Agents.selected = nil
  end
end)

--- What a unit is called on screen: the robot's name when it is one, its
--- number otherwise.
function Fleet.tag(u)
  if not u then return "" end
  local a = Agents.lookOf(u)
  if u.robot and a then return a.name end
  return string.format("U%04d", u.id)
end

function Fleet.resize(n)
  n = math.max(1, math.min(1000, math.floor(n)))
  Fleet.leaving = Fleet.leaving or {}
  local prev = Fleet.units or {}
  local next = {}
  for i = 1, n do
    local stand = World.standY(i)
    local fl = World.floors[i]
    local u = prev[i]
    if u then
      u.id = i
      u.homeFloor = i
      u.homeX = World.hangarX
      u.homeY = stand
      u.house = fl
      u.online = true
      Fleet.sendHome(u, {
        quiet = true,
        delay = math.min(0.28, (i - 1) / math.max(1, n) * 0.28),
      })
      next[i] = u
    else
      u = makeUnit(i, World.hangarX, World.SKY - 28)
      Fleet.sendHome(u, {
        quiet = true,
        delay = math.min(0.28, (i - 1) / math.max(1, n) * 0.28),
      })
      next[i] = u
    end
    if i <= Agents.wings() then Fleet.heroes[i] = next[i] end
  end
  for i = n + 1, #prev do
    local u = prev[i]
    u.retire = true
    Fleet.summon(u, World.hangarX + ((i % 7) - 3) * 18, World.SKY - 96, { quiet = true })
    Fleet.leaving[#Fleet.leaving + 1] = u
  end
  for i = Agents.wings() + 1, #Fleet.heroes do Fleet.heroes[i] = nil end
  Fleet.units = next
  Fleet.COUNT = n
  if Fleet.selected and (Fleet.selected.id > n or Fleet.selected.retire) then
    Fleet.unlock()
  end
end

function Fleet.scatterAll()
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if Fleet.inScope(u) and u.online then
      local floor = love.math.random(1, World.FLOORS)
      local x, y = World.randInFlat(floor)
      local delay = math.min(0.28, (u.id - 1) / math.max(1, Fleet.COUNT) * 0.28)
      Fleet.summon(u, x, y, { quiet = true, delay = delay })
      n = n + 1
    end
  end
  World.chase = nil
  Audio.play("whoosh")
  FX.wave(World.hangarX, World.cam.y, Theme.cyan, 70)
  return n
end

function Fleet.search(q, limit)
  q = (q or ""):upper():gsub("^%s+", ""):gsub("%s+$", "")
  limit = limit or 8
  local num = tonumber(q:match("%d+"))
  local cy = World.cam.y
  local scored = {}
  for _, u in ipairs(Fleet.units) do
    local a = Agents.lookOf(u)
    local id = string.format("U%04d", u.id)
    local fl = string.format("F%03d", u.homeFloor or u.id)
    local name = a and a.name or ""
    local ok = q == ""
      or id:find(q, 1, true)
      or fl:find(q, 1, true)
      or name:find(q, 1, true)
      or (num ~= nil and (u.id == num or u.homeFloor == num))
    if ok then
      local rank = math.abs(u.y - cy)
      if num and (u.id == num or u.homeFloor == num) then rank = rank - 1000000 end
      if Fleet.selected == u then rank = rank - 100000 end
      scored[#scored + 1] = { u = u, rank = rank }
    end
  end
  table.sort(scored, function(a, b) return a.rank < b.rank end)
  local hits = {}
  for i = 1, math.min(limit, #scored) do
    hits[i] = scored[i].u
  end
  return hits
end

function Fleet.onlineCount()
  return Fleet.stats.online
end

function Fleet.get(id)
  return Fleet.units[id]
end

function Fleet.hero(squad)
  return Fleet.heroes[squad]
end

function Fleet.setFilter(s)
  Fleet.filter = s
end

function Fleet.scopeN()
  if Fleet.selected then return 1 end
  if Fleet.filter == 0 then return Fleet.COUNT end
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if u.squad == Fleet.filter then n = n + 1 end
  end
  return n
end

function Fleet.scopeLabel()
  if Fleet.selected then
    return Fleet.tag(Fleet.selected)
  end
  if Fleet.filter == 0 then
    return string.format("ALL %d", Fleet.COUNT)
  end
  local a = Agents.list[Fleet.filter]
  local per = math.ceil(Fleet.COUNT / math.max(1, Agents.wings()))
  return string.format("%s %d", a and a.name or "WING", per)
end

-- A locked unit owns every order. With nobody locked, a wing filter (from
-- the model) still applies; otherwise the whole swarm.
function Fleet.inScope(u)
  if not u then return false end
  if Fleet.selected then return u == Fleet.selected end
  return Fleet.filter == 0 or u.squad == Fleet.filter
end

local function beginSeg(u, x0, y0, x1, y1, dur, arc)
  u.sx, u.sy = x0, y0
  u.ex, u.ey = x1, y1
  u.segT = 0
  u.segDur = math.max(0.35, dur)
  u.arc = arc and true or false
  local dx, dy = x1 - x0, y1 - y0
  local dist = math.sqrt(dx * dx + dy * dy)
  local side = (x0 < World.hangarX) and -1 or 1
  local pull = math.min(48, 8 + dist * 0.05)
  u.cx = (x0 + x1) * 0.5 + side * pull
  u.cy = (y0 + y1) * 0.5 - math.min(70, dist * 0.08)
end

local function stepSeg(u, dt)
  u.segT = (u.segT or 0) + dt
  local t = math.min(1, u.segT / (u.segDur or 0.4))
  -- long arcs hang, punch and settle; short hops just breathe in and out
  local k = u.arc and Ease.inOutExpo(t) or Ease.inOutSine(t)
  local nx, ny
  if u.arc then
    local ik = 1 - k
    nx = ik * ik * u.sx + 2 * ik * k * u.cx + k * k * u.ex
    ny = ik * ik * u.sy + 2 * ik * k * u.cy + k * k * u.ey
  else
    nx = u.sx + (u.ex - u.sx) * k
    ny = u.sy + (u.ey - u.sy) * k
  end
  u.vx = (nx - u.x) / math.max(dt, 1 / 240)
  u.vy = (ny - u.y) / math.max(dt, 1 / 240)
  u.x, u.y = nx, ny
  u.heading = math.atan2(u.vy, u.vx)
  return t >= 1
end

local function startFly(u)
  u.phase = "fly"
  u.state = STATE.FLY
  u.arrived = false
  local x0, y0 = u.x, u.y
  local x1 = u.destX or x0
  local y1 = u.destY or y0
  local dist = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
  if dist < 3 then
    u.phase = "idle"
    u.state = STATE.IDLE
    u.arrived = true
    u.wx, u.wy = x0, y0
    return
  end
  local dur = math.max(0.45, math.min(2.4, dist / 650))
  beginSeg(u, x0, y0, x1, y1, dur, dist > 40)
end

function Fleet.summon(u, destX, destY, opts)
  if not u or not u.online then return end
  opts = opts or {}
  u.idle = false
  u.destX = destX or u.x
  u.destY = destY or u.y
  u.quiet = opts.quiet and true or false
  u.arrived = false
  u.flyT = 0
  u.ctx[1] = (u.destY > World.SKY + 8) and "HOME" or "LAUNCH"
  -- Stay put until takeoff. Never rewrite x/y here.
  local delay = opts.delay or 0
  if delay > 0.02 then
    u.phase = "wait"
    u.state = STATE.IDLE
    u.wait = delay
  else
    startFly(u)
    if not u.quiet then
      FX.burstWorld(u.x, u.y, colorOf(u), 8)
      Audio.play("whoosh")
    end
  end
end

function Fleet.summonToRoof(u, opts)
  if not u then return end
  opts = opts or {}
  local x, y = World.roofGrid(u.id, Fleet.COUNT)
  Fleet.summon(u, x, y, opts)
  if not opts.quiet and not opts.noChase then
    -- follow without snapping the robot; camera eases in World.update
    World.chase = u
    World.rush = 1
  end
end

function Fleet.sendHome(u, opts)
  if not u then return end
  opts = opts or {}
  local fl = World.floors[u.homeFloor or u.id]
  local x = u.homeX or World.hangarX
  local y = u.homeY or World.standY(u.homeFloor or u.id)
  u.house = fl
  if u.ctx then u.ctx[1] = "HOME" end
  Fleet.summon(u, x, y, opts)
end

function Fleet.sendAllHome()
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if Fleet.inScope(u) and u.online then
      local delay = math.min(0.28, (u.homeFloor or u.id) / math.max(1, Fleet.COUNT) * 0.28)
      Fleet.sendHome(u, { quiet = true, delay = delay, noChase = true })
      n = n + 1
    end
  end
  World.chase = nil
  Audio.play("whoosh")
  FX.wave(World.hangarX, World.cam.y, Theme.magenta, 70)
  return n
end

function Fleet.summonAll()
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if Fleet.inScope(u) and u.online then
      local delay = math.min(0.28, (Fleet.COUNT - (u.homeFloor or u.id)) / math.max(1, Fleet.COUNT) * 0.28)
      Fleet.summonToRoof(u, { quiet = true, delay = delay, noChase = true })
      n = n + 1
    end
  end
  World.chase = nil
  Audio.play("sting")
  FX.kick(3)
  -- Frame the roof deck with the formation standing on it: the top slot at
  -- the top of the shot, a strip of roof at the bottom, zoom to fit.
  if n > 0 then
    World.frameRoof(0.95)
  end
  return n
end

-- Idle life: walk the floor, rest, or stand on a charger. Picked at random
-- and re-picked every few seconds, so a floor never looks choreographed.
-- Every stroll is eased: the agent leans into the step and settles out of
-- it, so a floor of them never marches at one constant speed.
local function strollTo(u, x)
  u.strollFrom = u.x
  u.strollTo = x
  u.strollT = 0
  u.strollDur = math.max(0.7, math.abs(x - u.x) / STROLL)
end

local function pickAct(u)
  local r = love.math.random()
  u.act = (r < 0.45 and "walk") or (r < 0.74 and "rest") or "charge"
  u.actT = ACT_MIN + love.math.random() * (ACT_MAX - ACT_MIN)
  if u.act == "walk" then
    strollTo(u, World.BX + 26 + love.math.random() * (World.BW - 52))
  elseif u.act == "charge" then
    -- chargers are on the walls at each end of the flat
    strollTo(u, (love.math.random() < 0.5) and (World.BX + 24) or (World.BX + World.BW - 24))
  else
    u.strollTo = nil
  end
  -- A stroll runs to its end. The activity timer is drawn from a range
  -- shorter than a long walk across the flat, and a re-pick mid-stroll
  -- restarted the ease from wherever the unit was — a jolt on screen, and
  -- a speed profile that was two half-strolls stitched together.
  if u.strollTo and u.strollDur then
    u.actT = math.max(u.actT, u.strollDur + 0.25)
  end
end

-- IDLE: everyone back to their own floor and left to their own devices.
function Fleet.idleAll()
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if Fleet.inScope(u) and u.online then
      local floor = u.homeFloor or u.id
      local x = World.BX + 30 + love.math.random() * (World.BW - 60)
      local delay = math.min(0.3, ((u.id - 1) % 24) / 24 * 0.3)
      Fleet.summon(u, x, World.standY(floor), { quiet = true, noChase = true, delay = delay })
      u.house = World.floors[floor]
      u.idle = true
      u.act, u.actT = nil, 0
      n = n + 1
    end
  end
  World.chase = nil
  Audio.play("toggle")
  return n
end

local function clampX(x)
  return math.max(World.BX + 14, math.min(World.BX + World.BW - 14, x))
end

-- Formations may spill past the tower shell into the open air beside it.
local function clampAir(x)
  return math.max(28, math.min(World.width - 28, x))
end

-- FORM UP: each wing packs into its own block over the deck, commanders at
-- the front. Distinct from SUMMON, which is one wide roof grid.
function Fleet.formOnCommanders()
  local wings = {}
  local order = {}
  for _, u in ipairs(Fleet.units) do
    if Fleet.inScope(u) and u.online then
      local w = u.squad
      if not wings[w] then wings[w] = {} order[#order + 1] = w end
      -- the commander leads its block
      if u.hero then table.insert(wings[w], 1, u) else wings[w][#wings[w] + 1] = u end
    end
  end
  table.sort(order)

  local lanes = math.max(1, #order)
  local span = math.min(World.width - 80, lanes * 108)
  local left = World.hangarX - span * 0.5
  local n = 0
  for lane, w in ipairs(order) do
    local list = wings[w]
    local cx = left + span * ((lane - 0.5) / lanes)
    -- roughly square blocks, so a big wing widens instead of towering
    local cols = math.max(1, math.min(6, math.ceil(math.sqrt(#list))))
    for i, u in ipairs(list) do
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      local x = cx + (col - (cols - 1) * 0.5) * 15
      local y = World.SKY - 22 - row * 14
      Fleet.summon(u, clampAir(x), y, { quiet = true, noChase = true })
      n = n + 1
    end
  end

  World.chase = nil
  if n > 0 then
    World.swoop(World.hangarX, World.SKY - 48, 0.95, 0.85)
    Audio.play("online")
    FX.wave(World.hangarX, World.SKY - 30, Theme.gold, 120)
  end
  return n
end

-- SWEEP: a low pass in three ranks right across the lobby, with the camera
-- dropped onto it so the pass is actually visible.
function Fleet.sweepLobby()
  local list = {}
  for _, u in ipairs(Fleet.units) do
    if Fleet.inScope(u) and u.online then list[#list + 1] = u end
  end
  if #list == 0 then return 0 end

  -- Keep the ranks readable: about 24 units abreast, however big the swarm.
  local ranks = math.max(1, math.min(24, math.ceil(#list / 24)))
  local per = math.ceil(#list / ranks)
  local span = math.min(World.width - 80, math.max(World.BW - 36, per * 15))
  local x0, x1 = World.hangarX - span * 0.5, World.hangarX + span * 0.5
  local base = World.standY(1)
  for i, u in ipairs(list) do
    local rank = math.floor((i - 1) / per)
    local k = (i - 1) % per
    local f = per > 1 and (k / (per - 1)) or 0.5
    Fleet.summon(u, clampAir(x0 + (x1 - x0) * f), base - rank * 15,
      { quiet = true, noChase = true })
  end

  World.chase = nil
  World.swoop(World.hangarX, base - 24, 1.0, 0.85)
  Audio.play("scan")
  FX.wave(World.hangarX, base - 10, Theme.cyan, 140)
  return #list
end

local function summonCap(kind, wx, wy)
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if not Fleet.inScope(u) then goto continue end
    if kind == "hold" then
      u.state = STATE.HOLD
      u.phase = "idle"
      u.idle = false
      u.vx, u.vy = 0, 0
      n = n + 1
    elseif kind == "sleep" then
      u.idle = false
      u.online = false
      u.state = STATE.HOLD
      u.phase = "idle"
      n = n + 1
    elseif kind == "wake" then
      u.online = true
      n = n + 1
    end
    ::continue::
  end
  return n
end

-- Returns how many units took the order, so callers can report it.
function Fleet.command(kind, wx, wy)
  if kind == "rally" then
    return Fleet.summonAll()
  elseif kind == "form" then
    return Fleet.formOnCommanders()
  elseif kind == "home" then
    return Fleet.sendAllHome()
  elseif kind == "scatter" then
    return Fleet.scatterAll()
  elseif kind == "sweep" then
    return Fleet.sweepLobby()
  elseif kind == "idle" then
    return Fleet.idleAll()
  elseif kind == "hold" or kind == "sleep" or kind == "wake" then
    return summonCap(kind, wx, wy)
  end
  return 0
end

function Fleet.pick(wx, wy, radius)
  local best, bd = nil, radius * radius
  for _, u in ipairs(Fleet.units) do
    if not Fleet.inScope(u) then goto continue end
    local dx, dy = u.x - wx, u.y - wy
    local d = dx * dx + dy * dy
    if d < bd then best, bd = u, d end
    ::continue::
  end
  return best
end

function Fleet.clusterCell()
  return 24
end

function Fleet.probe(wx, wy, zoom)
  zoom = zoom or World.cam.zoom
  local rad = math.max(16, 28 / zoom)
  local u = Fleet.pick(wx, wy + 12, rad)
  if u then return "unit", u end
  u = Fleet.pick(wx, wy, rad)
  if u then return "unit", u end
  return nil, nil
end

function Fleet.update(dt)
  Fleet.t = Fleet.t + dt
  local st = Fleet.stats
  st.online, st.fly, st.hold = 0, 0, 0
  for s = 1, Agents.wings() do st.squad[s] = 0 end

  local bag = {}
  for _, u in ipairs(Fleet.units) do bag[#bag + 1] = u end
  for _, u in ipairs(Fleet.leaving or {}) do bag[#bag + 1] = u end

  for _, u in ipairs(bag) do
    if u.online and not u.retire then
      st.online = st.online + 1
      st.squad[u.squad] = st.squad[u.squad] + 1
    end

    if not u.online then
      u.vx, u.vy = 0, 0
      goto continue
    end

    if u.phase == "wait" then
      u.ctx[1] = (u.destY and u.destY > World.SKY + 8) and "HOME" or "LAUNCH"
      u.wait = (u.wait or 0) - dt
      if u.wait <= 0 then
        startFly(u)
      end

    elseif u.phase == "exit" then
      -- leftover: treat as takeoff from here, no window snap
      startFly(u)

    elseif u.phase == "fly" then
      st.fly = st.fly + 1
      u.ctx[1] = "FLIGHT"
      u.flyT = (u.flyT or 0) + dt
      if stepSeg(u, dt) then
        u.phase = "hover"
        u.state = STATE.HOVER
        u.dwell = 0.16
        u.vx, u.vy = 0, 0
        if not u.quiet then
          FX.wave(u.x, u.y, colorOf(u), 28)
        end
      end
      local near = math.abs(u.y - World.cam.y) < 420
      local spd = math.sqrt((u.vx or 0) ^ 2 + (u.vy or 0) ^ 2)
      if near and love.math.random() < dt * (4 + math.min(12, spd * 0.02)) then
        FX.jet(u.x, u.y + 4, u.heading, Theme.gold)
        FX.jet(u.x, u.y + 4, u.heading, Theme.cyan)
      end

    elseif u.phase == "hover" then
      st.fly = st.fly + 1
      u.ctx[1] = "HOVER"
      u.dwell = (u.dwell or 0) - dt
      if u.dwell <= 0 then
        u.phase = "align"
        u.state = STATE.ALIGN
        u.wx, u.wy = u.destX, u.destY
        local fl = World.floorAtY(u.destY + 4)
        if u.destY <= World.SKY + 8 then fl = World.FLOORS end
        u.house = World.floors[fl]
        assignHouse(u, u.house)
        beginSeg(u, u.x, u.y, u.wx, u.wy, 0.12, false)
      end

    elseif u.phase == "align" then
      st.hold = st.hold + 1
      u.ctx[1] = "ALIGN"
      if stepSeg(u, dt) then
        u.phase = "idle"
        u.state = STATE.IDLE
        u.arrived = true
        u.vx, u.vy = 0, 0
        u.wx, u.wy = u.x, u.y
        u.ctx[1] = "AT " .. ((u.house and u.house.name) or "ROOF")
        if World.chase == u then World.chase = nil end
        if not u.quiet then
          FX.wave(u.x, u.y, colorOf(u), 22)
          FX.burstWorld(u.x, u.y, colorOf(u), 12)
          Audio.play("online")
        end
      end

    else
      st.hold = st.hold + 1
      u.vx, u.vy = 0, 0
      if u.wy and math.abs((u.y or 0) - u.wy) < 2.5 then
        u.y = u.wy
      end
      u.walkT = (u.walkT or 0) + dt
      local near = math.abs(u.y - World.cam.y) < 280

      if u.idle and u.arrived then
        u.actT = (u.actT or 0) - dt
        if not u.act or u.actT <= 0 then pickAct(u) end

        local walking = u.strollTo and (u.strollT or 0) < (u.strollDur or 0)
        if walking then
          u.strollT = u.strollT + dt
          local k = Ease.inOutSine(math.min(1, u.strollT / u.strollDur))
          local nx = u.strollFrom + (u.strollTo - u.strollFrom) * k
          u.vx = (nx - u.x) / math.max(dt, 1 / 240)
          u.x = nx
          u.heading = (u.strollTo >= u.strollFrom) and 0 or math.pi
          u.state = STATE.WORK
          u.ctx[1] = u.act == "charge" and "TO CHARGER" or "WALKING"
        elseif u.act == "walk" then
          -- arrived: pause a beat, then ease off somewhere else on the floor
          u.state = STATE.IDLE
          u.ctx[1] = "ON FLOOR"
          if love.math.random() < dt * 0.9 then
            strollTo(u, World.BX + 26 + love.math.random() * (World.BW - 52))
          end
        elseif u.act == "charge" then
          u.state = STATE.WORK
          u.ctx[1] = "CHARGING"
          if near and love.math.random() < dt * 3.2 then
            FX.jet(u.x, u.y - 10, -math.pi * 0.5, Theme.cyan)
          end
        else
          u.state = STATE.IDLE
          u.ctx[1] = "RESTING"
          if near and love.math.random() < dt * 0.5 then
            FX.jet(u.x, u.y - 12, -math.pi * 0.5, Theme.ice)
          end
        end
        u.wx = u.x

      elseif near and love.math.random() < dt * 1.4 then
        FX.jet(u.x, u.y + 2, math.pi * 0.5, Theme.gold)
        FX.jet(u.x, u.y + 2, math.pi * 0.5, Theme.cyan)
      end
    end

    ::continue::
  end

  if Fleet.leaving then
    for i = #Fleet.leaving, 1, -1 do
      local u = Fleet.leaving[i]
      if u.phase == "idle" and u.arrived then
        table.remove(Fleet.leaving, i)
      end
    end
  end

  for s = 1, Agents.wings() do
    local h = Fleet.heroes[s]
    local a = Agents.list[s]
    if h and a then
      a.wx, a.wy = h.x, h.y
      a.online = h.online
    end
  end
end

-- Every unit is drawn, whatever is locked. The scope narrows *orders*, not
-- the picture: choosing one agent used to make the other eleven vanish from
-- the tower, which read as the swarm having left rather than as a choice.
-- Pure, so a test can hold it to that.
function Fleet.drawList()
  local list = {}
  for _, u in ipairs(Fleet.units) do
    list[#list + 1] = u
  end
  for _, u in ipairs(Fleet.leaving or {}) do
    list[#list + 1] = u
  end
  table.sort(list, function(a, b) return a.y < b.y end)
  return list
end

function Fleet.draw(view)
  local x1, y1, x2, y2 = World.viewAABB(view)
  local pad = 50
  x1, y1, x2, y2 = x1 - pad, y1 - pad, x2 + pad, y2 + pad

  local list = Fleet.drawList()

  for _, u in ipairs(list) do
    if u.x < x1 or u.x > x2 or u.y < y1 or u.y > y2 then goto drawskip end
    local flying = u.phase == "fly" or u.phase == "exit" or u.phase == "hover"
      or u.phase == "wait" or u.phase == "align"
    local a = Agents.lookOf(u)
    local roofed = u.destY and u.destY <= World.SKY + 8 and not flying
    local h = 22
    if flying then h = 26
    elseif roofed then h = 18 end
    Sprites.drawAgent(u.lookKey or (a and a.key) or "jarvis", u.x, u.y, {
      flying = flying,
      vx = flying and (u.vx or 0) or 0,
      vy = flying and (u.vy or 0) or 0,
      t = Fleet.t,
      id = u.id,
      height = h,
    })
    -- what an off-duty agent is up to, read at a glance
    if u.idle and not flying then
      local p = 0.5 + 0.5 * math.sin(Fleet.t * (u.act == "charge" and 6 or 1.5) + u.id)
      if u.act == "charge" then
        love.graphics.setColor(Theme.cyan[1], Theme.cyan[2], Theme.cyan[3], 0.30 + 0.40 * p)
        love.graphics.rectangle("fill", math.floor(u.x) - 5, math.floor(u.y) + 1, 10, 1)
        love.graphics.setColor(Theme.cyan[1], Theme.cyan[2], Theme.cyan[3], 0.25 + 0.55 * p)
        love.graphics.rectangle("fill", math.floor(u.x) - 1, math.floor(u.y) - h - 4 - p * 2, 2, 2)
      elseif u.act == "rest" then
        love.graphics.setColor(Theme.ice[1], Theme.ice[2], Theme.ice[3], 0.14 + 0.10 * p)
        love.graphics.rectangle("fill", math.floor(u.x) - 4, math.floor(u.y) + 1, 8, 1)
        love.graphics.setColor(Theme.ice[1], Theme.ice[2], Theme.ice[3], 0.18 + 0.22 * p)
        love.graphics.rectangle("fill", math.floor(u.x) + 3, math.floor(u.y) - h - 3, 1, 1)
      end
    end
    if Fleet.selected == u then
      local col = colorOf(u)
      love.graphics.setColor(col[1], col[2], col[3], 0.85)
      love.graphics.rectangle("line", math.floor(u.x - 8), math.floor(u.y - h - 2), 16, h + 4)
    end
    ::drawskip::
  end
end

function Fleet.drawClusterLabels(_view)
end

function Fleet.drawMinimapDots(x, y, s)
  local scaleY = (s - 8) / World.height
  local tx = x + s * 0.42 + 2
  for _, u in ipairs(Fleet.units) do
    local col = colorOf(u)
    local on = Fleet.selected == u
    love.graphics.setColor(col[1], col[2], col[3], (on or not Fleet.selected) and 1 or 0.55)
    love.graphics.rectangle("fill", tx, y + 4 + u.y * scaleY, 3, 3)
  end
end

Fleet.STATE = STATE
return Fleet
