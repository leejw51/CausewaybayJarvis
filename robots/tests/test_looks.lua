-- Looks: which sprite set the roster wears. Persisted as looks.jsonl.
local Store = require("src.store")
local Json = require("src.json")
local Looks = require("src.looks")

return function(t)
  t.describe("looks / catalog")

  t.it("ships three looks, twelve faces each", function()
    t.eq(#Looks.CATALOG, 3)
    t.eq(#Looks.ROSTER, 12)
    local seen = {}
    for _, look in ipairs(Looks.CATALOG) do
      t.ok(look.id and look.name and look.sprites == 12, look.id)
      t.ok(not seen[look.id], "duplicate look " .. tostring(look.id))
      seen[look.id] = true
    end
    t.ok(Looks.find("robots"))
    t.ok(Looks.find("tropic"))
    t.ok(Looks.find("astral"))
  end)

  t.it("points themed sheets at assets/themes/<look>/", function()
    t.eq(Looks.file("robots", "jarvis"), "assets/agent_jarvis.png")
    t.eq(Looks.file("robots", "jarvis", true), "assets/agent_jarvis_fly.png")
    t.eq(Looks.file("tropic", "byte"), "assets/themes/tropic/agent_byte.png")
    t.eq(Looks.file("astral", "ember", true), "assets/themes/astral/agent_ember_fly.png")
  end)

  t.it("falls back to the house sprites when a look is missing a body", function()
    local prev = Looks.current
    Looks.current = "tropic"
    -- A catalog body the look never painted.
    t.eq(Looks.path("glitch"), "assets/agent_glitch.png")
    Looks.current = "robots"
    t.eq(Looks.path("jarvis"), "assets/agent_jarvis.png")
    Looks.current = prev
  end)

  t.describe("looks / persistency jsonl")

  t.it("ships the current anime-robot theme as jsonl", function()
    local man = Looks.manifest("robots")
    t.ok(man and #man >= 13, "theme record plus twelve sprites")
    t.eq(man[1].kind, "theme")
    t.eq(man[1].id, "robots")
    t.eq(man[1].sprites, 12)
    local faces = {}
    for i = 2, #man do
      if man[i].kind == "sprite" then faces[man[i].id] = man[i] end
    end
    for _, face in ipairs(Looks.ROSTER) do
      t.ok(faces[face.id], "missing " .. face.id .. " in persistency/robots.jsonl")
      t.has(faces[face.id].file, "agent_" .. face.id .. ".png")
    end
  end)

  t.it("ships tropic and astral manifests with twelve faces", function()
    for _, id in ipairs({ "tropic", "astral" }) do
      local man = Looks.manifest(id)
      t.ok(man and #man >= 13, id .. " manifest")
      t.eq(man[1].id, id)
      t.eq(man[1].sprites, 12)
      local n = 0
      for i = 2, #man do
        if man[i].kind == "sprite" then n = n + 1 end
      end
      t.eq(n, 12, id .. " sprite rows")
    end
  end)

  t.describe("looks / persistence")

  local scratch = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/jarvis2-looks-test"

  local function fresh()
    Store.use(scratch)
    Store.remove(Looks.LOG)
    Looks.current = "robots"
  end

  t.it("appends one json line per apply", function()
    fresh()
    t.eq(Looks.apply("tropic"), true)
    t.eq(Looks.current, "tropic")
    t.eq(Looks.apply("astral"), true)
    local lines = Store.lines(Looks.LOG)
    t.eq(#lines, 2)
    local first = Json.decode(lines[1])
    t.eq(first.id, "tropic")
    local second = Json.decode(lines[2])
    t.eq(second.id, "astral")
    t.ok(second.at and #second.at > 0, "each record is stamped")
  end)

  t.it("restores the last record on load", function()
    fresh()
    Looks.apply("astral")
    Looks.current = "robots"
    t.eq(Looks.load(), true)
    t.eq(Looks.current, "astral")
  end)

  t.it("keeps the house look when nothing was ever saved", function()
    fresh()
    t.eq(Looks.load(), false)
    t.eq(Looks.current, "robots")
  end)

  t.it("refuses an unknown look", function()
    fresh()
    t.eq(Looks.apply("msx"), false)
    t.eq(Looks.current, "robots")
  end)

  t.it("cycles the three looks", function()
    fresh()
    Looks.cycle(1)
    t.eq(Looks.current, "tropic")
    Looks.cycle(1)
    t.eq(Looks.current, "astral")
    Looks.cycle(1)
    t.eq(Looks.current, "robots")
    Looks.cycle(-1)
    t.eq(Looks.current, "astral")
  end)

  t.it("restores the real store for the suites that follow", function()
    Looks.apply("robots")
    Store.remove(Looks.LOG)
    Store.use(nil)
    Looks.current = "robots"
    t.has(Store.root(), ".causewaybayjarvis")
  end)
end
