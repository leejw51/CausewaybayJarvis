-- Face mode: geometry, and which face belongs on screen.

local Face = require("src.face")
local Robots = require("src.robots")

local function fake()
  Robots.reset()
  Robots.list = {
    { id = "aaa", slug = "jarvis", name = "JARVIS", kind = "general", sprite = "jarvis", color = "gold" },
    { id = "ccc", slug = "food", name = "EMBER", kind = "food", sprite = "ember", color = "orange" },
  }
  Robots.loaded = true
  Robots.index()
end

return function(F)
  F.describe("face / geometry")

  F.it("the head, the speech and the input all fit on screen", function()
    for _, s in ipairs({ { 640, 360, false }, { 360, 640, true }, { 480, 270, false } }) do
      local r = Face.rects(s[1], s[2], s[3])
      for name, box in pairs(r) do
        F.ok(box.w > 0 and box.h > 0, name .. " has no area")
        F.ok(box.x >= 0 and box.y >= 0, name .. " starts off screen")
        F.ok(box.x + box.w <= s[1] + 0.01, name .. " runs off the right")
        F.ok(box.y + box.h <= s[2] + 0.01, name .. " runs off the bottom")
      end
      F.ok(r.head.w == r.head.h, "the head is square")
    end
  end)

  F.it("landscape puts the speech beside the head, portrait below it", function()
    local land = Face.rects(640, 360, false)
    F.ok(land.speech.x >= land.head.x + land.head.w, "the speech overlaps the head")
    local port = Face.rects(360, 640, true)
    F.ok(port.speech.y >= port.head.y + port.head.h, "the speech overlaps the head")
  end)

  -- The bands nothing else may be drawn into. Each one is written by a
  -- different function, so nothing but a test holds them apart — and when
  -- they were not held apart, the robot's name printed straight through
  -- the first line of its own answer.
  F.it("leaves room under the head for the name and its role", function()
    for _, s in ipairs({ { 360, 640, true }, { 640, 360, false }, { 360, 1024, true } }) do
      local r = Face.rects(s[1], s[2], s[3])
      if s[3] then
        local gap = r.speech.y - (r.head.y + r.head.h)
        F.ok(gap >= 20, "only " .. gap .. " pixels for two rows of text")
      end
    end
  end)

  F.it("leaves room above the input for the key hints", function()
    for _, s in ipairs({ { 360, 640, true }, { 640, 360, false }, { 1024, 576, false } }) do
      local r = Face.rects(s[1], s[2], s[3])
      local gap = r.input.y - (r.speech.y + r.speech.h)
      F.ok(gap >= 11, "only " .. gap .. " pixels for the key hints")
    end
  end)

  -- A stretched canvas is the ordinary case now, not an exotic one: a
  -- window that is not the design's shape is filled rather than
  -- letterboxed, so the rects have to hold up at sizes nobody drew.
  F.it("holds up when the canvas is stretched", function()
    for _, s in ipairs({ { 640, 576, false }, { 576, 640, true }, { 360, 1024, true } }) do
      local r = Face.rects(s[1], s[2], s[3])
      for name, box in pairs(r) do
        F.ok(box.w > 0 and box.h > 0, name .. " has no area at " .. s[1] .. "x" .. s[2])
        F.ok(box.x + box.w <= s[1] + 0.01, name .. " runs off the right")
        F.ok(box.y + box.h <= s[2] + 0.01, name .. " runs off the bottom")
      end
      F.ok(r.speech.h >= 20, "the transcript was squeezed to nothing")
    end
  end)

  F.describe("face / whose face")

  F.it("the chosen robot wins", function()
    fake()
    Robots.select("food")
    Robots.hint = { agent = { id = "aaa" }, confident = true }
    F.eq(Face.subject().slug, "food")
  end)

  F.it("with nobody chosen, the words pick the face", function()
    fake()
    Robots.select(nil)
    Robots.hint = { agent = { id = "ccc" }, confident = true }
    F.eq(Face.subject().slug, "food")
  end)

  F.it("and with no route yet there is no face at all", function()
    fake()
    Robots.select(nil)
    Robots.hint = nil
    F.eq(Face.subject(), nil)
    F.eq(Robots.name(Face.subject()), "SWARM")
  end)
end
