-- The functions the model is allowed to call. Every case checks the string
-- handed back to the model AND what actually happened to the swarm.
local Tools = require("src.tools")
local Fleet = require("src.fleet")
local World = require("src.world")
local Agents = require("src.agents")
local Central = require("src.central")
local Json = require("src.json")
local Tween = require("src.tween")

local function reset()
  -- idle life, scatter and flight jitter all draw from love.math; seed it so
  -- a behaviour test cannot pass or fail by luck
  love.math.setRandomSeed(20260901)
  if not World.ready then World.build() end
  Fleet.spawn()
  Fleet.setFilter(0)
  Fleet.selected = nil
  Central.reset()
  for _, u in ipairs(Fleet.units) do
    u.online = true
    Central.assign(u.id, u.squad)
  end
  Agents.activateAll()
end

local function districtY(name)
  for _, d in ipairs(World.districts or {}) do
    if d.name == name then return d.y end
  end
end

local function countAtY(y, squad)
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if (not squad or u.squad == squad) and u.destY and math.abs(u.destY - y) < 1 then
      n = n + 1
    end
  end
  return n
end

local function homeCount()
  local n = 0
  for _, u in ipairs(Fleet.units) do
    if u.destY == u.homeY and u.destX == u.homeX then n = n + 1 end
  end
  return n
end

return function(t)
  t.describe("tools / schema")

  t.it("declares every tool the briefing promises", function()
    local names = {}
    for _, decl in ipairs(Tools.schema) do
      t.eq(decl.type, "function")
      local f = decl["function"]
      t.ok(f.name, "a tool needs a name")
      t.ok(f.description and #f.description > 10, f.name .. " needs a description the model can act on")
      t.eq(f.parameters.type, "object")
      names[f.name] = f
    end
    for _, want in ipairs({ "fleet_command", "move_unit", "move_fleet", "select_unit",
        "deselect", "fleet_status", "get_time" }) do
      t.ok(names[want], "missing tool " .. want)
    end
    -- required arguments have to exist in properties or the model cannot fill them
    for name, f in pairs(names) do
      for _, req in ipairs(f.parameters.required or {}) do
        t.ok(f.parameters.properties[req], name .. " requires " .. req .. " but never declares it")
      end
    end
  end)

  t.it("survives the JSON round trip the request makes", function()
    local back = Json.decode(Json.encode({ tools = Tools.schema }))
    t.eq(#back.tools, #Tools.schema)
    t.eq(back.tools[1]["function"].name, Tools.schema[1]["function"].name)
    t.has(Json.encode(Tools.schema), '"properties":{}', "fleet_status takes no arguments")
    t.has(Json.encode(Tools.schema), '"enum":["summon"', "the model is shown the legal commands")
  end)

  t.describe("tools / fleet_command")

  t.it("sends the whole swarm home and says so", function()
    reset()
    Tools.run("fleet_command", { command = "summon" })
    t.eq(homeCount(), 0, "everyone is off the roof first")

    local out = Tools.run("fleet_command", { command = "home" })
    t.has(out, "DONE")
    t.has(out, "HOME")
    t.eq(homeCount(), Fleet.COUNT, "every unit is routed back to its own flat")
  end)

  t.it("summons the swarm to the roof", function()
    reset()
    local out = Tools.run("fleet_command", { command = "summon" })
    t.has(out, "DONE")
    local roof = 0
    for _, u in ipairs(Fleet.units) do
      if u.destY and u.destY <= World.SKY + 8 then roof = roof + 1 end
    end
    t.eq(roof, Fleet.COUNT, "all units head for the roof formation")
  end)

  t.it("accepts the aliases the model invents", function()
    reset()
    -- gpt-oss really does answer with return_home for the home command
    local out = Tools.run("fleet_command", { command = "return_home" })
    t.has(out, "DONE")
    t.eq(homeCount(), Fleet.COUNT)

    reset()
    t.has(Tools.run("fleet_command", { command = "Power Off" }), "DONE")
    t.eq(Fleet.units[1].online, false, "power off is standby")
  end)

  t.it("rejects a command it does not have, and lists the real ones", function()
    reset()
    local out = Tools.run("fleet_command", { command = "self_destruct" })
    t.has(out, "REJECTED")
    t.has(out, "SUMMON")
    t.has(out, "SCATTER")
    t.eq(homeCount(), Fleet.COUNT, "nothing moved: units are still at home where spawn left them")
  end)

  t.it("scopes an order to one wing", function()
    reset()
    local out = Tools.run("fleet_command", { command = "hold", wing = "neon" })
    t.has(out, "DONE")
    t.eq(Fleet.filter, 2, "the console scope follows the order")
    t.has(out, "NEON")
  end)

  t.it("a locked unit takes the order alone", function()
    reset()
    Fleet.selected = Fleet.get(12)
    local out = Tools.run("fleet_command", { command = "summon" })
    t.has(out, "DONE")
    t.has(out, "U0012")
    t.ok(Fleet.get(12).destY <= World.SKY + 8, "the locked unit heads for the roof")
    t.eq(Fleet.get(13).destY, Fleet.get(13).homeY, "nobody else moved")
    t.eq(Fleet.scopeN(), 1)
  end)

  t.it("with nobody locked the order hits the whole swarm", function()
    reset()
    Fleet.selected = nil
    Tools.run("fleet_command", { command = "summon" })
    local roof = 0
    for _, u in ipairs(Fleet.units) do
      if u.destY and u.destY <= World.SKY + 8 then roof = roof + 1 end
    end
    t.eq(roof, Fleet.COUNT)
  end)

  t.it("rejects an unknown wing without touching the scope", function()
    reset()
    Fleet.setFilter(0)
    local out = Tools.run("fleet_command", { command = "home", wing = "penguin" })
    t.has(out, "REJECTED")
    t.has(out, "JARVIS")
    t.eq(Fleet.filter, 0, "a bad wing leaves the scope alone")
  end)

  t.it("powers the swarm down and back up", function()
    reset()
    t.has(Tools.run("fleet_command", { command = "standby" }), "DONE")
    t.eq(Fleet.units[1].online, false)
    t.eq(Agents.onlineCount(), 0, "the wing commanders go dark too")

    local out = Tools.run("fleet_command", { command = "wake" })
    t.has(out, "DONE")
    t.eq(Fleet.units[1].online, true)
    t.eq(Agents.onlineCount(), #Agents.list)
  end)

  t.describe("tools / move")

  t.it("flies one unit to the roof", function()
    reset()
    local out = Tools.run("move_unit", { unit = 12, place = "roof" })
    t.has(out, "DONE")
    t.has(out, "U0012")
    local u = Fleet.get(12)
    t.ok(u.destY <= World.SKY + 8, "unit 12 is bound for the roof")
    t.eq(Fleet.get(13).destY, Fleet.get(13).homeY, "nobody else moved")
  end)

  t.it("flies one unit to a named floor and back home", function()
    reset()
    t.has(Tools.run("move_unit", { unit = 5, place = "lobby" }), "DONE")
    t.near(Fleet.get(5).destY, districtY("LOBBY"), 1)

    t.has(Tools.run("move_unit", { unit = 5, place = "home" }), "DONE")
    t.eq(Fleet.get(5).destY, Fleet.get(5).homeY)
  end)

  t.it("keeps destinations inside the tower", function()
    reset()
    Tools.run("move_fleet", { place = "mid" })
    for _, u in ipairs(Fleet.units) do
      t.ok(type(u.destX) == "number", "destX must stay a number, never a predicate result")
      t.ok(u.destX > World.BX and u.destX < World.BX + World.BW, "unit " .. u.id .. " left the shell")
    end
  end)

  t.it("refuses to fly a powered-down unit and says what to do", function()
    reset()
    Tools.run("fleet_command", { command = "standby" })
    local out = Tools.run("move_unit", { unit = 3, place = "roof" })
    t.has(out, "REJECTED")
    t.has(out, "WAKE", "the model is told the fix")
  end)

  t.it("rejects a unit that is not on the grid", function()
    reset()
    t.has(Tools.run("move_unit", { unit = 99999, place = "roof" }), "REJECTED")
    t.has(Tools.run("move_unit", { unit = "twelve", place = "roof" }), "REJECTED")
  end)

  t.it("rejects a place that does not exist, and lists the real ones", function()
    reset()
    local out = Tools.run("move_unit", { unit = 1, place = "the moon" })
    t.has(out, "REJECTED")
    t.has(out, "ROOF")
    t.has(out, "LOBBY")
  end)

  t.it("moves the whole fleet to a floor", function()
    reset()
    local out = Tools.run("move_fleet", { place = "lobby" })
    t.has(out, "DONE")
    t.eq(countAtY(districtY("LOBBY")), Fleet.COUNT)
  end)

  t.it("moves only the wing it was given", function()
    reset()
    Tools.run("fleet_command", { command = "home" })
    local out = Tools.run("move_fleet", { place = "high", wing = "JADE" })
    t.has(out, "DONE")
    t.eq(Fleet.filter, 3, "JADE is the third wing")

    local jade = countAtY(districtY("HIGH"), 3)
    t.ok(jade > 0, "the jade wing moved")
    t.eq(countAtY(districtY("HIGH"), 1), 0, "the jarvis wing stayed put")
    for _, u in ipairs(Fleet.units) do
      if u.squad ~= 3 then t.eq(u.destY, u.homeY, "unit " .. u.id .. " should not have moved") end
    end
  end)

  t.it("accepts ALL as a wing without treating 0 as a miss", function()
    reset()
    local out = Tools.run("move_fleet", { place = "lobby", wing = "ALL" })
    t.has(out, "DONE")
    t.eq(Fleet.filter, 0)
    t.eq(countAtY(districtY("LOBBY")), Fleet.COUNT)
  end)

  t.it("refuses a catalog wing that is off duty this session", function()
    reset()
    local out = Tools.run("move_fleet", { place = "high", wing = "DRAGON" })
    t.has(out, "REJECTED")
    t.has(out, "OFF DUTY")
    t.has(out, "JARVIS")
  end)

  t.it("says so when the scope has nothing awake to move", function()
    reset()
    Tools.run("fleet_command", { command = "standby" })
    local out = Tools.run("move_fleet", { place = "mid" })
    t.has(out, "NOTHING MOVED")
    t.has(out, "WAKE")
  end)

  t.describe("tools / idle, sweep, form")

  t.it("idle sends everyone back to their own floor to live", function()
    reset()
    Tools.run("fleet_command", { command = "summon" })
    local out = Tools.run("fleet_command", { command = "idle" })
    t.has(out, "DONE")
    for _, u in ipairs(Fleet.units) do
      t.eq(u.destY, u.homeY, "unit " .. u.id .. " should head for its own floor")
      t.eq(u.idle, true, "unit " .. u.id .. " should be off duty")
    end
  end)

  t.it("gives an idle unit something to do, and only on its floor", function()
    reset()
    Tools.run("fleet_command", { command = "idle" })
    -- run the fleet for a few seconds of game time
    for _ = 1, 240 do Fleet.update(1 / 60) end

    local acts, floors = {}, 0
    for _, u in ipairs(Fleet.units) do
      if u.act then acts[u.act] = (acts[u.act] or 0) + 1 end
      if math.abs(u.y - u.homeY) < 3 then floors = floors + 1 end
      t.ok(u.x > World.BX and u.x < World.BX + World.BW, "unit " .. u.id .. " wandered out of the tower")
    end
    t.eq(floors, Fleet.COUNT, "nobody left their floor")
    local kinds = 0
    for _ in pairs(acts) do kinds = kinds + 1 end
    t.ok(kinds >= 2, "a floor of agents should not all be doing the same thing")
  end)

  t.it("walks on a cosine, never at a constant speed", function()
    reset()
    Tools.run("fleet_command", { command = "idle" })
    for _ = 1, 120 do Fleet.update(1 / 60) end

    -- follow one unit across a whole stroll and watch its speed profile
    local subject, samples, act = nil, {}, nil
    for _ = 1, 3000 do
      Fleet.update(1 / 60)
      if not subject then
        for _, u in ipairs(Fleet.units) do
          if u.act == "walk" and u.strollDur and (u.strollT or 0) < u.strollDur * 0.1
            and u.strollDur > 1.2 then
            subject, act = u, u.act
            break
          end
        end
      else
        if subject.act ~= act or (subject.strollT or 0) >= (subject.strollDur or 0) then break end
        samples[#samples + 1] = math.abs(subject.vx or 0)
      end
    end

    t.ok(#samples > 20, "caught a unit across a full stroll (" .. #samples .. " frames)")
    local peak, sum = 0, 0
    for _, v in ipairs(samples) do
      peak = math.max(peak, v)
      sum = sum + v
    end
    local mean = sum / #samples
    t.ok(mean > 0, "it is actually moving")
    -- a cosine ease peaks at pi/2 of its mean; constant speed would be 1.0
    t.ok(peak > mean * 1.35,
      string.format("speed must ease in and out, not hold constant (peak %.1f, mean %.1f)", peak, mean))
    t.ok(samples[1] < peak * 0.5, "it leans into the first step instead of snapping to full speed")
  end)

  t.it("drops the idle life as soon as an order lands", function()
    reset()
    Tools.run("fleet_command", { command = "idle" })
    t.eq(Fleet.units[1].idle, true)
    Tools.run("fleet_command", { command = "summon" })
    t.eq(Fleet.units[1].idle, false, "a summon cancels off-duty time")
  end)

  t.it("sweep really runs the lobby, spread across the floor", function()
    reset()
    local out = Tools.run("fleet_command", { command = "sweep" })
    t.has(out, "DONE")
    local base = World.standY(1)
    local lo, hi, ranks = math.huge, -math.huge, {}
    for _, u in ipairs(Fleet.units) do
      local off = base - u.destY
      t.ok(off >= 0 and off <= 24 * 15, "unit " .. u.id .. " is not in the lobby ranks")
      t.eq(off % 15, 0, "unit " .. u.id .. " should sit on a rank line")
      ranks[off] = true
      lo, hi = math.min(lo, u.destX), math.max(hi, u.destX)
    end
    local n = 0
    for _ in pairs(ranks) do n = n + 1 end
    t.ok(n >= 2 and n <= 24, "the swarm splits into readable ranks, got " .. n)
    t.ok(hi - lo > 200, "the sweep line spans the lobby, not a huddle: " .. math.floor(hi - lo) .. "px")
  end)

  t.it("form packs each wing into its own block, not the summon grid", function()
    reset()
    local out = Tools.run("fleet_command", { command = "form" })
    t.has(out, "DONE")

    local lanes = {}
    for _, u in ipairs(Fleet.units) do
      t.ok(u.destY < World.SKY, "unit " .. u.id .. " should be blocked up over the deck")
      local l = lanes[u.squad] or { lo = math.huge, hi = -math.huge }
      l.lo, l.hi = math.min(l.lo, u.destX), math.max(l.hi, u.destX)
      lanes[u.squad] = l
    end

    local centres = {}
    for squad, l in pairs(lanes) do
      t.ok(l.hi - l.lo < 110, "wing " .. squad .. " should be a tight block")
      centres[#centres + 1] = (l.lo + l.hi) * 0.5
    end
    table.sort(centres)
    t.ok(#centres >= 2, "several wings formed up")
    for i = 2, #centres do
      t.ok(centres[i] - centres[i - 1] > 30, "wing blocks should sit side by side, not on top of each other")
    end
  end)

  t.it("does not look like a summon", function()
    reset()
    Tools.run("fleet_command", { command = "form" })
    local formed = {}
    for _, u in ipairs(Fleet.units) do formed[u.id] = u.destX end
    reset()
    Tools.run("fleet_command", { command = "summon" })
    local same = 0
    for _, u in ipairs(Fleet.units) do
      if math.abs(u.destX - (formed[u.id] or -999)) < 1 then same = same + 1 end
    end
    t.ok(same < Fleet.COUNT * 0.5, "form and summon used to be the same call; they must differ now")
  end)

  t.describe("camera")

  t.it("swings up to the roof when the swarm is summoned", function()
    reset()
    World.cam.x, World.cam.y, World.cam.zoom = World.hangarX, World.standY(1), 1.0
    Tween.clear()

    Tools.run("fleet_command", { command = "summon" })
    t.ok(#Tween.items > 0, "the camera move is a tween, not a jump")
    t.ok(math.abs(World.cam.y - World.standY(1)) < 1, "and it does not teleport on the first frame")

    for _ = 1, 120 do Tween.update(1 / 60) end
    t.eq(World.chase, nil, "and stops chasing whatever it was following")

    -- the roof deck has to be in the shot, not just the sky above it
    local _, top = World.roofGrid(1, World.FLOORS)
    local half = (World.viewHeight() * 0.5) / World.cam.zoom
    local viewTop, viewBottom = World.cam.y - half, World.cam.y + half
    t.ok(viewBottom > World.SKY, "the roofline must be inside the frame")
    t.ok(viewBottom < World.SKY + 220, "and the shot is not buried in the tower")
    t.ok(viewTop < World.SKY - 20, "with formation sky above it")
    if top > viewTop then
      t.ok(true, "the whole formation fits")
    else
      t.ok(viewBottom - World.SKY < 120, "a formation too tall to fit anchors on the deck")
    end
  end)

  t.it("travels on a curve, not a straight line", function()
    reset()
    local x0, y0 = 120, 900
    World.cam.x, World.cam.y, World.cam.zoom = x0, y0, 1.0
    Tween.clear()
    local x1, y1 = 600, 100
    World.swoop(x1, y1, 1.0, 1.0)

    -- sample the path and measure how far it bows off the straight line
    local worst = 0
    for i = 1, 60 do
      Tween.update(1 / 60)
      local px, py = World.cam.x, World.cam.y
      -- distance from the point to the line through (x0,y0)-(x1,y1)
      local dx, dy = x1 - x0, y1 - y0
      local len = math.sqrt(dx * dx + dy * dy)
      local off = math.abs(dx * (y0 - py) - (x0 - px) * dy) / len
      worst = math.max(worst, off)
      if i == 30 then t.ok(off > 1, "the midpoint sits off the straight line") end
    end
    t.ok(worst > 40, "the path should bow a long way off a ruled line, got " .. math.floor(worst) .. "px")

    for _ = 1, 90 do Tween.update(1 / 60) end
    t.near(World.cam.x, x1, 1, "and it still arrives")
    t.near(World.cam.y, y1, 1)
    t.near(World.cam.zoom, 1.0, 0.02, "with the lens settled back")
  end)

  t.it("pulls the lens back mid-swing", function()
    reset()
    World.cam.x, World.cam.y, World.cam.zoom = 200, 800, 1.2
    Tween.clear()
    World.swoop(600, 120, 1.2, 1.0)
    local widest = 1.2
    for _ = 1, 42 do
      Tween.update(1 / 60)
      widest = math.min(widest, World.cam.zoom)
    end
    t.ok(widest < 1.15, "the camera should breathe out on the way, got " .. string.format("%.2f", widest))
  end)

  t.describe("tools / read-only")

  t.it("locks the console onto a unit", function()
    reset()
    local out = Tools.run("select_unit", { unit = 7 })
    t.has(out, "DONE")
    t.has(out, "U0007")
    t.ok(Fleet.selected, "a unit is locked")
    t.eq(Fleet.selected.id, 7)
    t.eq(Agents.selected, Fleet.get(7).squad, "the wing follows the lock")
  end)

  t.it("lets go of the selection", function()
    reset()
    Tools.run("fleet_command", { command = "hold", wing = "neon" })
    Tools.run("select_unit", { unit = 7 })
    t.ok(Fleet.selected)

    local out = Tools.run("deselect")
    t.has(out, "DONE")
    t.has(out, "U0007", "it says what it let go of")
    t.eq(Fleet.selected, nil, "no unit is locked")
    t.eq(Agents.selected, nil, "no wing is chosen")
    t.eq(Fleet.filter, 0, "orders apply to the whole swarm again")
    t.eq(Agents.get().id, "jarvis", "JARVIS still speaks when nobody is chosen")
  end)

  t.it("says so when there was nothing to let go of", function()
    reset()
    Fleet.selected = nil
    Agents.clear()
    local out = Tools.run("deselect")
    t.has(out, "DONE")
    t.has(out, "NOTHING WAS SELECTED")
  end)

  t.it("reads live fleet state", function()
    reset()
    Tools.run("select_unit", { unit = 4 })
    local out = Tools.run("fleet_status")
    t.has(out, "UNITS")
    t.has(out, tostring(Fleet.COUNT))
    t.has(out, "SCOPE")
    t.has(out, "LOCKED U0004")
    t.has(out, "ROOF", "the model is reminded where it can send units")
  end)

  t.it("reads the clock in both zones", function()
    local utc = Tools.run("get_time", { zone = "utc" })
    t.match(utc, "^UTC %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d$")

    local loc = Tools.run("get_time", { zone = "local" })
    t.has(loc, "LOCAL")
    t.match(loc, "%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d")

    local both = Tools.run("get_time", { zone = "both" })
    t.has(both, "LOCAL")
    t.has(both, "UTC")

    t.has(Tools.run("get_time", { zone = "Zulu" }), "UTC", "models paraphrase the zone")
    t.has(Tools.run("get_time", {}), "LOCAL", "no zone means the operator's clock")
  end)

  t.it("agrees with os.date on the UTC offset", function()
    local utc = Tools.run("get_time", { zone = "utc" }):match("(%d%d:%d%d):%d%d")
    t.eq(utc, os.date("!%H:%M"), "UTC is the real UTC, not the local clock relabelled")
  end)

  t.describe("tools / dispatch")

  t.it("takes arguments as a JSON string too", function()
    reset()
    local out = Tools.run("move_unit", '{"unit": 9, "place": "roof"}')
    t.has(out, "DONE")
    t.ok(Fleet.get(9).destY <= World.SKY + 8)
  end)

  t.it("rejects a tool it does not have, and lists what it does", function()
    local out = Tools.run("launch_missiles", { at = "everything" })
    t.has(out, "REJECTED")
    t.has(out, "FLEET_COMMAND")
    t.has(out, "GET_TIME")
  end)

  t.it("catches an error inside a tool instead of crashing the game", function()
    reset()
    local save = Fleet.get
    Fleet.get = function() error("boom") end
    local out = Tools.run("move_unit", { unit = 1, place = "roof" })
    Fleet.get = save
    t.has(out, "FAILED")
    t.has(out, "boom")
  end)

  t.it("labels a call for the console log", function()
    t.eq(Tools.label("move_unit", { unit = 12, place = "roof" }), "MOVE_UNIT 12 ROOF")
    t.eq(Tools.label("fleet_command", { command = "home", wing = "neon" }), "FLEET_COMMAND HOME NEON")
    t.eq(Tools.label("fleet_status", nil), "FLEET_STATUS")
  end)
end
