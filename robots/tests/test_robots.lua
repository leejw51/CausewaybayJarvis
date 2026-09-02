-- The roster as this client holds it: selection, the ring, and colours.

local Robots = require("src.robots")
local Theme = require("src.theme")

local function fake()
  Robots.reset()
  Robots.list = {
    { id = "aaa", slug = "jarvis", name = "JARVIS", kind = "general", sprite = "jarvis", color = "gold" },
    { id = "bbb", slug = "coding", name = "BYTE", kind = "coding", sprite = "byte", color = "cyan" },
    { id = "ccc", slug = "food", name = "EMBER", kind = "food", sprite = "ember", color = "orange" },
  }
  Robots.loaded = true
  Robots.index()
end

return function(F)
  F.describe("robots / selection")

  F.it("nobody is chosen to begin with, and that is the global space", function()
    fake()
    F.eq(Robots.selected, nil)
    F.eq(Robots.current(), nil)
    F.eq(Robots.name(), "SWARM")
  end)

  F.it("selects by GUID or by slug", function()
    fake()
    F.ok(Robots.select("bbb"))
    F.eq(Robots.name(), "BYTE")
    F.ok(Robots.select("food"))
    F.eq(Robots.selected, "ccc")
    F.eq(Robots.select("nobody"), false, "an unknown handle changes nothing")
    F.eq(Robots.selected, "ccc")
  end)

  F.it("the ring runs through nobody as well as everybody", function()
    fake()
    local seen = {}
    for _ = 1, 4 do
      Robots.cycle(1)
      seen[#seen + 1] = Robots.selected or "-"
    end
    F.eq(table.concat(seen, " "), "aaa bbb ccc -")
  end)

  F.it("cycles backwards too", function()
    fake()
    Robots.cycle(-1)
    F.eq(Robots.selected, "ccc")
  end)

  F.it("changing robot throws away the page it was holding", function()
    fake()
    Robots.select("bbb")
    Robots.page = { folder = "x" }
    Robots.pageFor = "bbb"
    F.ok(Robots.pageFresh())
    Robots.select("ccc")
    F.eq(Robots.page, nil)
    F.eq(Robots.pageFresh(), false)
  end)

  F.describe("robots / colour")

  F.it("maps the backend's colour name onto the palette", function()
    fake()
    F.eq(Robots.color(Robots.byId.bbb), Theme.cyan)
    F.eq(Robots.color(Robots.byId.aaa), Theme.gold)
    F.eq(Robots.color(nil), Theme.ice, "the swarm has its own colour")
    F.eq(Robots.color({ color = "chartreuse" }), Theme.cyan, "an unknown name falls back")
  end)

  F.describe("robots / the routed face")

  F.it("only a confident route puts a face forward", function()
    fake()
    Robots.hint = { agent = { id = "ccc" }, confident = true }
    F.eq(Robots.hinted().slug, "food")
    Robots.hint = { agent = { id = "ccc" }, confident = false }
    F.eq(Robots.hinted(), nil, "a guess is not a summons")
    Robots.hint = nil
    F.eq(Robots.hinted(), nil)
  end)

  F.describe("robots / one selection, wherever it is made")

  local Agents = require("src.agents")
  local Fleet = require("src.fleet")
  local World = require("src.world")

  local roster = {
    { id = "aaa", slug = "jarvis", name = "JARVIS", kind = "general", role = "CORE BUTLER", sprite = "jarvis", color = "gold" },
    { id = "bbb", slug = "coding", name = "BYTE", kind = "coding", role = "CODE WRANGLER", sprite = "byte", color = "cyan" },
    { id = "ccc", slug = "food", name = "EMBER", kind = "food", role = "GALLEY CHIEF", sprite = "ember", color = "orange" },
  }

  local function tower()
    fake()
    Agents.fromRoster(roster)
    if not World.ready then World.build() end
    Fleet.COUNT = 3
    Fleet.spawn()
  end

  local function down()
    Robots.select(nil)
    Agents.dropRoster()
    Agents.deploy({ "jarvis", "neon", "jade", "typhoon" })
    Fleet.COUNT = 100
    Fleet.spawn()
    Robots.reset()
  end

  F.it("the tower holds the roster, one robot per floor", function()
    tower()
    F.eq(#Fleet.units, 3)
    F.eq(Fleet.units[2].robot, "bbb")
    F.eq(Fleet.unitOf("ccc"), Fleet.units[3])
    F.eq(Fleet.unitOf(nil), nil)
    F.eq(Fleet.tag(Fleet.units[3]), "EMBER")
    down()
  end)

  F.it("locking a unit on the map chooses the robot", function()
    tower()
    Fleet.lock(Fleet.units[2])
    F.eq(Robots.selected, "bbb")
    F.eq(Robots.name(), "BYTE")
    F.eq(Fleet.selected, Fleet.units[2])
    F.eq(Agents.selected, 2)
    Fleet.unlock()
    F.eq(Robots.selected, nil)
    F.eq(Fleet.selected, nil)
    F.eq(Agents.selected, nil)
    down()
  end)

  F.it("choosing the robot anywhere else locks its unit on the map", function()
    tower()
    Robots.select("food")
    F.eq(Fleet.selected, Fleet.units[3], "the rail and the map are one selection")
    Robots.cycle(1)
    F.eq(Robots.selected, nil)
    F.eq(Fleet.selected, nil)
    Robots.cycle(1)
    F.eq(Fleet.selected, Fleet.units[1])
    down()
  end)

  F.it("a robot chosen before the tower was built is locked once it is", function()
    fake()
    Agents.fromRoster(roster)
    Fleet.units = {}
    Robots.select("bbb")
    F.eq(Fleet.selected, nil)
    if not World.ready then World.build() end
    Fleet.COUNT = 3
    Fleet.spawn()
    F.eq(Fleet.selected, Fleet.units[2])
    down()
  end)

  F.it("locking one agent leaves the others on the tower", function()
    tower()
    Fleet.lock(Fleet.units[1])
    F.eq(#Fleet.drawList(), 3, "the other two must still be drawn")
    F.eq(Fleet.scopeN(), 1, "but orders go to the one")
    down()
  end)
end
