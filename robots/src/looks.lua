-- Visual looks: which sprite folder the roster wears.
--
-- `theme.lua` is the HUD palette. This is the faces. Three shipped looks,
-- each a jsonl in persistency/, and the one in use is kept in the store
-- (~/.causewaybayjarvis/looks.jsonl) the same way display.jsonl is.

local Store = require("src.store")
local Json = require("src.json")

local Looks = {
  current = "robots",
  LOG = "looks.jsonl",
}

local LOG_MAX = 200
local LOG_KEEP = 40

-- The twelve faces a look must paint. Same ids the backend roster wears.
Looks.ROSTER = {
  { id = "jarvis", name = "JARVIS", role = "CORE BUTLER",   color = "gold" },
  { id = "byte",   name = "BYTE",   role = "CODE WRANGLER", color = "cyan" },
  { id = "ember",  name = "EMBER",  role = "GALLEY CHIEF",  color = "orange" },
  { id = "jade",   name = "JADE",   role = "ARCHIVIST",     color = "jade" },
  { id = "neon",   name = "NEON",   role = "COMMS",         color = "magenta" },
  { id = "iris",   name = "IRIS",   role = "OPTICS",        color = "teal" },
  { id = "tally",  name = "TALLY",  role = "COUNTING HOUSE",color = "lime" },
  { id = "ivy",    name = "IVY",    role = "MEDIC",         color = "green" },
  { id = "orbit",  name = "ORBIT",  role = "NAVIGATOR",     color = "blue" },
  { id = "lumen",  name = "LUMEN",  role = "ATELIER",       color = "yellow" },
  { id = "sentry", name = "SENTRY", role = "WARDEN",        color = "red" },
  { id = "vector", name = "VECTOR", role = "COMPUTER",      color = "violet" },
}

Looks.CATALOG = {
  {
    id = "robots",
    name = "ANIME ROBOT",
    blurb = "SUPER-DEFORMED MECHA. THE HOUSE STYLE.",
    console = "SNES / GENESIS",
    folder = nil,
    sprites = 12,
    persist = "persistency/robots.jsonl",
  },
  {
    id = "tropic",
    name = "TROPIC RUN",
    blurb = "16-BIT VEST, SHORTS, SWORD. GENESIS HEROES.",
    console = "ORIGINAL",
    folder = "assets/themes/tropic",
    sprites = 12,
    persist = "persistency/tropic.jsonl",
  },
  {
    id = "astral",
    name = "ASTRAL WAR",
    blurb = "FEMALE FUTURISTIC WARRIORS. HUMAN LINE.",
    console = "ORIGINAL",
    folder = "assets/themes/astral",
    sprites = 12,
    persist = "persistency/astral.jsonl",
  },
}

function Looks.find(id)
  for _, look in ipairs(Looks.CATALOG) do
    if look.id == id then return look end
  end
end

function Looks.indexOf(id)
  for i, look in ipairs(Looks.CATALOG) do
    if look.id == id then return i end
  end
end

-- Preferred path for a look, with no filesystem fallback.
function Looks.file(lookId, key, flying)
  local look = Looks.find(lookId) or Looks.CATALOG[1]
  local name = "agent_" .. tostring(key) .. (flying and "_fly" or "") .. ".png"
  if look.folder then
    return look.folder .. "/" .. name
  end
  return "assets/" .. name
end

-- Path the current look wants, falling back to the house sprites when a
-- themed sheet is missing (the catalog has a hundred bodies; a look only
-- paints twelve).
function Looks.path(key, flying)
  local preferred = Looks.file(Looks.current, key, flying)
  if Looks.current == "robots" then return preferred end
  if love and love.filesystem and love.filesystem.getInfo then
    if love.filesystem.getInfo(preferred) then return preferred end
    -- A look ships standing sheets only. Flying falls back to that pose
    -- rather than to a robot fly sheet of a different silhouette.
    if flying then
      local stand = Looks.file(Looks.current, key, false)
      if love.filesystem.getInfo(stand) then return stand end
    end
  end
  return Looks.file("robots", key, flying)
end

local function record()
  return {
    at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    id = Looks.current,
  }
end

local function trim()
  local lines = Store.lines(Looks.LOG)
  if #lines <= LOG_MAX then return end
  local keep = {}
  for i = #lines - LOG_KEEP + 1, #lines do keep[#keep + 1] = lines[i] end
  Store.write(Looks.LOG, table.concat(keep, "\n") .. "\n")
end

function Looks.save()
  local ok = Store.append(Looks.LOG, Json.encode(record()) .. "\n")
  if ok then trim() end
  return ok
end

function Looks.load()
  local lines = Store.lines(Looks.LOG)
  for i = #lines, 1, -1 do
    local rec = Json.decode(lines[i])
    if type(rec) == "table" and type(rec.id) == "string" and Looks.find(rec.id) then
      Looks.current = rec.id
      return true
    end
  end
  return false
end

local function reloadSprites()
  local Sprites = package.loaded["src.sprites"]
  local Agents = package.loaded["src.agents"]
  local Robots = package.loaded["src.robots"]
  if not (Sprites and Sprites.reloadAgents) then return end
  local list = nil
  if Agents then
    if Agents.roster and Agents.list and #Agents.list > 0 then
      list = Agents.list
    elseif Agents.loaded and #Agents.loaded > 0 then
      list = Agents.loaded
    end
  end
  if (not list or #list == 0) and Robots and Robots.list then
    local wanted = {}
    for _, r in ipairs(Robots.list) do
      if r.sprite and r.sprite ~= "" then
        wanted[#wanted + 1] = { key = r.sprite, base = r.sprite }
      end
    end
    if #wanted > 0 then list = wanted end
  end
  Sprites.reloadAgents(list)
end

function Looks.apply(id)
  if not Looks.find(id) then return false end
  if Looks.current == id then return true end
  Looks.current = id
  Looks.save()
  reloadSprites()
  return true
end

function Looks.cycle(step)
  local at = Looks.indexOf(Looks.current) or 1
  local n = #Looks.CATALOG
  at = ((at - 1 + (step or 1)) % n) + 1
  return Looks.apply(Looks.CATALOG[at].id)
end

-- Shipped jsonl for a look: one theme record, then one sprite record per
-- roster face. Missing file => empty list.
function Looks.manifest(id)
  local look = Looks.find(id)
  if not look then return nil end
  local body
  if love and love.filesystem and love.filesystem.read then
    body = love.filesystem.read(look.persist)
  end
  if not body then
    local f = io.open(look.persist, "rb")
    if f then body = f:read("*a"); f:close() end
  end
  if not body then return nil end
  local out = {}
  for line in body:gmatch("[^\r\n]+") do
    if line:match("%S") then
      local rec = Json.decode(line)
      if type(rec) == "table" then out[#out + 1] = rec end
    end
  end
  return out
end

function Looks.label()
  local look = Looks.find(Looks.current)
  return look and look.name or "ANIME ROBOT"
end

return Looks
