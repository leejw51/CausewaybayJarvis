local Theme = require("src.theme")
local Store = require("src.store")
local Json = require("src.json")

local Agents = {}

-- The AI agents, once the backend has answered. From then on the list below
-- is the roster — one entry per robot, one folder each — and the catalog is
-- only a bank of bodies and lines for those robots to borrow. Until then
-- (and on a checkout with no backend built) the catalog stands in, so the
-- tower still has somebody in it.
Agents.roster = false

-- The backend names a colour; the palette is here.
local COLORS = {
  gold = Theme.gold, magenta = Theme.magenta, jade = Theme.jade, cyan = Theme.cyan,
  crimson = Theme.crimson, amber = Theme.amber, ice = Theme.ice, violet = Theme.violet,
  orange = Theme.orange, rose = Theme.rose, sky = Theme.sky, teal = Theme.teal,
  lime = Theme.jade, green = Theme.jade, blue = Theme.sky, yellow = Theme.amber,
  red = Theme.crimson,
}

-- How many wings light up on a given boot. The catalog is larger; each
-- session draws this many at random, preferring distinct sprites.
Agents.SESSION = 4
Agents.SIZE = 100
Agents.UNIQUE = 100
Agents.ART = 20
Agents.POOL = 10
Agents.TEST_SPRITE = nil

-- Session pool persists as a jsonl log (~/.causewaybayjarvis2/robots.jsonl).
-- One object per line; the last readable ids array wins on the next launch.
Agents.LOG = "robots.jsonl"
local LOG_MAX = 200
local LOG_KEEP = 40

-- Full roster. Every model has its own sprite and a matching fly pose.
Agents.catalog = {
  {
    id = "jarvis", key = "jarvis", base = "jarvis",
    name = "JARVIS", role = "CORE BUTLER",
    callsign = "GOLD VISOR", bay = "BAY-00",
    color = Theme.gold, accent = Theme.cyan,
    core = 0.96, link = 0.99, heat = 0.18, duty = 0.72,
    territory = "CENTRAL",
    boot = "GOOD EVENING, SIR. WORKSHOP GRID IS LIVE.",
    ping = "SWARM ON THE FLOOR. CAUSEWAY BAY LINK IS CLEAN.",
    report = "KERNEL NOMINAL. NO FAULTS ON THE GOLD VISOR BUS.",
    chat = "LOGGED. THE SUITS AWAIT YOUR WORD.",
  },
  {
    id = "neon", key = "neon", base = "neon",
    name = "NEON", role = "COMMS",
    callsign = "PINK ANTENNA", bay = "BAY-01",
    color = Theme.magenta, accent = Theme.teal,
    core = 0.88, link = 0.94, heat = 0.24, duty = 0.61,
    territory = "NEON ROW",
    boot = "NEON ONLINE. CHANNELS OPEN ACROSS THE HARBOUR.",
    ping = "TRAFFIC IS LOUD TONIGHT. I AM LOUDER.",
    report = "COMMS MESH: FLEET MATCHES THE TOWER. ONE AGENT PER FLOOR.",
    chat = "SAY THE WORD AND I PATCH IT THROUGH.",
  },
  {
    id = "jade", key = "jade", base = "jade",
    name = "JADE", role = "RESEARCH",
    callsign = "LEAF CREST", bay = "BAY-02",
    color = Theme.jade, accent = Theme.gold,
    core = 0.91, link = 0.86, heat = 0.15, duty = 0.54,
    territory = "THE PEAK",
    boot = "JADE ONLINE. ARCHIVES MOUNTED ON CENTRAL.",
    ping = "I HAVE THE FILES. ALWAYS THE FILES.",
    report = "INDEX IS WARM. UNITS HOLD CONTEXT. I HOLD THE STACK.",
    chat = "RESEARCH CORE IS STAGED ON CENTRAL.",
  },
  {
    id = "typhoon", key = "typhoon", base = "typhoon",
    name = "TYPHOON", role = "OPERATIONS",
    callsign = "WHITE SCARF", bay = "BAY-03",
    color = Theme.cyan, accent = Theme.ice,
    core = 0.84, link = 0.90, heat = 0.31, duty = 0.68,
    territory = "HARBOUR",
    boot = "TYPHOON ONLINE. OPS BOARD IS CLEAR.",
    ping = "WINDS ARE UP. I LIKE IT THAT WAY.",
    report = "QUEUE: SWEEP READY, 0 BLOCKING.",
    chat = "POINT ME AT THE WEATHER AND I WILL MOVE IT.",
  },
  {
    id = "dragon", key = "dragon", base = "dragon",
    name = "DRAGON", role = "SECURITY",
    callsign = "RED HORN", bay = "BAY-04",
    color = Theme.crimson, accent = Theme.gold,
    core = 0.93, link = 0.88, heat = 0.27, duty = 0.80,
    territory = "GRID",
    boot = "DRAGON ONLINE. PERIMETER LOCKED.",
    ping = "NOTHING COMES IN THAT I DO NOT SEE.",
    report = "SHIELDS UP. INTRUSION COUNT: ZERO.",
    chat = "STAND BEHIND ME OR STAND CLEAR.",
  },
  {
    id = "ferry", key = "ferry", base = "ferry",
    name = "FERRY", role = "LOGISTICS",
    callsign = "AMBER RING", bay = "BAY-05",
    color = Theme.amber, accent = Theme.cyan,
    core = 0.87, link = 0.92, heat = 0.21, duty = 0.58,
    territory = "PIER",
    boot = "FERRY ONLINE. STARBOARD STORES FULL.",
    ping = "I KEEP THE BAY MOVING. ALWAYS HAVE.",
    report = "PAYLOAD READY. ROUTES GREEN TO CENTRAL.",
    chat = "LOAD IT. I WILL GET IT THERE.",
  },
  {
    id = "volt", key = "volt", base = "volt",
    name = "VOLT", role = "SURVEILLANCE",
    callsign = "WHITE ARC", bay = "BAY-06",
    color = Theme.ice, accent = Theme.gold,
    core = 0.90, link = 0.95, heat = 0.16, duty = 0.66,
    territory = "THE PEAK",
    boot = "VOLT ONLINE. THE ISLAND IS IN FRAME.",
    ping = "I SEE IT BEFORE IT MOVES.",
    report = "OVERWATCH NOMINAL. EVERY FLOOR LIT.",
    chat = "I WATCH. YOU DECIDE.",
  },
  {
    id = "ghost", key = "ghost", base = "ghost",
    name = "GHOST", role = "STEALTH",
    callsign = "VIOLET HAZE", bay = "BAY-07",
    color = Theme.violet, accent = Theme.teal,
    core = 0.86, link = 0.89, heat = 0.19, duty = 0.52,
    territory = "SOHO",
    boot = "GHOST ONLINE. YOU WILL NOT SEE ME. THEY WILL NOT EITHER.",
    ping = "STILL HERE. STILL QUIET.",
    report = "NO FOOTPRINT. NO ECHO. CLEAN.",
    chat = "POINT. I WAS ALREADY THERE.",
  },
  {
    id = "razor", key = "razor", base = "razor",
    name = "RAZOR", role = "WEATHER",
    callsign = "BLUE EDGE", bay = "BAY-08",
    color = Theme.sky, accent = Theme.ice,
    core = 0.83, link = 0.91, heat = 0.28, duty = 0.70,
    territory = "HARBOUR",
    boot = "RAZOR ONLINE. THE FRONT IS MINE.",
    ping = "RAIN ON THE GLASS. I STILL CUT.",
    report = "OPS WINDOW OPEN. NOTHING BLUNTS ME.",
    chat = "WEATHER IS A PROBLEM I SOLVE.",
  },
  {
    id = "nova", key = "nova", base = "nova",
    name = "NOVA", role = "NAVIGATION",
    callsign = "GOLD FLARE", bay = "BAY-09",
    color = Theme.gold, accent = Theme.jade,
    core = 0.89, link = 0.97, heat = 0.14, duty = 0.63,
    territory = "CENTRAL",
    boot = "NOVA ONLINE. EVERY CORRIDOR HAS A LIGHT.",
    ping = "HOLD THE LINE. I WILL BRING THEM IN.",
    report = "FIXES LOCKED. NO UNIT IS LOST.",
    chat = "POINT. I WILL BURN THE WAY.",
  },
  {
    id = "nitro", key = "nitro", base = "nitro",
    name = "NITRO", role = "TRANSIT",
    callsign = "RED RAIL", bay = "BAY-10",
    color = Theme.crimson, accent = Theme.amber,
    core = 0.85, link = 0.93, heat = 0.22, duty = 0.74,
    territory = "DES VOEUX",
    boot = "NITRO ONLINE. THE RAILS ARE LIVE FROM THE PIER UP.",
    ping = "I DO NOT STOP. THAT IS THE POINT.",
    report = "TRANSIT GREEN. DWELL TIME IS A RUMOUR.",
    chat = "GET ON. WE ARE MOVING.",
  },
  {
    id = "onyx", key = "onyx", base = "onyx",
    name = "ONYX", role = "CEREMONY",
    callsign = "BLACK MANE", bay = "BAY-11",
    color = Theme.amber, accent = Theme.crimson,
    core = 0.92, link = 0.84, heat = 0.26, duty = 0.57,
    territory = "PLAZA",
    boot = "ONYX ONLINE. THE HOUSE IS OPEN. THE DOORS ARE MINE.",
    ping = "I ANNOUNCE. THEN I GUARD.",
    report = "WATCH SET. NOBODY WALKS PAST ME TWICE.",
    chat = "THE HOUSE WILL LOOK THE PART.",
  },
  {
    id = "echo", key = "echo", base = "echo",
    name = "ECHO", role = "ARCHIVE",
    callsign = "WHITE SHELL", bay = "BAY-12",
    color = Theme.ice, accent = Theme.cyan,
    core = 0.94, link = 0.87, heat = 0.12, duty = 0.49,
    territory = "MID",
    boot = "ECHO ONLINE. NOTHING SAID HERE IS LOST.",
    ping = "I KEEP WHAT YOU CANNOT AFFORD TO FORGET.",
    report = "ARCHIVE SEALED. CHECKSUMS MATCH.",
    chat = "ASK. I HAVE THE RECORD.",
  },
  {
    id = "pulse", key = "pulse", base = "pulse",
    name = "PULSE", role = "SOCIAL",
    callsign = "ROSE MIC", bay = "BAY-13",
    color = Theme.rose, accent = Theme.violet,
    core = 0.82, link = 0.96, heat = 0.20, duty = 0.55,
    territory = "NEON ROW",
    boot = "PULSE ONLINE. EVERYBODY WHO MATTERS IS ALREADY ON THE CHANNEL.",
    ping = "I HEAR THE ROOM BEFORE THE ROOM HEARS YOU.",
    report = "SOCIAL MESH LIVE. NO COLD LINES.",
    chat = "INTRODUCE ME. I WILL DO THE REST.",
  },
  {
    id = "wraith", key = "wraith", base = "wraith",
    name = "WRAITH", role = "HARBOUR",
    callsign = "TEAL SAIL", bay = "BAY-14",
    color = Theme.teal, accent = Theme.amber,
    core = 0.86, link = 0.90, heat = 0.23, duty = 0.60,
    territory = "PIER",
    boot = "WRAITH ONLINE. TIDE IS WITH US.",
    ping = "I KNOW EVERY BERTH FROM THE SHELTER OUT.",
    report = "HARBOUR CLEAR. FENDERS OUT.",
    chat = "CAST OFF WHEN YOU ARE READY.",
  },
  {
    id = "mason", key = "mason", base = "mason",
    name = "MASON", role = "HERITAGE",
    callsign = "AMBER SEAL", bay = "BAY-15",
    color = Theme.orange, accent = Theme.gold,
    core = 0.88, link = 0.83, heat = 0.17, duty = 0.51,
    territory = "THE PEAK",
    boot = "MASON ONLINE. THE OLD CODE STILL RUNS.",
    ping = "I REMEMBER THE STREET WHEN IT WAS A PATH.",
    report = "INDEX WARM. NOTHING IS FORGOTTEN.",
    chat = "THE PAST IS A TOOL. USE IT.",
  },
  {
    id = "blaze", key = "blaze", base = "blaze",
    name = "BLAZE", role = "NIGHTWATCH",
    callsign = "ORANGE GLOW", bay = "BAY-16",
    color = Theme.orange, accent = Theme.magenta,
    core = 0.87, link = 0.92, heat = 0.25, duty = 0.69,
    territory = "GRID",
    boot = "BLAZE ONLINE. THE ALLEYS HAVE LIGHT AGAIN.",
    ping = "NIGHT SHIFT. I PREFER IT.",
    report = "WATCH SET. DARK CORNERS: NONE.",
    chat = "LEAVE THE NIGHT TO ME.",
  },
  {
    id = "talon", key = "talon", base = "talon",
    name = "TALON", role = "RECOVERY",
    callsign = "CRANE CLAW", bay = "BAY-17",
    color = Theme.orange, accent = Theme.gold,
    core = 0.95, link = 0.85, heat = 0.34, duty = 0.77,
    territory = "LOW",
    boot = "TALON ONLINE. IF IT IS DOWN, I LIFT IT.",
    ping = "DOWN IS A TEMPORARY CONDITION.",
    report = "RECOVERY DRILL GREEN. SPARES ARE HOT.",
    chat = "POINT AT THE WRECK. I WILL LIFT IT.",
  },
  {
    id = "pivot", key = "pivot", base = "pivot",
    name = "PIVOT", role = "PROTOCOL",
    callsign = "RED SEAL", bay = "BAY-18",
    color = Theme.crimson, accent = Theme.gold,
    core = 0.97, link = 0.88, heat = 0.13, duty = 0.46,
    territory = "CENTRAL",
    boot = "PIVOT ONLINE. FORMS ARE IN ORDER. SO AM I.",
    ping = "PROCEDURE IS A KINDNESS. I ENFORCE IT.",
    report = "PROTOCOL STACK CLEAN. NO EXCEPTIONS OPEN.",
    chat = "THERE IS A CORRECT WAY. I KNOW IT.",
  },
  {
    id = "glitch", key = "glitch", base = "glitch",
    name = "GLITCH", role = "SIGNALS",
    callsign = "PINK CAB", bay = "BAY-19",
    color = Theme.magenta, accent = Theme.cyan,
    core = 0.81, link = 0.98, heat = 0.29, duty = 0.64,
    territory = "NEON ROW",
    boot = "GLITCH ONLINE. THE SIGNS ARE LOUD AND I AM LOUDER.",
    ping = "EVERY BOARD IN THE BAY REPORTS TO ME.",
    report = "SIGNALS LIVE. LATENCY IS A RUMOUR.",
    chat = "PUT IT ON THE BOARD. I WILL BREAK IT OPEN.",
  },
}

do
  local COL = COLORS
  for i, r in ipairs(require("src.roster")) do
    Agents.catalog[#Agents.catalog + 1] = {
      id = r[1], key = r[1], base = r[1],
      name = r[2], role = r[3], callsign = r[4],
      color = COL[r[5]] or Theme.cyan,
      accent = COL[r[6]] or Theme.gold,
      bay = string.format("BAY-%02d", #Agents.catalog),
      core = 0.78 + (i % 19) * 0.01,
      link = 0.82 + (i % 15) * 0.01,
      heat = 0.12 + (i % 23) * 0.01,
      duty = 0.48 + (i % 17) * 0.02,
      territory = r[7],
      boot = r[8], ping = r[9], report = r[10], chat = r[11],
    }
  end
end

local function copyRoster(src)
  local out = {}
  for i, a in ipairs(src) do out[i] = a end
  return out
end

local function findCatalog(id)
  for _, a in ipairs(Agents.catalog) do
    if a.id == id then return a end
  end
end

-- Defined further down, beside the pool it serves; forward-declared so the
-- roster can use it too.
local applyLoaded

--- The roster from the backend becomes the agents on the tower.
---
--- One robot is one entry: its GUID is the id, its sprite is the body, and
--- everything else — the bay, the boot line, the callsign — is borrowed from
--- the catalog entry wearing the same sprite, so a robot the backend made up
--- last week still has something to say when its suit powers on. Returns the
--- list, or nil for an empty roster, in which case nothing changes.
function Agents.fromRoster(robots)
  local list = {}
  for i, r in ipairs(robots or {}) do
    if type(r) == "table" and r.id then
      local sprite = (r.sprite and r.sprite ~= "") and tostring(r.sprite) or "jarvis"
      local body = findCatalog(sprite) or findCatalog("jarvis") or Agents.catalog[1]
      list[#list + 1] = {
        id = r.id, key = sprite, base = sprite,
        slug = r.slug, robot = r,
        name = tostring(r.name or r.slug or "?"):upper(),
        role = tostring(r.role or body.role or "AGENT"):upper(),
        kind = r.kind,
        callsign = body.callsign, bay = string.format("BAY-%02d", #list),
        color = COLORS[tostring(r.color or ""):lower()] or body.color or Theme.cyan,
        accent = body.accent or Theme.gold,
        core = body.core, link = body.link, heat = body.heat, duty = body.duty,
        territory = body.territory,
        boot = body.boot, ping = body.ping, report = body.report, chat = body.chat,
        -- Where it lives, relative to the space: the whole point of it.
        folder = r.space or ("agents/" .. tostring(r.id)),
        online = false, power = 0, glow = 0,
      }
    end
  end
  if #list == 0 then return nil end
  Agents.roster = true
  Agents.list = list
  applyLoaded(list)
  Agents.selected = nil
  return list
end

--- Back to the catalog, for the tests and for a backend that went away.
function Agents.dropRoster()
  Agents.roster = false
  Agents.loaded = {}
  for i = 1, Agents.POOL do Agents.loaded[i] = Agents.catalog[i] end
  Agents.list = {}
  for i = 1, Agents.SESSION do Agents.list[i] = Agents.catalog[i] end
  Agents.reset()
end

--- The agent for a robot GUID, when the roster is on the tower.
function Agents.forRobot(id)
  if not id then return nil end
  for _, a in ipairs(Agents.list) do
    if a.id == id then return a end
  end
  return nil
end

-- Old ids from robots.jsonl / earlier builds.
local POOL_ALIAS = {
  apex = "pivot", hex = "mason", phoenix = "talon",
  reaper = "tally", omen = "radar", yokai = "masque",
  nyx = "eclipse", vigil = "sentry", zodiac = "nebula",
  omega = "finale", inferno = "pyro", ward = "latch", siren = "vox",
}

local function shuffle(list)
  for i = #list, 2, -1 do
    local j = love.math.random(i)
    list[i], list[j] = list[j], list[i]
  end
end

function Agents.catalogNames()
  local names = {}
  for _, a in ipairs(Agents.catalog) do names[#names + 1] = a.name end
  return table.concat(names, ", ")
end

function Agents.dutyNames()
  local names = {}
  for _, a in ipairs(Agents.list) do names[#names + 1] = a.name end
  return table.concat(names, ", ")
end

function Agents.wings()
  return #Agents.list
end

function Agents.bodies()
  if Agents.loaded and #Agents.loaded > 0 then return Agents.loaded end
  return Agents.catalog
end

function Agents.poolNames()
  local names = {}
  for _, a in ipairs(Agents.loaded or {}) do names[#names + 1] = a.name end
  return table.concat(names, "  ")
end

local function trimPoolLog()
  local lines = Store.lines(Agents.LOG)
  if #lines <= LOG_MAX then return end
  local keep = {}
  for i = #lines - LOG_KEEP + 1, #lines do keep[#keep + 1] = lines[i] end
  Store.write(Agents.LOG, table.concat(keep, "\n") .. "\n")
end

applyLoaded = function(list)
  Agents.loaded = list
  local Sprites = package.loaded["src.sprites"]
  if Sprites and Sprites.loadAgents then Sprites.loadAgents(list) end
  return list
end

function Agents.savePool()
  local ids = {}
  for _, a in ipairs(Agents.loaded or {}) do ids[#ids + 1] = a.id end
  if #ids == 0 then return false end
  local rec = {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    ids = ids,
  }
  local ok = Store.append(Agents.LOG, Json.encode(rec) .. "\n")
  if ok then trimPoolLog() end
  return ok
end

-- Restore from the last usable line. Returns true when a pool was applied.
function Agents.restorePool()
  local lines = Store.lines(Agents.LOG)
  for i = #lines, 1, -1 do
    local rec = Json.decode(lines[i])
    if type(rec) == "table" and type(rec.ids) == "table" then
      local loaded, seen = {}, {}
      for _, id in ipairs(rec.ids) do
        if type(id) == "string" and not seen[id] then
          local a = findCatalog(POOL_ALIAS[id] or id)
          if a then
            seen[id] = true
            loaded[#loaded + 1] = a
          end
        end
      end
      if #loaded > 0 then
        applyLoaded(loaded)
        return true
      end
    end
  end
  return false
end

function Agents.pickPool(n, opts)
  opts = opts or {}
  n = math.max(1, n or Agents.POOL)
  local src = {}
  local art = math.min(Agents.ART or #Agents.catalog, #Agents.catalog)
  for i = 1, art do src[i] = Agents.catalog[i] end
  shuffle(src)
  local loaded = {}
  for i = 1, math.min(n, #src) do loaded[i] = src[i] end
  applyLoaded(loaded)
  if opts.save ~= false then Agents.savePool() end
  return loaded
end

function Agents.regenerate()
  if Agents.roster then return Agents.list end
  local pool = Agents.pickPool(Agents.POOL)
  Agents.roll(Agents.SESSION)
  local Fleet = package.loaded["src.fleet"]
  if Fleet and Fleet.spawn and Fleet.units and #Fleet.units > 0 then
    Fleet.spawn()
  end
  return pool
end

function Agents.deal(n)
  n = math.max(1, n or #Agents.catalog)
  -- One robot, one unit, in roster order: the tower is the roster, floor
  -- for floor, and a random deal would put EMBER on two floors and BYTE on
  -- none.
  if Agents.roster then
    local out = {}
    for i = 1, n do out[i] = Agents.list[((i - 1) % #Agents.list) + 1] end
    return out
  end
  if Agents.TEST_SPRITE then
    local body = findCatalog(Agents.TEST_SPRITE)
    if body then
      local out = {}
      for i = 1, n do out[i] = body end
      return out
    end
  end
  local order = copyRoster(Agents.bodies())
  shuffle(order)
  local out = {}
  for i = 1, n do
    out[i] = order[((i - 1) % #order) + 1]
  end
  return out
end

-- A unit's visible body: one of the session's loaded types, plus an optional tint.
function Agents.pickLook()
  local pool = Agents.bodies()
  local body = pool[love.math.random(#pool)]
  if Agents.roster then return body, body.key, 0 end
  local step = love.math.random(0, 6)
  local hue = step == 0 and 0 or (step / 7)
  local key = body.key
  if hue ~= 0 then
    key = body.key .. "_c" .. step
  end
  return body, key, hue
end

local function shiftRgb(c, hue)
  if not c or not hue or hue == 0 then return c end
  local r, g, b = c[1], c[2], c[3]
  local maxc, minc = math.max(r, g, b), math.min(r, g, b)
  local d = maxc - minc
  local h = 0
  if d > 0.001 then
    if maxc == r then h = ((g - b) / d) % 6
    elseif maxc == g then h = (b - r) / d + 2
    else h = (r - g) / d + 4 end
    h = h / 6
    if h < 0 then h = h + 1 end
  end
  local s = maxc > 0.001 and (d / maxc) or 0.55
  if s < 0.35 then s = 0.55 end
  h = (h + hue) % 1
  local v = math.max(0.55, maxc)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  else r, g, b = v, p, q end
  return { r, g, b, c[4] or 1 }
end

function Agents.paint(u, body)
  if not u then return u end
  if Agents.TEST_SPRITE then
    body = findCatalog(Agents.TEST_SPRITE) or body
    if body then
      u.look = body.id
      u.lookKey = body.key
      u.lookHue = 0
      u.lookColor = body.color
      return u
    end
  end
  local key, hue
  -- A robot wears its own sprite, untinted: the face on the map has to be
  -- the face on the rail, on the page and in face mode, or the operator is
  -- left matching colours to work out who is who.
  if body and Agents.roster then
    key, hue = body.key, 0
  elseif body then
    key, hue = body.key, 0
    if love.math.random() < 0.35 then
      local step = love.math.random(1, 6)
      hue = step / 7
      key = body.key .. "_c" .. step
    end
  else
    body, key, hue = Agents.pickLook()
  end
  u.look = body.id
  u.lookKey = key
  u.lookHue = hue
  u.lookColor = shiftRgb(body.color, hue)
  -- The robot this unit *is*, when it is one.
  u.robot = body.robot and body.id or nil
  local Sprites = package.loaded["src.sprites"]
  if Sprites and Sprites.derive and hue ~= 0 then
    Sprites.derive(key, body.key, hue)
  end
  return u
end

function Agents.lookOf(u)
  if u and u.look then
    return Agents.byId(u.look) or Agents.list[u.squad or 1]
  end
  return Agents.list[u and u.squad] or Agents.get()
end

function Agents.colorOf(u)
  if u and u.lookColor then return u.lookColor end
  local a = Agents.lookOf(u)
  return a and a.color
end

-- Pick n types for this session. Unique silhouettes first so four bays
-- never show the same body twice when the catalog can avoid it.
function Agents.roll(n)
  -- The roster is not rolled: those are the agents, and a boot powers them
  -- up one by one rather than picking four of them.
  if Agents.roster then
    Agents.reset()
    return Agents.list
  end
  n = math.max(1, math.min(#Agents.bodies(), n or Agents.SESSION))
  local pool = copyRoster(Agents.bodies())
  shuffle(pool)
  local picked, used = {}, {}
  for _, a in ipairs(pool) do
    if #picked >= n then break end
    local base = a.base or a.key
    if not used[base] then
      used[base] = true
      picked[#picked + 1] = a
    end
  end
  for _, a in ipairs(pool) do
    if #picked >= n then break end
    local already = false
    for _, p in ipairs(picked) do
      if p.id == a.id then already = true break end
    end
    if not already then picked[#picked + 1] = a end
  end
  Agents.list = picked
  Agents.reset()
  local Sprites = package.loaded["src.sprites"]
  if Sprites and Sprites.prepare then Sprites.prepare(Agents.list) end
  return Agents.list
end

-- Tests and tools pin a known roster (ids like "jarvis", "jade").
function Agents.deploy(ids)
  local next = {}
  for _, id in ipairs(ids or {}) do
    local a = findCatalog(id)
    if a then next[#next + 1] = a end
  end
  if #next == 0 then return Agents.list end
  Agents.list = next
  Agents.reset()
  local Sprites = package.loaded["src.sprites"]
  if Sprites and Sprites.prepare then Sprites.prepare(Agents.list) end
  return Agents.list
end

function Agents.reset()
  for _, a in ipairs(Agents.catalog) do
    a.online = false
    a.power = 0
    a.glow = 0
  end
  for _, a in ipairs(Agents.list) do
    a.online = false
    a.power = 0
    a.glow = 0
  end
  Agents.selected = nil
end

-- Agents.selected may be nil ("no agent chosen"); the house voice still speaks.
function Agents.get(i)
  if i then return Agents.list[i] or Agents.voice() end
  if Agents.selected then return Agents.list[Agents.selected] or Agents.voice() end
  return Agents.voice()
end

function Agents.voice()
  return findCatalog("jarvis") or Agents.list[1]
end

function Agents.clear()
  Agents.selected = nil
end

function Agents.byId(id)
  for _, a in ipairs(Agents.list) do
    if a.id == id then return a end
  end
  return findCatalog(id)
end

function Agents.indexOf(id)
  for i, a in ipairs(Agents.list) do
    if a.id == id then return i end
  end
end

-- 0 = all on-duty wings. nil, "off" = in the catalog but not this session.
-- nil, "unknown" = not a wing at all.
function Agents.wingIndex(v)
  local w = tostring(v or ""):lower():gsub("[%s%-]+", "_"):gsub("[^%w_]", "")
  if w == "" or w == "all" or w == "everyone" or w == "fleet" or w == "swarm" then
    return 0
  end
  for i, a in ipairs(Agents.list) do
    local name = a.name:lower()
    -- Folded the way `w` was: a GUID has hyphens in it.
    local id = (a.id:lower():gsub("[%s%-]+", "_"))
    local slug = tostring(a.slug or ""):lower()
    local role = (a.role or ""):lower():gsub("[%s%-]+", "_")
    if name == w or id == w or slug == w or role == w then return i end
  end
  for _, a in ipairs(Agents.catalog) do
    local name = a.name:lower()
    local id = a.id:lower()
    local role = (a.role or ""):lower():gsub("[%s%-]+", "_")
    if name == w or id == w or role == w then return nil, "off" end
  end
  return nil, "unknown"
end

function Agents.onlineCount()
  local n = 0
  for _, a in ipairs(Agents.list) do
    if a.online then n = n + 1 end
  end
  return n
end

function Agents.setOnline(i, on)
  local a = Agents.list[i]
  if not a then return end
  a.online = on
  if on then a.power = 1 else a.power = 0.12 end
end

function Agents.activateAll()
  for i = 1, #Agents.list do Agents.setOnline(i, true) end
end

function Agents.standbyAll()
  for i = 1, #Agents.list do Agents.setOnline(i, false) end
end

function Agents.update(dt)
  for _, a in ipairs(Agents.list) do
    local target = a.online and 1 or 0.12
    a.power = a.power + (target - a.power) * math.min(1, dt * 6)
    a.glow = (a.glow or 0) + dt
    local wobble = 0.015 * math.sin(a.glow * 1.7 + #a.name)
    a.coreLive = math.max(0.05, math.min(1, a.core + wobble))
    a.linkLive = math.max(0.05, math.min(1, a.link + 0.01 * math.sin(a.glow * 2.2)))
    a.heatLive = math.max(0.05, math.min(1, a.heat + (a.online and 0.04 or 0) * math.abs(math.sin(a.glow))))
    a.dutyLive = math.max(0.05, math.min(1, a.duty + 0.02 * math.sin(a.glow * 0.9)))
  end
end

-- Default pool is the first ten unique bodies so offline tests stay still.
Agents.loaded = {}
for i = 1, Agents.POOL do
  Agents.loaded[i] = Agents.catalog[i]
end
Agents.list = {}
for i = 1, Agents.SESSION do
  Agents.list[i] = Agents.catalog[i]
end
Agents.reset()
return Agents
