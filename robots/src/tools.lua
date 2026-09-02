-- Functions the model is allowed to call. Ollama returns tool_calls; each
-- one lands here, moves real units, and answers with one short ASCII line
-- the model can read back to the operator.
--
-- Models paraphrase enums ("return_home" for "home", "UTC" for "utc"), so
-- every argument goes through an alias table before it touches the fleet.

local Agents = require("src.agents")
local Audio = require("src.audio")
local Central = require("src.central")
local Fleet = require("src.fleet")
local FX = require("src.fx")
local Theme = require("src.theme")
local World = require("src.world")

local Tools = {}

local PLACES = "ROOF, HIGH, MID, LOW, LOBBY, GRID, HOME"
local COMMANDS = "SUMMON, HOME, SCATTER, SWEEP, FORM, IDLE, WAKE, HOLD, STANDBY"

Tools.schema = {
  {
    type = "function",
    ["function"] = {
      name = "fleet_command",
      description = "Order the drone swarm to do something. If a unit is locked on the console, " ..
        "the order hits only that unit. If nobody is locked, it hits the whole swarm (or one wing " ..
        "when wing is set). " ..
        "summon launches units to the roof formation, home returns each unit to its own flat, " ..
        "scatter sends them to random flats, sweep runs a low pass across the lobby in ranks, " ..
        "form packs each wing into its own block over the deck, idle sends everyone back to their own " ..
        "floor to walk about, rest and recharge, wake powers units up, hold freezes them in place, " ..
        "standby powers them down.",
      parameters = {
        type = "object",
        properties = {
          command = {
            type = "string",
            enum = { "summon", "home", "scatter", "sweep", "form", "idle", "wake", "hold", "standby" },
            description = "The order to run.",
          },
          wing = {
            type = "string",
            description = "Optional on-duty wing name, or ALL. Off-duty catalog names are rejected.",
          },
        },
        required = { "command" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "move_unit",
      description = "Fly one drone to a place in the tower.",
      parameters = {
        type = "object",
        properties = {
          unit = { type = "integer", description = "Unit number, as in U0012 -> 12." },
          place = {
            type = "string",
            enum = { "roof", "high", "mid", "low", "lobby", "grid", "home" },
            description = "Where to send it.",
          },
        },
        required = { "unit", "place" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "move_fleet",
      description = "Fly every drone (or one wing) to a place in the tower.",
      parameters = {
        type = "object",
        properties = {
          place = {
            type = "string",
            enum = { "roof", "high", "mid", "low", "lobby", "grid", "home" },
            description = "Where to send them.",
          },
          wing = {
            type = "string",
            description = "Optional on-duty wing name, or ALL. Off-duty catalog names are rejected.",
          },
        },
        required = { "place" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "select_unit",
      description = "Lock the console and camera onto one drone.",
      parameters = {
        type = "object",
        properties = {
          unit = { type = "integer", description = "Unit number to lock on." },
        },
        required = { "unit" },
      },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "deselect",
      description = "Let go of the locked drone and the wing scope, so no agent is selected " ..
        "and orders apply to the whole swarm again.",
      parameters = { type = "object", properties = {} },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "fleet_status",
      description = "Read the live swarm state: unit counts, current scope, locked unit, wings.",
      parameters = { type = "object", properties = {} },
    },
  },
  {
    type = "function",
    ["function"] = {
      name = "get_time",
      description = "Current clock time, local to the operator or UTC.",
      parameters = {
        type = "object",
        properties = {
          zone = { type = "string", enum = { "local", "utc", "both" }, description = "Which clock to read." },
        },
      },
    },
  },
}

-- argument normalising ---------------------------------------------------

local CMD_ALIAS = {
  summon = "rally", rally = "rally", launch = "rally", come = "rally",
  home = "home", return_home = "home", ["return"] = "home", recall = "home", dismiss = "home",
  scatter = "scatter", disperse = "scatter", spread = "scatter",
  idle = "idle", rest = "idle", relax = "idle", loiter = "idle", chill = "idle", stand_by_floor = "idle",
  sweep = "sweep", scan = "sweep",
  form = "form", form_up = "form", formation = "form", regroup = "form",
  wake = "wake", activate = "wake", online = "wake", power_on = "wake",
  hold = "hold", stop = "hold", freeze = "hold", halt = "hold",
  standby = "sleep", sleep = "sleep", shutdown = "sleep", power_off = "sleep", offline = "sleep",
}

local PLACE_ALIAS = {
  roof = "ROOF", rooftop = "ROOF", top = "ROOF", sky = "ROOF",
  high = "HIGH", upper = "HIGH",
  mid = "MID", middle = "MID", centre = "MID", center = "MID",
  low = "LOW", lower = "LOW",
  lobby = "LOBBY", ground = "LOBBY", street = "LOBBY",
  grid = "GRID",
}

local function clean(v)
  return tostring(v or ""):lower():gsub("[%s%-]+", "_"):gsub("[^%w_]", "")
end

local function wingReject(v)
  local w, why = Agents.wingIndex(v)
  if w ~= nil then return w end
  if why == "off" then
    return nil, string.format("REJECTED: WING %s IS OFF DUTY THIS SESSION. ON DUTY: %s OR ALL.",
      tostring(v):upper(), Agents.dutyNames())
  end
  return nil, string.format("REJECTED: NO WING %q. ON DUTY: %s OR ALL.",
    tostring(v), Agents.dutyNames())
end

-- World.insideX is a predicate, not a clamp: keep destinations inside the
-- tower shell ourselves.
local function clampX(x)
  return math.max(World.BX + 12, math.min(World.BX + World.BW - 12, x))
end

local function district(name)
  for _, d in ipairs(World.districts or {}) do
    if d.name == name then return d end
  end
end

local function scopeLabel()
  return Fleet.scopeLabel()
end

-- tools ------------------------------------------------------------------

local function toolFleetCommand(args)
  local id = CMD_ALIAS[clean(args.command)]
  if not id then
    return string.format("REJECTED: UNKNOWN COMMAND %q. USE ONE OF: %s.", tostring(args.command), COMMANDS)
  end

  if args.wing ~= nil and args.wing ~= "" then
    local w, err = wingReject(args.wing)
    if err then return err end
    Fleet.setFilter(w)
  end

  Fleet.command(id)
  if id == "wake" and not Fleet.selected then Agents.activateAll() end
  if id == "sleep" and not Fleet.selected then Agents.standbyAll() end

  local Commands = require("src.commands")
  Commands.bump(id)
  local label = (id == "rally" and "SUMMON") or (id == "sleep" and "STANDBY") or id:upper()
  FX.toast(label .. "  " .. scopeLabel(), Theme.gold)
  Audio.play("online")
  return string.format("DONE: %s ON %s. %d OF %d UNITS ONLINE.",
    label, scopeLabel(), Fleet.onlineCount(), Fleet.COUNT)
end

local function sendTo(u, place, i, n)
  if place == "HOME" then
    Fleet.sendHome(u, { quiet = true, noChase = true })
    return true
  end
  local d = district(place)
  if not d then return false end
  local spread = ((i - 1) - (n - 1) * 0.5) * 16
  Fleet.summon(u, clampX(d.x + spread), d.y, { quiet = n > 1, noChase = true })
  return true
end

local function toolMoveUnit(args)
  local n = tonumber(args.unit)
  if not n then return "REJECTED: UNIT MUST BE A NUMBER, AS IN 12 FOR U0012." end
  local u = Fleet.get(math.floor(n))
  if not u then return string.format("REJECTED: NO UNIT U%04d ON THE GRID.", n) end
  if not u.online then
    return string.format("REJECTED: U%04d IS POWERED DOWN. RUN FLEET_COMMAND WAKE FIRST.", u.id)
  end

  local place = clean(args.place) == "home" and "HOME" or PLACE_ALIAS[clean(args.place)]
  if not place then
    return string.format("REJECTED: UNKNOWN PLACE %q. USE ONE OF: %s.", tostring(args.place), PLACES)
  end

  sendTo(u, place, 1, 1)
  World.setChase(u)
  FX.toast(string.format("U%04d  %s", u.id, place), Agents.colorOf(u))
  Audio.play("whoosh")
  return string.format("DONE: U%04d IS FLYING TO %s.", u.id, place)
end

local function toolMoveFleet(args)
  local place = clean(args.place) == "home" and "HOME" or PLACE_ALIAS[clean(args.place)]
  if not place then
    return string.format("REJECTED: UNKNOWN PLACE %q. USE ONE OF: %s.", tostring(args.place), PLACES)
  end

  if args.wing ~= nil and args.wing ~= "" then
    local w, err = wingReject(args.wing)
    if err then return err end
    Fleet.setFilter(w)
  end

  if place == "HOME" then
    local n = Fleet.sendAllHome()
    FX.toast("HOME  " .. scopeLabel(), Theme.magenta)
    return string.format("DONE: %d UNITS HEADING HOME ON %s.", n, scopeLabel())
  end
  if place == "ROOF" then
    local n = Fleet.summonAll()
    FX.toast("ROOF  " .. scopeLabel(), Theme.gold)
    return string.format("DONE: %d UNITS CLIMBING TO THE ROOF FORMATION.", n)
  end

  local moving = {}
  for _, u in ipairs(Fleet.units) do
    if Fleet.inScope(u) and u.online then moving[#moving + 1] = u end
  end
  for i, u in ipairs(moving) do sendTo(u, place, i, #moving) end
  World.chase = nil
  Audio.play("whoosh")
  FX.toast(place .. "  " .. scopeLabel(), Theme.cyan)
  if #moving == 0 then
    return "NOTHING MOVED: NO UNITS ONLINE IN SCOPE " .. scopeLabel() .. ". TRY FLEET_COMMAND WAKE."
  end
  return string.format("DONE: %d UNITS MOVING TO %s ON %s.", #moving, place, scopeLabel())
end

local function toolSelectUnit(args)
  local n = tonumber(args.unit)
  if not n then return "REJECTED: UNIT MUST BE A NUMBER." end
  local u = Fleet.get(math.floor(n))
  if not u then return string.format("REJECTED: NO UNIT U%04d ON THE GRID.", n) end
  Fleet.lock(u)
  u.ctx = Central.query(u, "memory")
  World.focus(u.x, u.y - 16, 1.2, 0.22)
  Audio.play("whoosh")
  local rec = Central.record(u)
  FX.toast("LOCK " .. rec.id, Agents.colorOf(u))
  return string.format("DONE: LOCKED %s. WING %s. SECTOR %s. TASK %s.", rec.id, rec.squad, rec.sector, rec.task)
end

local function toolDeselect()
  local had = Fleet.selected and string.format("U%04d", Fleet.selected.id) or nil
  Fleet.unlock()
  Fleet.setFilter(0)
  World.chase = nil
  FX.toast("DESELECT  //  NO AGENT", Theme.dim)
  Audio.play("toggle")
  if had then
    return string.format("DONE: RELEASED %s. NO AGENT SELECTED, SCOPE %s.", had, scopeLabel())
  end
  return "DONE: NOTHING WAS SELECTED. SCOPE " .. scopeLabel() .. "."
end

local function toolFleetStatus()
  local sel = Fleet.selected
  local parts = {
    string.format("UNITS %d OF %d ONLINE", Fleet.onlineCount(), Fleet.COUNT),
    "SCOPE " .. scopeLabel(),
    string.format("WINGS %d OF %d POWERED", Agents.onlineCount(), #Agents.list),
    "PLACES " .. PLACES,
  }
  if sel then
    local rec = Central.record(sel)
    parts[#parts + 1] = string.format("LOCKED %s WING %s SECTOR %s TASK %s", rec.id, rec.squad, rec.sector, rec.task)
  else
    parts[#parts + 1] = "NO UNIT LOCKED"
  end
  return table.concat(parts, ". ") .. "."
end

local function toolGetTime(args)
  local z = clean(args and args.zone)
  local lt = os.date("%Y-%m-%d %H:%M:%S")
  local ut = os.date("!%Y-%m-%d %H:%M:%S")
  if z == "utc" or z == "gmt" or z == "zulu" then
    return "UTC " .. ut
  end
  if z == "local" or z == "" or z == "here" then
    return "LOCAL " .. lt .. " (" .. os.date("%Z") .. ")"
  end
  return "LOCAL " .. lt .. " (" .. os.date("%Z") .. "). UTC " .. ut .. "."
end

local RUN = {
  fleet_command = toolFleetCommand,
  move_unit = toolMoveUnit,
  move_fleet = toolMoveFleet,
  select_unit = toolSelectUnit,
  deselect = toolDeselect,
  fleet_status = toolFleetStatus,
  get_time = toolGetTime,
}

-- Returns the line handed back to the model, plus a short console label.
function Tools.run(name, args)
  local fn = RUN[tostring(name or "")]
  if not fn then
    local known = {}
    for k in pairs(RUN) do known[#known + 1] = k:upper() end
    table.sort(known)
    return string.format("REJECTED: NO TOOL %q. AVAILABLE: %s.", tostring(name), table.concat(known, ", "))
  end
  if type(args) == "string" then
    args = require("src.json").decode(args)
  end
  if type(args) ~= "table" then args = {} end
  local ok, out = pcall(fn, args)
  if not ok then
    return "FAILED: " .. tostring(out):gsub("%s+", " "):sub(1, 90)
  end
  return out
end

-- One compact line for the console log, e.g. MOVE_FLEET ROOF.
function Tools.label(name, args)
  local bits = { tostring(name or "TOOL"):upper() }
  if type(args) == "table" then
    for _, k in ipairs({ "command", "unit", "place", "wing", "zone" }) do
      if args[k] ~= nil and args[k] ~= "" then bits[#bits + 1] = tostring(args[k]):upper() end
    end
  end
  return table.concat(bits, " ")
end

Tools.PLACES = PLACES
Tools.COMMANDS = COMMANDS

return Tools
