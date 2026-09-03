-- Frequent commands as buttons, sorted by live usage. Mock AI behind each one.
local Theme = require("src.theme")
local Audio = require("src.audio")
local FX = require("src.fx")
local Fleet = require("src.fleet")
local World = require("src.world")
local Agents = require("src.agents")
local Central = require("src.central")
local Ease = require("src.ease")
local Actions = require("src.actions")

local Commands = {
  list = {},
  lastPoint = nil,
}

local function reply(text)
  local Chat = require("src.chat")
  local agent
  if Fleet.selected then
    agent = Agents.lookOf(Fleet.selected)
  else
    local v = Agents.voice()
    agent = { name = "AI", id = v.id, color = v.color }
  end
  Chat.reply(text, agent)
end

local function bumpChip(cmd)
  cmd.uses = cmd.uses + 1
end

-- The archive chips: the same actions the console words run, said back
-- on the console. A tone becomes one of the console's colours.
local TONE = { good = "jade", warn = "crimson", info = "cyan" }
local function sayOnConsole(text, tone)
  local Chat = require("src.chat")
  Chat.push("SYS", text, TONE[tone] or "cyan")
end

local function archiveChip(id)
  return function()
    Audio.play("blip")
    Actions.run(id, nil, sayOnConsole)
  end
end

local function execStatus()
  reply(Central.summary(), 1)
  FX.toast("STATUS  //  CENTRAL", Theme.cyan)
end

local function execReport()
  local u = Fleet.selected or Fleet.hero(Agents.selected)
  if not u then
    reply("NO UNIT LOCKED. CLICK THE SWARM, SIR.", 1)
    return
  end
  local rec = Central.record(u)
  u.ctx = Central.query(u, "memory")
  reply(string.format("%s REPORT. %s. SECTOR %s. TASK %s. CTX ONLY, DB ON CENTRAL.", rec.id, rec.squad, rec.sector, rec.task), u.squad)
  FX.toast("REPORT  " .. rec.id, Agents.colorOf(u))
end

local function execRally(pt)
  local n = Fleet.command("rally")
  reply(string.format("%s LAUNCHING. ROOF FORMATION.", Fleet.scopeLabel()), 1)
  FX.toast("SUMMON  " .. n, Theme.gold)
end

local function execHome()
  local n = Fleet.command("home")
  reply(string.format("HOME. %s RETURNS TO FLOOR AND FLAT.", Fleet.scopeLabel()), 2)
  FX.toast("HOME  " .. n, Theme.magenta)
end

local function execScatter()
  local n = Fleet.command("scatter")
  reply(string.format("SCATTER. %s FLY TO RANDOM FLATS.", Fleet.scopeLabel()), 3)
  FX.toast("SCATTER  " .. n, Theme.cyan)
end

local function execIdle()
  Fleet.command("idle")
  reply("IDLE. " .. Fleet.scopeLabel() .. " ON THEIR OWN FLOORS. WALKING, RESTING, CHARGING.", 3)
  FX.toast("IDLE  " .. Fleet.scopeLabel(), Theme.teal)
end

local function execSweep()
  Fleet.command("sweep")
  Audio.play("scan")
  reply("SWEEP. " .. Fleet.scopeLabel() .. " RUNNING THE LOBBY IN RANKS.", 4)
  FX.toast("SWEEP  " .. Fleet.scopeLabel(), Theme.cyan)
end

local function execForm()
  Fleet.command("form")
  Audio.play("online")
  reply("FORM UP. " .. Fleet.scopeLabel() .. " IN WING BLOCKS OVER THE DECK.", 1)
  FX.toast("FORM  " .. Fleet.scopeLabel(), Theme.gold)
  FX.kick(3)
end

local function execWake()
  local n = Fleet.command("wake")
  if not Fleet.selected then Agents.activateAll() end
  Audio.play("sting", 1.1, 0.6)
  FX.wave(World.hangarX, World.hangarY, Theme.jade, 160)
  FX.kick(5)
  reply("WAKE " .. Fleet.scopeLabel() .. ". " .. n .. " UNITS LIVE.", 1)
  FX.toast("WAKE  " .. Fleet.scopeLabel(), Theme.jade)
end

local function execHold()
  Fleet.command("hold")
  Audio.play("alert")
  reply("HOLD " .. Fleet.scopeLabel() .. ". JETS TO IDLE.", 5)
  FX.toast("HOLD  " .. Fleet.scopeLabel(), Theme.amber)
end

local function execSleep()
  Fleet.command("sleep")
  if not Fleet.selected then Agents.standbyAll() end
  Audio.play("alert")
  reply("STANDBY " .. Fleet.scopeLabel() .. ". CENTRAL KEEPS THE BOOKS.", 1)
  FX.toast("STANDBY  " .. Fleet.scopeLabel(), Theme.crimson)
end

local function execPing()
  local u = Fleet.selected or Fleet.hero(Agents.selected)
  Audio.play("scan")
  if u then
    local rec = Central.record(u)
    FX.wave(u.x, u.y, Agents.colorOf(u), 40)
    reply(string.format("%s ACK. LINK %s. %s.", rec.id, rec.link, rec.task), u.squad)
    FX.toast("PING " .. rec.id, Agents.colorOf(u))
  else
    reply("SIX COMMANDERS PING CLEAN. SWARM HEARTBEAT NOMINAL.", 1)
    FX.toast("PING GRID", Theme.cyan)
  end
end

local function execHello()
  Audio.play("blip")
  reply(Agents.roster
    and string.format("ALWAYS, SIR. %d AI AGENTS. %d FLOORS. ONE FOLDER EACH.", Fleet.COUNT, Fleet.COUNT)
    or string.format("ALWAYS, SIR. %d AGENTS. %d FLOORS. ONE ROBOT PER FLAT.", Fleet.COUNT, Fleet.COUNT), 1)
  FX.toast("HEY JARVIS", Theme.gold)
end

local function execFocus()
  local u = Fleet.selected or Fleet.hero(Agents.selected)
  if not u then
    World.focus(World.hangarX, World.SKY - 8, 1.08, 0.5)
    reply("CENTERING ON THE ROOF.", 1)
    return
  end
  World.setChase(u)
  Audio.play("whoosh")
  reply("LOCKING CAMERA ON " .. Fleet.tag(u) .. ".", u.squad)
  FX.toast("FOCUS", Agents.colorOf(u))
end

function Commands.init()
  Commands.list = {
    { id = "rally",  label = "SUMMON",  uses = 11, stroke = Theme.gold,    exec = execRally },
    { id = "home",   label = "HOME",    uses = 10, stroke = Theme.magenta, exec = execHome },
    { id = "scatter",label = "SCATTER", uses = 9,  stroke = Theme.cyan,    exec = execScatter },
    { id = "wake",   label = "WAKE",    uses = 8,  stroke = Theme.jade,    exec = execWake },
    { id = "sweep",  label = "SWEEP",   uses = 7,  stroke = Theme.cyan,    exec = execSweep },
    { id = "idle",   label = "IDLE",    uses = 7,  stroke = Theme.teal,    exec = execIdle },
    { id = "form",   label = "FORM UP", uses = 6,  stroke = Theme.teal,    exec = execForm },
    { id = "status", label = "STATUS",  uses = 5,  stroke = Theme.ice,     exec = execStatus },
    { id = "ping",   label = "PING",    uses = 4,  stroke = Theme.cyan,    exec = execPing },
    { id = "focus",  label = "FOCUS",   uses = 3,  stroke = Theme.gold,    exec = execFocus },
    { id = "hold",   label = "HOLD",    uses = 3,  stroke = Theme.amber,   exec = execHold },
    { id = "report", label = "REPORT",  uses = 2,  stroke = Theme.paper,   exec = execReport },
    { id = "hello",  label = "HEY J",   uses = 2,  stroke = Theme.gold,    exec = execHello },
    { id = "sleep",  label = "STANDBY", uses = 1,  stroke = Theme.crimson, exec = execSleep },
    -- The archive: what the chosen agent is shown, given, and drawn as.
    { id = "photo",  label = "PHOTO",   uses = 6,  stroke = Theme.cyan,    exec = archiveChip("photo") },
    { id = "file",   label = "FILE",    uses = 5,  stroke = Theme.amber,   exec = archiveChip("file") },
    { id = "gallery",label = "GALLERY", uses = 4,  stroke = Theme.cyan,    exec = archiveChip("gallery") },
    { id = "paper",  label = "PAPER",   uses = 4,  stroke = Theme.paper,   exec = archiveChip("paper") },
  }
  for _, c in ipairs(Commands.list) do
    c.x = 0
    c.y = 0
    c.tx = 0
    c.ty = 0
  end
  Commands.sort()
end

function Commands.sort()
  table.sort(Commands.list, function(a, b)
    if a.uses == b.uses then return a.label < b.label end
    return a.uses > b.uses
  end)
end

function Commands.run(id, extra)
  local cmd
  for _, c in ipairs(Commands.list) do
    if c.id == id then cmd = c break end
  end
  if not cmd then return end
  bumpChip(cmd)
  Commands.sort()
  cmd.exec(extra)
end

-- A tool call drives the same action a chip does, so it should age the
-- chip order the same way.
function Commands.bump(id)
  for _, c in ipairs(Commands.list) do
    if c.id == id then
      bumpChip(c)
      Commands.sort()
      return true
    end
  end
  return false
end

function Commands.findUnit(n)
  local u = Fleet.get(n)
  if not u then
    reply("NO UNIT U" .. string.format("%04d", n) .. " ON THE GRID.", 1)
    return
  end
  Fleet.lock(u)
  u.ctx = Central.query(u, "memory")
  World.focus(u.x, u.y - 16, 1.2, 0.22)
  Audio.play("whoosh")
  local rec = Central.record(u)
  reply(string.format("FOUND %s. %s  %s. ZOOMING.", rec.id, rec.squad, rec.task), u.squad)
  FX.toast("LOCK " .. rec.id, Agents.colorOf(u))
  FX.wave(u.x, u.y, Agents.colorOf(u), 50)
end

function Commands.fromText(msg)
  local m = msg:lower()
  -- The archive words are exact: `photo` opens the box, `photo of a cat`
  -- is a sentence. `Actions.parse` knows the difference.
  local action = Actions.parse(msg)
  if action and action ~= "search" then return action end
  if m:find("summon") or m:find("rally") or m:find("come") or m:find("here") or m:find("launch") then return "rally" end
  if m:find("home") or m:find("return") or m:find("dismiss") then return "home" end
  if m:find("scatter") or m:find("spread") or m:find("disperse") then return "scatter" end
  if m:find("idle") or m:find("relax") or m:find("rest") or m:find("chill") then return "idle" end
  if m:find("sweep") or m:find("scan") then return "sweep" end
  if m:find("form") or m:find("wing") then return "form" end
  if m:find("wake") or m:find("online") or m:find("activate") or m:find("all on") then return "wake" end
  if m:find("standby") or m:find("sleep") or m:find("all off") then return "sleep" end
  if m:find("hold") or m:find("stop") or m:find("wait") then return "hold" end
  if m:find("status") then return "status" end
  if m:find("report") then return "report" end
  if m:find("ping") then return "ping" end
  if m:find("focus") or m:find("zoom") then return "focus" end
  if m:find("hello") or m:find("hey") or m:find("hi") or m:find("jarvis") then return "hello" end
  return nil
end

function Commands.update(dt)
  for _, c in ipairs(Commands.list) do
    c.x = Ease.smooth(c.x or c.tx, c.tx, dt, 14)
    c.y = Ease.smooth(c.y or c.ty, c.ty, dt, 14)
  end
end

function Commands.reset()
  Commands.init()
end

Commands.init()
return Commands
