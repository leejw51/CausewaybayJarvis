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

  F.it("leaves room above the input for the menu and the key hints", function()
    for _, s in ipairs({ { 360, 640, true }, { 640, 360, false }, { 1024, 576, false } }) do
      local r = Face.rects(s[1], s[2], s[3])
      local gap = r.input.y - (r.speech.y + r.speech.h)
      F.ok(gap >= 13, "only " .. gap .. " pixels for the menu")
      F.ok(r.menu.y >= r.speech.y + r.speech.h, "the menu overlaps the transcript")
      F.ok(r.menu.y + r.menu.h <= r.input.y, "the menu overlaps the input")
    end
  end)

  F.describe("face / the menu")

  F.it("every archive word and the unified search fit the row, wide or narrow", function()
    for _, w in ipairs({ 1024, 640, 480, 360 }) do
      local r = Face.rects(w, 640, w < 480)
      local buttons, hintX = Face.menuLayout(r.menu)
      F.eq(#buttons, #Face.MENU, w .. " wide lost a button")
      F.eq(buttons[#buttons].id, "search")
      local last = buttons[#buttons]
      F.ok(last.x + last.w <= r.menu.x + r.menu.w, w .. " wide runs off the right")
      F.ok(hintX > last.x + last.w, "the hints start on a button")
      for i = 2, #buttons do
        F.ok(buttons[i].x >= buttons[i - 1].x + buttons[i - 1].w, "buttons overlap")
      end
    end
    local _, narrow = Face.menuLayout(Face.rects(360, 640, true).menu)
    local _, wide = Face.menuLayout(Face.rects(640, 360, false).menu)
    F.ok(narrow < wide, "the narrow row did not shorten SEARCH ALL")
  end)

  F.it("the search box takes the keyboard, and enter or escape gives it back", function()
    local Input = require("src.input")
    local Converse = require("src.converse")
    fake()
    Robots.select("ccc")
    Converse.reset()
    Converse.loadedFor = "ccc"
    Converse.draft = "half a question"
    F.eq(Face.press("search"), true)
    F.eq(Face.searching, true)
    F.eq(Face.query, "")

    -- Typing goes to the query, not the draft, and escape is not "back".
    Input.begin()
    Input.textinput("cong")
    F.eq(Face.update(0.016), nil)
    Input.begin()
    Input.textinput("ee")
    Face.update(0.016)
    F.eq(Face.query, "congee")
    F.eq(Converse.draft, "half a question")
    Input.begin()
    Input.backspace = true
    Face.update(0.016)
    F.eq(Face.query, "conge")
    Input.begin()
    Input.keypressed("escape")
    F.eq(Face.update(0.016), nil, "escape closed the face instead of the box")
    F.eq(Face.searching, false)

    -- An empty box on enter is nothing, not a search.
    Face.openSearch()
    F.eq(Face.searchAll(""), false)
    F.eq(Face.searching, false)
    Converse.draft = ""
    Input.begin()
    Robots.reset()
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
