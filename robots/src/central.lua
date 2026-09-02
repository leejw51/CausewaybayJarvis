-- Mock Central. The database lives here. Flying units keep only a tiny
-- context window and query Central when they need facts, tasks, or memory.

local Agents = require("src.agents")

local Central = {
  ready = true,
  queries = 0,
  tasks = {},
}

local TASKS = {
  "PATROL SECTOR", "ESCORT FERRY", "SCAN ROOFTOPS", "HOLD PERIMETER",
  "RELAY COMMS", "MAP THERMALS", "WATCH HARBOUR", "GRID SWEEP",
  "NEON WATCH", "PEAK OVERWATCH", "CAUSEWAY FLOW", "HANGAR GUARD",
}

local function tag(id)
  return string.format("U%04d", id)
end

local function districtName(unit)
  local World = require("src.world")
  local best, bd = "GRID", 1e12
  for _, d in ipairs(World.districts or {}) do
    local dx, dy = unit.x - d.x, unit.y - d.y
    local dd = dx * dx + dy * dy
    if dd < bd then best, bd = d.name, dd end
  end
  return best
end

function Central.reset()
  Central.queries = 0
  Central.tasks = {}
  Central.houses = {}
  Central.ready = true
end

function Central.assign(id, squad, house)
  local t
  if house and house.job then
    t = house.job
  else
    t = TASKS[((id * 7 + squad * 3) % #TASKS) + 1]
  end
  Central.tasks[id] = t
  Central.houses = Central.houses or {}
  Central.houses[id] = house and house.name or nil
  return t
end

function Central.query(unit, kind)
  Central.queries = Central.queries + 1
  local squad = Agents.list[unit.squad]
  local task = Central.tasks[unit.id] or Central.assign(unit.id, unit.squad)
  if kind == "memory" then
    return {
      "LAST PING " .. os.date("%H:%M:%S"),
      "TASK " .. task,
      "NO LOCAL ARCHIVE  //  CENTRAL HOLDS MEMORY",
    }
  end
  return string.format("%s  %s  TASK %s  CTX 3 SLOTS  DB LIVE", tag(unit.id), squad.name, task)
end

function Central.record(unit)
  Central.queries = Central.queries + 1
  local squad = Agents.list[unit.squad]
  local task = Central.tasks[unit.id] or Central.assign(unit.id, unit.squad)
  return {
    id = tag(unit.id),
    squad = squad and squad.name or "?",
    role = squad and squad.role or "UNIT",
    task = task,
    house = unit.house and unit.house.name or (Central.houses and Central.houses[unit.id]) or "STREET",
    job = unit.house and unit.house.job or task,
    sector = districtName(unit),
    mem = 3,
    link = Central.ready and "LIVE" or "DOWN",
  }
end

function Central.summary()
  local Fleet = require("src.fleet")
  local n = Fleet.onlineCount()
  return string.format(
    "CENTRAL DB LIVE. %d/%d UNITS HARNESSED. %d QUERIES THIS SESSION. AGENTS HOLD CONTEXT ONLY.",
    n, Fleet.COUNT, Central.queries
  )
end

function Central.mockReply(msg, unit)
  Central.queries = Central.queries + 1
  local m = msg:lower()
  local rec = unit and Central.record(unit)
  local squad = unit and Agents.list[unit.squad]
  local name = squad and squad.name or "JARVIS"
  local Fleet = require("src.fleet")

  if m:find("hey") or m:find("hello") or m:find("hi") or m:find("jarvis") then
    return "ALWAYS, SIR. " .. Fleet.onlineCount() .. " UNITS ON THE GRID. SAY THE WORD."
  end
  if m:find("who") or m:find("what are you") then
    return "J.A.R.V.I.S.  CAUSEWAY BAY NODE 02. I AM THE HARNESS. THEY ARE THE HANDS."
  end
  if rec and (m:find("you") or m:find("this") or m:find("unit")) then
    return string.format("%s  %s  %s  //  %s. MEMORY IS MINE, CONTEXT IS THEIRS.", rec.id, rec.squad, rec.sector, rec.task)
  end
  return string.format("LOGGED. CENTRAL FILED UNDER %s. %s", name, rec and rec.task or "STANDBY")
end

return Central
