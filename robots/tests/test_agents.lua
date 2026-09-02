-- One hundred named robots, each with its own body and a fly pose.
local Agents = require("src.agents")
local Store = require("src.store")
local Json = require("src.json")

return function(t)
  t.describe("agents / catalog")

  t.it("has one hundred named models", function()
    t.eq(#Agents.catalog, Agents.SIZE)
    t.eq(#Agents.catalog, 100)
    local seen = {}
    for _, a in ipairs(Agents.catalog) do
      t.ok(a.id and a.name and a.key and a.base, a.name .. " needs id/name/key/base")
      t.ok(not seen[a.id], "duplicate id " .. tostring(a.id))
      seen[a.id] = true
      t.eq(a.base, a.id, a.name .. " should be its own body")
      t.eq(a.hue, nil, a.name .. " should not be a palette shift")
    end
  end)

  t.it("has one hundred unique robot bodies", function()
    t.eq(Agents.UNIQUE, 100)
    t.eq(#Agents.catalog, Agents.UNIQUE)
  end)

  t.it("defaults to the original four so offline tests stay still", function()
    Agents.deploy({ "jarvis", "neon", "jade", "typhoon" })
    t.eq(#Agents.list, 4)
    t.eq(Agents.list[1].id, "jarvis")
    t.eq(Agents.list[3].id, "jade")
  end)

  t.describe("agents / session roll")

  t.it("rolls four distinct silhouettes from the catalog", function()
    love.math.setRandomSeed(20260901)
    local list = Agents.roll(4)
    t.eq(#list, 4)
    local bases, ids = {}, {}
    for _, a in ipairs(list) do
      t.ok(not ids[a.id], "rolled the same agent twice")
      ids[a.id] = true
      t.ok(not bases[a.base], "two wings shared silhouette " .. a.base)
      bases[a.base] = true
    end
  end)

  t.it("a second roll can pick a different four", function()
    love.math.setRandomSeed(1)
    Agents.roll(4)
    local a = Agents.list[1].id .. Agents.list[2].id .. Agents.list[3].id .. Agents.list[4].id
    love.math.setRandomSeed(99)
    Agents.roll(4)
    local b = Agents.list[1].id .. Agents.list[2].id .. Agents.list[3].id .. Agents.list[4].id
    t.ok(a ~= b, "two seeds produced the same roster")
    Agents.deploy({ "jarvis", "neon", "jade", "typhoon" })
  end)

  t.it("deploy pins a known roster for tools", function()
    Agents.deploy({ "dragon", "ferry", "volt", "glitch" })
    t.eq(Agents.list[1].id, "dragon")
    t.eq(Agents.indexOf("ferry"), 2)
    t.eq(Agents.wingIndex("all"), 0)
    t.eq(Agents.wingIndex("VOLT"), 3)
    local w, why = Agents.wingIndex("jade")
    t.eq(w, nil)
    t.eq(why, "off")
    Agents.deploy({ "jarvis", "neon", "jade", "typhoon" })
  end)

  t.describe("agents / looks")

  t.it("deals the loaded pool across a full swarm", function()
    local prev = Agents.TEST_SPRITE
    Agents.TEST_SPRITE = nil
    love.math.setRandomSeed(7)
    local looks = Agents.deal(100)
    t.eq(#looks, 100)
    local seen, allowed = {}, {}
    for _, a in ipairs(Agents.bodies()) do allowed[a.id] = true end
    for _, a in ipairs(looks) do
      t.ok(allowed[a.id], "dealt a body outside the pool: " .. a.id)
      seen[a.id] = true
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    t.eq(n, #Agents.bodies(), "expected the whole pool, got " .. n)
    Agents.TEST_SPRITE = prev
  end)

  t.it("paints color tints from the loaded pool", function()
    local prev = Agents.TEST_SPRITE
    Agents.TEST_SPRITE = nil
    love.math.setRandomSeed(42)
    local hues = 0
    local bodies = {}
    for i = 1, 80 do
      local u = { id = i, squad = ((i - 1) % 4) + 1 }
      Agents.paint(u)
      t.ok(u.look and u.lookKey, "unit needs a look")
      local body = Agents.byId(u.look)
      t.ok(body and body.id == body.base, "look should be a unique body")
      bodies[u.look] = true
      if u.lookHue and u.lookHue ~= 0 then hues = hues + 1 end
    end
    local n = 0
    for _ in pairs(bodies) do n = n + 1 end
    t.ok(n >= 5, "expected several silhouettes, got " .. n)
    t.ok(n <= #Agents.bodies(), "painted outside the pool, got " .. n)
    t.ok(hues >= 8, "expected some color shifts, got " .. hues)
    Agents.TEST_SPRITE = prev
  end)

  t.it("keeps a fly sheet next to every body", function()
    for _, a in ipairs(Agents.catalog) do
      t.ok(love.filesystem.getInfo("assets/agent_" .. a.key .. ".png"), a.name .. " standing sprite")
      t.ok(love.filesystem.getInfo("assets/agent_" .. a.key .. "_fly.png"), a.name .. " fly sprite")
    end
  end)

  t.describe("agents / pool")

  t.it("picks ten distinct unique bodies", function()
    love.math.setRandomSeed(20260901)
    local pool = Agents.pickPool(10, { save = false })
    t.eq(#pool, 10)
    local seen = {}
    for _, a in ipairs(pool) do
      t.ok(not seen[a.id], "picked the same type twice: " .. a.id)
      seen[a.id] = true
      t.eq(a.base, a.id)
    end
    t.eq(#Agents.loaded, 10)
    Agents.loaded = {}
    for i = 1, Agents.POOL do Agents.loaded[i] = Agents.catalog[i] end
  end)

  t.describe("agents / pool persistence")

  local scratch = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/jarvis2-robots-test"

  local function defaultPool()
    Agents.loaded = {}
    for i = 1, Agents.POOL do Agents.loaded[i] = Agents.catalog[i] end
  end

  local function fresh()
    Store.use(scratch)
    Store.remove(Agents.LOG)
    defaultPool()
  end

  t.it("appends one json line per pick", function()
    fresh()
    love.math.setRandomSeed(11)
    Agents.pickPool(10)
    love.math.setRandomSeed(22)
    Agents.pickPool(10)
    local lines = Store.lines(Agents.LOG)
    t.eq(#lines, 2)
    local first = Json.decode(lines[1])
    local second = Json.decode(lines[2])
    t.eq(#first.ids, 10)
    t.eq(#second.ids, 10)
    t.ok(first.at and #first.at > 0, "each record is stamped")
    t.ok(second.ids[1] ~= nil)
  end)

  t.it("restores the last record on load", function()
    fresh()
    love.math.setRandomSeed(33)
    Agents.pickPool(10)
    local saved = {}
    for i, a in ipairs(Agents.loaded) do saved[i] = a.id end
    defaultPool()
    t.eq(Agents.restorePool(), true)
    t.eq(#Agents.loaded, 10)
    for i, id in ipairs(saved) do
      t.eq(Agents.loaded[i].id, id)
    end
  end)

  t.it("keeps the default pool when nothing was ever saved", function()
    fresh()
    t.eq(Agents.restorePool(), false)
    t.eq(Agents.loaded[1].id, "jarvis")
    t.eq(#Agents.loaded, 10)
  end)

  t.it("skips a truncated tail line and uses the last good one", function()
    fresh()
    Store.write(Agents.LOG, '{"ids":["volt","dragon","ghost"]}\n{"ids":["ja\n')
    t.eq(Agents.restorePool(), true)
    t.eq(Agents.loaded[1].id, "volt")
    t.eq(Agents.loaded[2].id, "dragon")
    t.eq(#Agents.loaded, 3)
  end)

  t.it("ignores a record with unknown ids", function()
    fresh()
    Store.write(Agents.LOG, '{"ids":["not-a-robot"]}\n')
    t.eq(Agents.restorePool(), false)
    t.eq(Agents.loaded[1].id, "jarvis")
  end)

  t.it("trims the log so it cannot grow without bound", function()
    fresh()
    local seed = {}
    for _ = 1, 205 do seed[#seed + 1] = '{"ids":["jarvis"]}' end
    Store.write(Agents.LOG, table.concat(seed, "\n") .. "\n")
    Agents.savePool()
    local lines = Store.lines(Agents.LOG)
    t.ok(#lines <= 40, "trimmed down, got " .. #lines)
    local last = Json.decode(lines[#lines])
    t.eq(last.ids[1], "jarvis", "the newest record survives")
  end)

  t.it("restores the real store for the suites that follow", function()
    Store.remove(Agents.LOG)
    Store.use(nil)
    defaultPool()
    Agents.deploy({ "jarvis", "neon", "jade", "typhoon" })
  end)

  t.describe("agents / the roster is the swarm")

  local roster = {
    { id = "aaa-1", slug = "jarvis", name = "JARVIS", kind = "general", role = "CORE BUTLER",
      sprite = "jarvis", color = "gold", space = "agents/aaa-1" },
    { id = "bbb-2", slug = "coding", name = "BYTE", kind = "coding", role = "CODE WRANGLER",
      sprite = "byte", color = "cyan", space = "agents/bbb-2" },
    { id = "ccc-3", slug = "food", name = "EMBER", kind = "food", role = "GALLEY CHIEF",
      sprite = "ember", color = "orange", space = "agents/ccc-3" },
  }

  t.it("one robot becomes one agent, wearing its own sprite and folder", function()
    local list = Agents.fromRoster(roster)
    t.eq(#list, 3)
    t.eq(Agents.roster, true)
    t.eq(Agents.wings(), 3)
    t.eq(Agents.list[2].id, "bbb-2", "the GUID is the id")
    t.eq(Agents.list[2].key, "byte", "the sprite is the body")
    t.eq(Agents.list[2].name, "BYTE")
    t.eq(Agents.list[2].role, "CODE WRANGLER")
    t.eq(Agents.list[2].folder, "agents/bbb-2", "the folder is the point")
    t.ok(Agents.list[2].boot and #Agents.list[2].boot > 0, "borrows a boot line from the catalog")
    t.eq(Agents.forRobot("ccc-3").name, "EMBER")
    t.eq(Agents.forRobot("nobody"), nil)
    t.eq(Agents.byId("aaa-1").slug, "jarvis")
  end)

  t.it("deals the roster in order, one body per floor, untinted", function()
    Agents.fromRoster(roster)
    love.math.setRandomSeed(3)
    local looks = Agents.deal(3)
    t.eq(looks[1].id, "aaa-1")
    t.eq(looks[2].id, "bbb-2")
    t.eq(looks[3].id, "ccc-3")
    for i = 1, 3 do
      local u = { id = i, squad = i }
      Agents.paint(u, looks[i])
      t.eq(u.lookHue, 0, "a robot wears its own colours")
      t.eq(u.lookKey, looks[i].key)
      t.eq(u.robot, looks[i].id, "the unit knows which robot it is")
    end
  end)

  t.it("a boot powers the roster up rather than rolling four of the catalog", function()
    Agents.fromRoster(roster)
    Agents.setOnline(1, true)
    local list = Agents.roll()
    t.eq(#list, 3)
    t.eq(list[1].id, "aaa-1")
    t.eq(list[1].online, false, "a boot starts everyone off")
    t.eq(Agents.regenerate(), Agents.list, "there is nothing to regenerate")
  end)

  t.it("a wing is a robot: by name, slug or id", function()
    Agents.fromRoster(roster)
    t.eq(Agents.wingIndex("EMBER"), 3)
    t.eq(Agents.wingIndex("coding"), 2)
    t.eq(Agents.wingIndex("aaa-1"), 1)
    t.eq(Agents.wingIndex("all"), 0)
    local w, why = Agents.wingIndex("volt")
    t.eq(w, nil)
    t.eq(why, "off", "a catalog body that is not on the roster is off duty")
  end)

  t.it("an empty roster changes nothing", function()
    Agents.fromRoster(roster)
    t.eq(Agents.fromRoster({}), nil)
    t.eq(#Agents.list, 3)
  end)

  t.it("puts the catalog back for the suites that follow", function()
    Agents.dropRoster()
    t.eq(Agents.roster, false)
    t.eq(#Agents.loaded, 10)
    Agents.deploy({ "jarvis", "neon", "jade", "typhoon" })
    t.eq(#Agents.list, 4)
  end)
end
