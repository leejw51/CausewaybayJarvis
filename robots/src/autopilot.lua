-- The house takes the helm.
--
-- A minute with no hand on the console and JARVIS starts running the swarm
-- himself: one move every twenty seconds or so, chosen the way a bored night
-- butler would choose it — mostly let them idle, occasionally call them up,
-- send them home, look in on one unit. The model picks the move when the link
-- is up (it gets the same tools the operator's chat does); a weighted local
-- script covers for it when the link is down.
--
-- Any keypress, click, scroll or mouse twitch hands control straight back.

local Env = require("src.env")
local Audio = require("src.audio")
local Fleet = require("src.fleet")
local FX = require("src.fx")
local Layout = require("src.layout")
local Ollama = require("src.ollama")
local Theme = require("src.theme")

local Autopilot = {
  timeout = 60,     -- seconds of quiet before the helm changes hands
  idleT = 0,
  active = false,
  enabled = true,
  wait = 0,         -- until the next move
  moves = 0,
  recent = {},      -- what it has done lately, newest last
  mx = nil,
  my = nil,
}

local MIN_GAP, MAX_GAP = 14, 28   -- seconds between moves
local REST_GAP = 34               -- a longer breath after sending them off duty
local FIRST_GAP = 1.5
local HISTORY = 4

-- Weighted fallback, and the rhythm the model is asked to keep: idle most of
-- the time, with the odd summon, and home after a summon.
local SCRIPT = {
  { id = "idle", w = 30 },
  { id = "rally", w = 14 },
  { id = "home", w = 12 },
  { id = "scatter", w = 10 },
  { id = "sweep", w = 8 },
  { id = "form", w = 8 },
  { id = "focus", w = 6 },
  { id = "ping", w = 6 },
}

local FOLLOW = {          -- what tends to come next, like a shift routine
  rally = { "home", "form", "sweep" },
  form = { "home", "rally" },
  sweep = { "home", "idle" },
  scatter = { "idle", "home" },
  home = { "idle", "idle", "ping" },
}

function Autopilot.init()
  local n = tonumber(Env.get("JARVIS_IDLE_SECONDS", "60"))
  Autopilot.timeout = math.max(5, math.min(3600, n or 60))
  Autopilot.reset()
  return Autopilot.timeout
end

function Autopilot.reset()
  Autopilot.idleT = 0
  Autopilot.active = false
  Autopilot.wait = 0
  Autopilot.moves = 0
  Autopilot.recent = {}
  Autopilot.mx, Autopilot.my = nil, nil
end

function Autopilot.remaining()
  return math.max(0, Autopilot.timeout - Autopilot.idleT)
end

-- "AUTO 0:47" while counting down, "AUTOPILOT" once it has the helm.
function Autopilot.label()
  if not Autopilot.enabled then return "AUTO OFF" end
  if Autopilot.active then return "AUTOPILOT" end
  local left = math.ceil(Autopilot.remaining())
  return string.format("AUTO %d:%02d", math.floor(left / 60), left % 60)
end

function Autopilot.color()
  if not Autopilot.enabled then return Theme.dim end
  if Autopilot.active then return Theme.magenta end
  if Autopilot.remaining() < 10 then return Theme.amber end
  return Theme.teal
end

local function say(who, text, key)
  local Chat = require("src.chat")
  Chat.push(who, text, key or "teal")
end

function Autopilot.start()
  if Autopilot.active then return end
  Autopilot.active = true
  Autopilot.wait = FIRST_GAP
  Autopilot.moves = 0
  say("AUTO", "NO HAND ON THE CONSOLE. I HAVE THE HELM, SIR.", "teal")
  FX.toast("AUTOPILOT  //  JARVIS HAS THE HELM", Theme.magenta)
  Audio.play("sting", 0.9, 0.6)
end

function Autopilot.stop(quiet)
  Autopilot.idleT = 0
  if not Autopilot.active then return end
  Autopilot.active = false
  Autopilot.wait = 0
  if not quiet then
    say("AUTO", "HELM IS YOURS AGAIN, SIR.", "teal")
    FX.toast("MANUAL  //  OPERATOR BACK", Theme.teal)
    Audio.play("toggle")
  end
end

-- Any deliberate touch of the console hands control back.
function Autopilot.poke()
  Autopilot.stop()
end

function Autopilot.toggle()
  Autopilot.enabled = not Autopilot.enabled
  if not Autopilot.enabled then Autopilot.stop(true) end
  Autopilot.idleT = 0
  Audio.play("click")
  FX.toast(Autopilot.enabled and "AUTOPILOT ARMED" or "AUTOPILOT OFF",
    Autopilot.enabled and Theme.teal or Theme.dim)
  return Autopilot.enabled
end

local function lastMove()
  return Autopilot.recent[#Autopilot.recent]
end

local function note(id)
  Autopilot.recent[#Autopilot.recent + 1] = id
  while #Autopilot.recent > HISTORY do table.remove(Autopilot.recent, 1) end
end

local function gapFor(id)
  if id == "idle" then return REST_GAP + love.math.random() * 12 end
  return MIN_GAP + love.math.random() * (MAX_GAP - MIN_GAP)
end

-- Weighted pick that never repeats the last move and leans on the routine.
function Autopilot.pick()
  local last = lastMove()
  local follow = last and FOLLOW[last]
  if follow and love.math.random() < 0.55 then
    local id = follow[love.math.random(1, #follow)]
    if id ~= last then return id end
  end

  local total = 0
  for _, c in ipairs(SCRIPT) do
    if c.id ~= last then total = total + c.w end
  end
  local roll = love.math.random() * total
  for _, c in ipairs(SCRIPT) do
    if c.id ~= last then
      roll = roll - c.w
      if roll <= 0 then return c.id end
    end
  end
  return "idle"
end

-- What the swarm is doing right now, in a line the model can reason about.
function Autopilot.context()
  local Central = require("src.central")
  local idle, flying = 0, 0
  for _, u in ipairs(Fleet.units) do
    if u.idle then idle = idle + 1 end
    if u.phase == "fly" or u.phase == "wait" or u.phase == "hover" then flying = flying + 1 end
  end

  local away = math.floor(Autopilot.idleT)
  local bits = {
    string.format("The operator has been away for %d minutes %d seconds.",
      math.floor(away / 60), away % 60),
    "Local time is " .. os.date("%H:%M") .. ".",
    string.format("Fleet: %d of %d units online, %d off duty on their floors, %d in the air, scope %s.",
      Fleet.onlineCount(), Fleet.COUNT, idle, flying, Fleet.scopeLabel()),
  }
  if Fleet.selected then
    bits[#bits + 1] = "Locked unit: " .. Central.record(Fleet.selected).id .. "."
  else
    bits[#bits + 1] = "No unit is locked."
  end
  if #Autopilot.recent > 0 then
    bits[#bits + 1] = "Your last moves, oldest first: " .. table.concat(Autopilot.recent, ", ") .. "."
  else
    bits[#bits + 1] = "This is your first move of the watch."
  end
  return table.concat(bits, " ")
end

local PROMPT = table.concat({
  "You have the helm while the operator is away.",
  "Make exactly one move now, the way a night-shift butler would: mostly let the swarm idle on",
  "their own floors, now and then call them up to the roof, send them home afterwards, and",
  "occasionally scatter, sweep, form up, or look in on a single unit.",
  "Do not repeat your last move. Call exactly one tool, then report it in one short sentence.",
}, " ")

-- Run the local script: pick a command chip and press it.
function Autopilot.localStep()
  local Commands = require("src.commands")
  local id = Autopilot.pick()
  note(id)
  Autopilot.moves = Autopilot.moves + 1
  Commands.run(id)
  Autopilot.wait = gapFor(id)
  return id
end

function Autopilot.step()
  if Ollama.available() then
    local Chat = require("src.chat")
    -- the move is recorded when the tool actually runs, in recordTool
    Autopilot.moves = Autopilot.moves + 1
    Chat.auto(PROMPT .. " " .. Autopilot.context())
    Autopilot.wait = MIN_GAP + love.math.random() * (MAX_GAP - MIN_GAP)
    return "model"
  end
  return Autopilot.localStep()
end

-- Called by the autopilot's own tool runs so the routine remembers itself.
function Autopilot.recordTool(name, args)
  if not Autopilot.active then return end
  local id = name
  if name == "fleet_command" and type(args) == "table" and args.command then
    id = tostring(args.command):lower()
  end
  note(id)
  if id == "idle" then Autopilot.wait = math.max(Autopilot.wait, gapFor("idle")) end
end

function Autopilot.update(dt, touched)
  local Chat = require("src.chat")

  -- a moved mouse counts as a hand on the console
  local mx, my = Layout.mouse()
  if mx and Autopilot.mx then
    if math.abs(mx - Autopilot.mx) > 2 or math.abs(my - Autopilot.my) > 2 then
      touched = true
    end
  end
  Autopilot.mx, Autopilot.my = mx, my

  if touched then
    Autopilot.poke()
    return
  end
  if not Autopilot.enabled then
    Autopilot.idleT = 0
    return
  end

  Autopilot.idleT = Autopilot.idleT + dt
  if not Autopilot.active then
    if Autopilot.idleT >= Autopilot.timeout then Autopilot.start() end
    return
  end

  -- never talk over a reply that is still landing
  if Chat.busy() or Ollama.busy() then return end
  Autopilot.wait = Autopilot.wait - dt
  if Autopilot.wait <= 0 then Autopilot.step() end
end

return Autopilot
