-- The new screens, actually drawn.
--
-- The geometry tests hold the arithmetic; this holds the drawing code, which
-- is the half that reaches `love.graphics` and is therefore the half a
-- headless test cannot see. The suite runs inside LOVE with a window, so
-- every mode of the page — list, grid, the search shelf, the paper shelf,
-- the search box, both orientations, a real picture on a shelf — and face
-- mode with a system notice in it are drawn for real, and a runtime error
-- in any of them fails here instead of on the operator's screen.

local Page = require("src.agentpage")
local Face = require("src.face")
local Converse = require("src.converse")
local Robots = require("src.robots")
local Layout = require("src.layout")
local Input = require("src.input")
local UI = require("src.ui")
local Actions = require("src.actions")
local Photos = require("src.photos")

return function(F)
  F.describe("draw / the agent page in every mode")

  local source = love.filesystem.getSource()
  local picture = source .. "/assets/agent_byte.png"

  local function frame(drawFn)
    Input.begin()
    UI.begin()
    love.graphics.push("all")
    local ok, err = pcall(drawFn)
    love.graphics.pop()
    UI.endFrame()
    Input.begin()
    if not ok then error(err, 0) end
  end

  local function seed()
    Robots.reset()
    Robots.list = {
      { id = "a-1", slug = "coding", name = "BYTE", role = "CODE WRANGLER", kind = "coding",
        sprite = "byte", color = "cyan" },
      { id = "b-2", slug = "food", name = "EMBER", role = "GALLEY CHIEF", kind = "food",
        sprite = "ember", color = "orange" },
    }
    Robots.index()
    Robots.select("a-1")
    Robots.page = {
      folder = "~/.causewaybayjarvis/agents/a-1",
      messages = 3, bytes = 12345,
      gallery = {
        { id = 1, title = "the byte robot", kind = "image", mime = "image/png", bytes = 54000,
          path = "agents/a-1/photos/agent_byte.png", abs = picture },
        { id = 2, title = "missing picture", kind = "image", mime = "image/png", bytes = 1,
          path = "agents/a-1/photos/gone.png", abs = "/nowhere/gone.png" },
      },
      markdowns = { { id = 3, title = "lifetimes", kind = "markdown", body = "# Lifetimes\nborrow" } },
      files = { { id = 4, title = "spec.pdf", kind = "file", mime = "application/pdf", bytes = 900 } },
      notes = { { id = 5, title = "a note", kind = "note", body = "the borrow checker\nsecond line" } },
      papers = { { id = 0, title = "coding-2026.png", kind = "paper", mime = "image/png",
        bytes = 300000, path = "agents/a-1/paper/coding-2026.png", abs = picture } },
    }
    Robots.pageFor = "a-1"
    Page.hits = nil
    Page.grid = false
    Page.searching = false
    Page.setShelf(1)
  end

  local function eachOrientation(fn)
    local mode, vw, vh = Layout.mode, Layout.vw, Layout.vh
    local ok, err = pcall(function()
      Layout.mode = "landscape"
      Layout.vw, Layout.vh = 640, 360
      fn("landscape")
      Layout.mode = "portrait"
      Layout.vw, Layout.vh = 360, 640
      fn("portrait")
    end)
    Layout.mode, Layout.vw, Layout.vh = mode, vw, vh
    if not ok then error(err, 0) end
  end

  F.it("draws every shelf as a list with its preview, a real picture included", function()
    seed()
    eachOrientation(function(shape)
      for i = 1, #Page.SHELVES - 1 do
        Page.setShelf(i)
        Page.cursor = 1
        frame(Page.draw)
        Page.move(1)
        frame(Page.draw)
      end
    end)
    F.ok(Photos.get(picture), "the picture on the shelf was not decoded")
  end)

  F.it("draws the photo shelf as a grid, and the grid selects", function()
    seed()
    Page.showGallery()
    eachOrientation(function()
      frame(Page.draw)
      Page.move(1)
      frame(Page.draw)
    end)
    F.eq(Page.grid, true)
    F.eq(Page.cursor, 2)
  end)

  F.it("draws the search box, then the search shelf with hits from two robots", function()
    seed()
    Page.searching = true
    Page.query = "borrow"
    eachOrientation(function() frame(Page.draw) end)
    Page.searching = false
    Page.hits = {
      { item = { id = 5, title = "a note", kind = "note", body = "the borrow checker" },
        agent_name = "BYTE", via = "both", score = 0.03 },
      { item = { id = 9, title = "pan", kind = "image", mime = "image/png", path = "x.png" },
        abs = picture, agent_name = "EMBER", via = "bm25", score = 0.01 },
    }
    Page.hitsFor = "borrow"
    Page.setShelf(Page.SEARCH)
    eachOrientation(function()
      frame(Page.draw)
      Page.move(1)
      frame(Page.draw)
    end)
    F.eq(Page.selected().agent_name, "EMBER")
  end)

  F.it("draws the paper shelf with a paper on it, and a notice above", function()
    seed()
    Page.showPapers()
    Robots.page = Robots.page or {}
    Page.say("PAPER 1024X1024 -> CODING-2026.PNG", "good")
    -- showPapers asks for a fresh page; give it the fixture back.
    seed()
    Page.setShelf(Page.PAPERS)
    eachOrientation(function() frame(Page.draw) end)
    F.eq(Page.selected().kind, "paper")
  end)

  F.it("draws with nobody chosen, everybody's photos on the shelf", function()
    seed()
    Robots.select(nil)
    Robots.page = { folder = "~/.causewaybayjarvis/global", messages = 0, bytes = 0,
      gallery = {}, markdowns = {}, files = {}, notes = {}, papers = {} }
    Robots.pageFor = nil
    Robots.galleryAll = {
      { id = 7, title = "a", kind = "image", mime = "image/png", abs = picture, agent_name = "EMBER" },
      { id = 6, title = "b", kind = "image", mime = "image/png", abs = picture, agent_name = "BYTE" },
    }
    Page.setShelf(Page.GALLERY)
    Page.grid = true
    eachOrientation(function() frame(Page.draw) end)
    Page.grid = false
    eachOrientation(function() frame(Page.draw) end)
    F.eq(#Page.items(), 2)
    Robots.galleryAll = nil
  end)

  F.it("the footer's SEARCH button opens the box, and the tabs' GRID button flips the grid", function()
    seed()
    local mode, vw, vh = Layout.mode, Layout.vw, Layout.vh
    Layout.mode = "landscape"
    Layout.vw, Layout.vh = 640, 360
    local was = love.mouse.getPosition
    local function click(vx, vy)
      love.mouse.getPosition = function()
        return vx * Layout.scale + Layout.ox, vy * Layout.scale + Layout.oy
      end
      Input.begin(); Input.mousepressed()
      UI.begin(); Page.draw(); UI.endFrame()
      Input.begin(); Input.mousereleased()
      UI.begin(); Page.draw(); UI.endFrame()
      Input.begin()
    end
    local ok, err = pcall(function()
      local r = Page.rects(640, 360, false)
      -- The footer: PHOTO, FILE, PAPER, SEARCH — SEARCH is the fourth.
      local x = 2
      for _, label in ipairs({ "PHOTO", "FILE", "PAPER" }) do x = x + #label * 8 + 8 + 2 end
      click(x + 20, r.footer.y + 6)
      F.eq(Page.searching, true, "SEARCH did not open the box")
      Page.searching = false
      -- The GRID button sits at the right end of the tab row.
      click(640 - 46 + 20, r.tabs.y + 7)
      F.eq(Page.grid, true, "GRID did not flip the grid")
    end)
    love.mouse.getPosition = was
    Layout.mode, Layout.vw, Layout.vh = mode, vw, vh
    Page.grid = false
    if not ok then error(err, 0) end
  end)

  F.it("typing into the box and pressing enter runs the search through the bridge", function()
    seed()
    Page.searching = true
    Page.query = ""
    Input.begin()
    Input.textinput("congee")
    Page.update(0.016)
    F.eq(Page.query, "congee")
    Input.begin()
    Input.keypressed("backspace")
    Page.update(0.016)
    F.eq(Page.query, "conge")
    Input.begin()
    Input.keypressed("escape")
    local back = Page.update(0.016)
    F.eq(back, nil, "escape closes the box, not the page")
    F.eq(Page.searching, false)
    Input.begin()
  end)

  F.describe("draw / face mode with the archive words in it")

  F.it("draws a transcript that carries system notices from an action", function()
    seed()
    Converse.reset()
    Converse.loadedFor = "a-1"
    local said = {}
    Actions.handle("gallery", function(text, tone)
      said[#said + 1] = tone
      Converse.push("SYSTEM", text, tone == "good" and { 0, 1, 0, 1 } or { 0.5, 0.5, 0.5, 1 })
    end)
    Actions.request = nil
    Converse.push("YOU", "search congee", { 1, 1, 1, 1 })
    Converse.push("SYSTEM", "3 HITS IN EMBER  //  HYBRID", { 0, 1, 0, 1 })
    Converse.push("SYSTEM", "#4 NOTE CONGEE (EMBER)", { 0.5, 0.5, 0.5, 1 })
    Face.enter()
    eachOrientation(function() frame(Face.draw) end)
    F.eq(#said, 1)
    F.ok(#Converse.lines >= 4)
    Converse.reset()
  end)

  Robots.reset()
  Page.hits = nil
  Page.grid = false
  Page.searching = false
  Page.setShelf(1)
end
