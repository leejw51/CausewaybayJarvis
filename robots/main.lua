local Theme = require("src.theme")
local Layout = require("src.layout")
local Input = require("src.input")
local UI = require("src.ui")
local CRT = require("src.crt")
local Audio = require("src.audio")
local Sprites = require("src.sprites")
local Boot = require("src.boot")
local Dash = require("src.dashboard")
local Chat = require("src.chat")
local Agents = require("src.agents")
local FX = require("src.fx")
local World = require("src.world")
local Tween = require("src.tween")
local Commands = require("src.commands")
local Settings = require("src.settings")
local Ollama = require("src.ollama")
local Autopilot = require("src.autopilot")
local Backend = require("src.backend")
local Robots = require("src.robots")
local AgentPage = require("src.agentpage")
local Face = require("src.face")
local Converse = require("src.converse")
local Fleet = require("src.fleet")

local testing = false
-- boot | dash | page | face. The last two are the robot system: one screen
-- for what a robot *knows*, one for talking to its face and nothing else.
local state = "boot"
local qa = false
local qaBoot, qaDash = false, false
-- QA drives itself through every screen and photographs each one, so `make
-- robots-shots` is a check that the new screens actually draw rather than a
-- promise that they do.
local qaClock, qaStep = 0, 0
local qaAsked = false
local qaShot = {}
local qaSetupAt
-- Where ESC goes back to from a robot screen.
local returnTo = "dash"

local function wantsFace(args)
  if os.getenv("JARVIS_FACE") == "1" then return true end
  for _, a in ipairs(args or {}) do
    if a == "--face" or a == "face" then return true end
  end
  return false
end

local function enterPage()
  returnTo = state == "face" and "face" or "dash"
  state = "page"
  AgentPage.enter()
  Audio.play("whoosh")
end

local function enterFace()
  returnTo = state == "page" and "page" or "dash"
  state = "face"
  Face.enter()
  Audio.play("online")
end

local PROVIDER_TONE = { good = "jade", info = "sky", warn = "crimson" }

local function switchProvider()
  Backend.cycleProvider(function(data, err)
    if err then
      FX.toast("AI  " .. tostring(err):sub(1, 30), Theme.crimson)
      return
    end
    local color = Theme[PROVIDER_TONE[Backend.providerTone()] or "dim"] or Theme.dim
    FX.toast(Backend.providerLabel(), color)
    Audio.play("toggle")
  end)
end

local function enterBoot()
  state = "boot"
  Boot.enter(function()
    state = "dash"
    Dash.enter()
  end)
end

local function wantsTests(args)
  if os.getenv("JARVIS_TEST") == "1" then return true end
  for _, a in ipairs(args or {}) do
    if a == "--test" then return true end
  end
  return false
end

function love.load(args)
  if wantsTests(args) then
    testing = true
    local passed = require("tests.init").run()
    love.event.quit(passed and 0 or 1)
    return
  end

  love.graphics.setDefaultFilter("nearest", "nearest")
  love.graphics.setLineStyle("rough")
  love.graphics.setLineWidth(1)
  love.keyboard.setKeyRepeat(true)
  love.mouse.setVisible(false)
  qa = love.filesystem.getInfo("QA") ~= nil or os.getenv("JARVIS_QA") == "1"
  Sprites.load()
  if not Agents.restorePool() then
    Agents.pickPool(Agents.POOL)
  end
  Sprites.loadAgents(Agents.loaded)
  Audio.load()
  Layout.init()
  Settings.load()
  World.build()
  FX.reset()
  Tween.clear()
  -- Boot reports the link (on-device vs cloud, model, size) once the
  -- spec probe fired here has had time to answer.
  Ollama.init()
  Autopilot.init()

  -- The robot system: one folder, one database, one process to ask.
  -- Everything here degrades rather than fails -- a checkout with no `agentd`
  -- built still boots, and the boot report says why the archive is shut.
  -- Health first, and — when this machine is the brain — the model load
  -- right behind it, so the wait is spent behind the boot screen while the weights
  -- go onto the GPU and the first answer does not pay for them.
  -- The roster *is* the swarm: one robot, one folder, one unit on the
  -- tower. When the backend answers `agents.list`, the catalog drones
  -- stand down and the robots take the floors.
  Robots.watchRoster(function(list)
    if Agents.fromRoster(list) then
      Sprites.loadAgents(Agents.list)
      Dash.roster(Agents.list)
    end
  end)
  if Backend.init() then
    Backend.warmUp()
    Robots.refresh()
  end

  if wantsFace(args) then
    state = "face"
    Face.enter()
  else
    enterBoot()
  end
end

function love.update(dt)
  if testing then return end
  dt = math.min(dt, 0.05)
  Layout.flush()
  CRT.update(dt)
  FX.update(dt)
  Tween.update(dt)
  Ollama.update(dt)
  Backend.update(dt)

  if Input.wasKey("escape") then
    if state == "dash" and Dash.screen == "settings" then
      -- closed in Dash.update
    elseif state == "page" or state == "face" then
      -- handled by the screen itself, which knows where it came from
    elseif state ~= "boot" then
      Audio.play("whoosh")
      enterBoot()
    end
  end

  -- F9 flips which brain answers — auto, on-device, cloud — from anywhere,
  -- mid-conversation included. The setting lives in the backend's space, so
  -- the CLI sees the same answer.
  if Input.wasKey("f9") then
    switchProvider()
  end

  -- The two robot screens are reachable from anywhere, boot included: a
  -- machine whose whole point is the agents should not make you walk through
  -- a dashboard to reach one.
  if Input.wasKey("f2") then
    if state == "page" then state = returnTo else enterPage() end
  end
  if Input.wasKey("f4") then
    if state == "face" then state = returnTo else enterFace() end
  end
  if state ~= "face" and Input.wasKey("f6") then
    Robots.cycle(1)
    FX.toast("AGENT  " .. Robots.name(), Robots.color(Robots.current()))
    Audio.play("toggle")
  end

  if state == "boot" then
    if Input.wasKey("l") or Input.wasKey("f1") then
      Layout.toggleOrientation()
      Audio.play("whoosh")
    end
    if Input.wasKey("f") or Input.wasKey("f11") then
      Layout.toggleFullscreen()
      Audio.play("toggle")
    end
    if Input.wasKey("m") or Input.wasKey("f8") then
      Audio.toggleMute()
    end
    if Input.wasKey("c") or Input.wasKey("f3") then
      Layout.toggleCompact()
      Audio.play("whoosh")
    end
  else
    if Input.wasKey("f1") then
      Layout.toggleOrientation()
      Audio.play("whoosh")
    end
    if Input.wasKey("f11") then
      Layout.toggleFullscreen()
      Audio.play("toggle")
    end
    if Input.wasKey("f8") then
      Audio.toggleMute()
    end
  end

  -- Only once the boot screen has been photographed: the wait is short,
  -- and a clap that beat the shot left the walk one picture short.
  if qa and state == "boot" and Boot.phase == "wait" and Boot.t > 0.55 and qaBoot then
    Boot.clap()
  end

  -- The QA walk: dashboard, then the robot page, then face mode with a line
  -- typed into it, then out. Each step waits long enough for the backend to
  -- have answered, because a screenshot of a half-loaded page proves nothing.
  if qa and state ~= "boot" then
    qaClock = qaClock + dt
    if qaStep == 0 and qaClock > 3.0 then
      qaStep = 1
      -- A page of an empty global space proves nothing: look at a robot.
      if #Robots.list > 0 then Robots.select(Robots.list[1].id) end
      enterPage()
    elseif qaStep == 2 and qaClock > 6.5 then
      qaStep = 3
      Robots.select(nil)
      enterFace()
      Converse.draft = "what should i cook for dinner"
    elseif qaStep == 3 and qaClock > 7.5 and not qaAsked then
      -- Actually ask, so the shot shows a routed robot answering rather than
      -- a face beside an empty pane. With no key this is the offline path,
      -- which is just as worth photographing.
      qaAsked = true
      Converse.send(Converse.draft)
      Converse.draft = ""
    elseif qaStep == 4 and qaClock > 0 and not qaShot.setupOpened then
      -- Last, the setup: SET on the dashboard, AI tab, long enough for the
      -- backend to have answered `config` and probed the daemon.
      qaShot.setupOpened = true
      qaSetupAt = qaClock
      state = "dash"
      Dash.enter()
      Dash.screen = "settings"
      Settings.enter("ai")
    elseif qaStep == 5 then
      love.event.quit(0)
    end
  end

  if state == "boot" then
    Boot.update(dt)
  elseif state == "page" then
    if AgentPage.update(dt) == "back" then
      state = returnTo
      if state == "face" then Face.enter() end
      Audio.play("whoosh")
    end
  elseif state == "face" then
    if Face.update(dt) == "back" then
      state = returnTo == "face" and "dash" or returnTo
      Audio.play("whoosh")
    end
  else
    Dash.update(dt)
    if Input.wasKey("space") and Chat.draft == "" and not Dash.searchFocus and Dash.screen ~= "settings" then
      Commands.run("rally")
    end
    -- The dashboard asks for a screen rather than switching to one itself.
    if Dash.request == "page" then enterPage()
    elseif Dash.request == "face" then enterFace()
    elseif Dash.request == "provider" then switchProvider() end
    Dash.request = nil
  end

  if Input.wasKey("f12") then
    love.graphics.captureScreenshot("shot.png")
  end
end

function love.draw()
  if testing then return end
  Layout.begin()
  UI.begin()
  if state == "boot" then
    Boot.draw()
  elseif state == "page" then
    AgentPage.draw()
  elseif state == "face" then
    Face.draw()
  else
    Dash.draw()
  end
  UI.endFrame()
  CRT.draw()
  FX.drawCursor()
  Layout.finish()
  Layout.flush()
  if qa then
    if state == "boot" and Boot.phase == "wait" and not qaBoot then
      qaBoot = true
      love.graphics.captureScreenshot("qa_boot.png")
    end
    if state == "dash" and Dash.t > 1.8 and not qaDash then
      qaDash = true
      love.graphics.captureScreenshot("qa_dash.png")
    end
    if qaStep == 1 and qaClock > 5.5 and not qaShot.page then
      qaShot.page = true
      qaStep = 2
      love.graphics.captureScreenshot("qa_page.png")
    end
    -- The face is photographed when the answer has actually arrived — an
    -- on-device first turn pays the model load, and a screenshot of the
    -- thinking dots proves nothing. The cap is the give-up, not the plan.
    -- The wait itself: photographed while the answer is still coming, so
    -- a blank face during prefill would show up as a failed shot rather
    -- than as nobody noticing.
    if qaStep == 3 and qaAsked and not qaShot.waiting and Converse.progress then
      qaShot.waiting = true
      love.graphics.captureScreenshot("qa_waiting.png")
    end
    if qaStep == 3 and qaAsked and not qaShot.face
      and ((not Converse.busy and Converse.lastTurn) or qaClock > 80) then
      qaShot.face = true
      qaStep = 4
      love.graphics.captureScreenshot("qa_face.png")
    end
    if qaStep == 4 and qaShot.setupOpened and not qaShot.setup
      and qaClock > (qaSetupAt or 0) + 3.0 then
      qaShot.setup = true
      love.graphics.captureScreenshot("qa_setup.png")
      -- The same screen the other way up, since the two layouts are two
      -- code paths; flipped back after, so the walk leaves the preference
      -- as it found it.
      Layout.toggleOrientation()
      qaSetupAt = qaClock
    elseif qaStep == 4 and qaShot.setup and not qaShot.setupAlt
      and qaClock > (qaSetupAt or 0) + 0.6 then
      qaShot.setupAlt = true
      love.graphics.captureScreenshot("qa_setup_alt.png")
      -- The other tab: the agents, one folder each.
      Settings.enter("tower")
      qaSetupAt = qaClock
    elseif qaStep == 4 and qaShot.setupAlt and not qaShot.agents
      and qaClock > (qaSetupAt or 0) + 0.6 then
      qaShot.agents = true
      love.graphics.captureScreenshot("qa_agents.png")
      -- and the dashboard in this orientation, for its header and rail —
      -- with an agent locked, because the shot has to show that locking
      -- one leaves the other eleven on the tower.
      Dash.screen = "map"
      if Fleet.units[2] then Dash.selectUnit(Fleet.units[2]) end
      qaSetupAt = qaClock
    elseif qaStep == 4 and qaShot.agents and not qaShot.dashAlt
      and qaClock > (qaSetupAt or 0) + 0.6 then
      qaShot.dashAlt = true
      qaStep = 5
      love.graphics.captureScreenshot("qa_dash_alt.png")
      Layout.toggleOrientation()
    end
  end
  Input.begin()
end

function love.mousepressed(x, y, button)
  if button == 1 then Input.mousepressed() end
end

function love.mousereleased(x, y, button)
  if button == 1 then Input.mousereleased() end
end

function love.wheelmoved(dx, dy)
  Input.wheelmoved(dy)
end

function love.keypressed(key)
  Input.keypressed(key)
end

function love.textinput(t)
  if state == "dash" or state == "face" then Input.textinput(t) end
end

-- Dropping a file on the window files it with the robot that is chosen, or in
-- the global space when none is. It is the shortest path there is from "here
-- is a picture" to "the robot can find this", which is the whole point of
-- giving each one a folder.
function love.filedropped(file)
  local path = file and file.getFilename and file:getFilename() or nil
  if not path then return end
  local name = path:match("([^/]+)$") or path
  FX.toast("FILING " .. name:upper():sub(1, 22), Theme.gold)
  Robots.add(path, {}, function(item, err)
    if err then
      FX.toast("REFUSED  " .. tostring(err):sub(1, 26), Theme.crimson)
      return
    end
    FX.toast(tostring(item.kind):upper() .. " -> " .. Robots.name(), Theme.jade)
    Audio.play("online")
    if state == "page" then AgentPage.enter() end
  end)
end

function love.resize()
  -- canvas scale is recomputed each frame
end

function love.quit()
  Ollama.shutdown()
  Backend.shutdown()
end
