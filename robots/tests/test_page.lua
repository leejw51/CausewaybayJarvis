-- The robot page: geometry and list behaviour, with no graphics context.

local Page = require("src.agentpage")
local Robots = require("src.robots")

return function(F)
  F.describe("page / geometry")

  F.it("landscape puts the list beside the preview", function()
    local r = Page.rects(640, 360, false)
    F.ok(r.preview.x > r.list.x + r.list.w - 1, "the panes overlap")
    F.eq(r.list.y, r.preview.y)
    F.ok(r.list.y > r.tabs.y, "the list is below the tabs")
    F.ok(r.footer.y + r.footer.h <= 360)
    F.ok(r.preview.x + r.preview.w <= 640)
  end)

  F.it("portrait stacks them, because a 360 column cannot hold both", function()
    local r = Page.rects(360, 640, true)
    F.eq(r.list.x, r.preview.x)
    F.ok(r.preview.y > r.list.y + r.list.h - 1)
    F.ok(r.preview.y + r.preview.h <= 640 - 12)
  end)

  F.it("every pane stays inside the canvas at either shape", function()
    for _, s in ipairs({ { 640, 360, false }, { 360, 640, true }, { 480, 270, false } }) do
      local r = Page.rects(s[1], s[2], s[3])
      for name, box in pairs(r) do
        F.ok(box.x >= 0 and box.y >= 0, name .. " starts off screen")
        F.ok(box.w > 0 and box.h > 0, name .. " has no area")
        F.ok(box.x + box.w <= s[1] + 0.01, name .. " runs off the right")
        F.ok(box.y + box.h <= s[2] + 0.01, name .. " runs off the bottom")
      end
    end
  end)

  F.describe("page / the scroll window")

  F.it("shows everything when everything fits", function()
    F.eq(Page.window(4, 3, 10), 1)
  end)

  F.it("keeps the cursor on screen at both ends", function()
    F.eq(Page.window(100, 1, 10), 1)
    F.eq(Page.window(100, 100, 10), 91)
    local first = Page.window(100, 50, 10)
    F.ok(first <= 50 and 50 < first + 10, "cursor 50 is outside the window")
  end)

  F.describe("page / shelves")

  F.it("cycles through the six shelves and wraps", function()
    Page.shelf = 1
    Page.setShelf(7)
    F.eq(Page.shelf, 1)
    Page.setShelf(0)
    F.eq(Page.shelf, 6)
    F.eq(Page.shelfDef().id, "search")
    Page.setShelf(5)
    F.eq(Page.shelfDef().field, "papers")
    Page.setShelf(4)
    F.eq(Page.shelfDef().field, "notes")
  end)

  F.it("the gallery and paper requests land on their shelves", function()
    Page.grid = false
    Page.showGallery()
    F.eq(Page.shelf, Page.GALLERY)
    F.eq(Page.grid, true)
    Page.showPapers()
    F.eq(Page.shelf, Page.PAPERS)
    F.eq(Page.grid, false)
    Page.setShelf(1)
    Page.grid = false
  end)

  F.it("the search shelf is the last reply's hits, each with its owner", function()
    Robots.reset()
    Page.hits = {
      { item = { id = 4, title = "congee", kind = "note" }, agent_name = "EMBER", via = "both", score = 0.03 },
      { item = { id = 2, title = "lifetimes", kind = "markdown", path = "a.md" }, agent_name = "BYTE", via = "bm25" },
    }
    Page.setShelf(Page.SEARCH)
    F.eq(Page.count(Page.SHELVES[Page.SEARCH]), 2)
    local items = Page.items()
    F.eq(#items, 2)
    F.eq(items[1].agent_name, "EMBER")
    F.eq(items[1].via, "both")
    F.eq(Page.selected().title, "congee")
    Page.hits = nil
    Page.setShelf(1)
  end)

  F.it("with nobody chosen the photo shelf is everybody's photos", function()
    Robots.reset()
    Robots.galleryAll = { { id = 9, title = "b", agent_name = "EMBER" }, { id = 3, title = "a", agent_name = "BYTE" } }
    Page.setShelf(Page.GALLERY)
    F.eq(Page.galleryIsEverybody(), true)
    F.eq(#Page.items(), 2)
    F.eq(Page.count(Page.SHELVES[Page.GALLERY]), 2)
    F.eq(Page.items()[1].agent_name, "EMBER")
    Robots.galleryAll = nil
  end)

  F.it("has nothing to draw until the page arrives", function()
    Robots.reset()
    Page.shelf = 1
    F.eq(#Page.items(), 0)
    F.eq(Page.selected(), nil)
    F.eq(Page.count(Page.SHELVES[1]), 0)
  end)

  F.it("reads the shelf the backend answered with", function()
    Robots.reset()
    Robots.page = {
      gallery = { { id = 1, title = "cat.png" }, { id = 2, title = "dog.png" } },
      markdowns = {}, files = {}, notes = {},
    }
    Robots.pageFor = nil
    Page.shelf = 1
    Page.cursor = 2
    F.eq(#Page.items(), 2)
    F.eq(Page.selected().title, "dog.png")
    Page.move(5)
    F.eq(Page.cursor, 2, "the cursor cannot run past the end")
    Page.move(-5)
    F.eq(Page.cursor, 1)
  end)

  F.describe("page / the tabs")

  F.it("keeps the full labels when the row is wide, and shortens them when it is not", function()
    local counts = { 12, 3, 0, 7, 1, 0 }
    local shown = { true, true, true, true, true, false }
    local wide = Page.tabLabels(640, counts, shown, 1)
    F.eq(wide[1], "PHOTOS 12")
    F.eq(wide[4], "NOTES 7")
    local narrow = Page.tabLabels(360, counts, shown, 1)
    F.has(narrow[1], "12", "the chosen tab keeps its count")
    F.ok(#narrow[2] < #wide[2], "the others lost something")
    local function width(labels)
      local total = 4
      for i, l in ipairs(labels) do if shown[i] then total = total + #l * 8 + 13 end end
      return total
    end
    F.ok(width(narrow) <= 360 - 48, "still too wide: " .. width(narrow))
    shown[6] = true
    local tiny = Page.tabLabels(300, counts, shown, 6)
    F.ok(width(tiny) <= 300 - 48 or #tiny[1] <= 6, "the shortest form is three letters")
    F.eq(#Page.tabLabels(640, counts, shown, 1), 6)
  end)

  F.describe("page / the grid")

  F.it("fits as many columns as the width allows and widens the cells", function()
    local r = { x = 4, y = 60, w = 632, h = 280 }
    local g = Page.gridLayout(r, 20, 1)
    F.ok(g.cols >= 7 and g.cols <= 9, "columns: " .. g.cols)
    F.ok(g.cell >= 64, "cell shrank: " .. g.cell)
    -- Every column, with its gaps, fits the row.
    F.ok(g.x + g.cols * g.cell + (g.cols - 1) * g.gap <= r.x + r.w, "the row overflows")
    local x1, y1 = Page.gridPos(g, 1)
    local x2 = Page.gridPos(g, 2)
    F.eq(x1, g.x)
    F.eq(x2, g.x + g.cell + g.gap)
    local xn, yn = Page.gridPos(g, g.cols + 1)
    F.eq(xn, g.x, "the next row starts at the left")
    F.ok(yn > y1, "the next row is lower")
  end)

  F.it("scrolls rows so the cursor stays visible, and hides the rest", function()
    local r = { x = 4, y = 60, w = 320, h = 160 }
    local g = Page.gridLayout(r, 200, 200)
    F.ok(g.first > 1, "the last cell must scroll the grid")
    F.eq(Page.gridPos(g, 1), nil, "the first cell is off the top")
    F.ok(Page.gridPos(g, 200) ~= nil, "the cursor's cell is drawn")
    local g1 = Page.gridLayout(r, 200, 1)
    F.eq(g1.first, 1)
  end)

  F.it("one cell is still a grid", function()
    local g = Page.gridLayout({ x = 0, y = 0, w = 40, h = 40 }, 1, 1)
    F.eq(g.cols, 1)
    F.ok(Page.gridPos(g, 1) ~= nil)
  end)

  F.describe("page / paths")

  F.it("keeps the filename when a path is too long", function()
    F.eq(Page.fitPath("short.png", 20), "short.png")
    local long = "agents/1234-5678-90ab-cdef/photos/a-very-long-name.png"
    local cut = Page.fitPath(long, 24)
    F.eq(#cut, 24)
    F.has(cut, "long-name.png")
    F.match(cut, "^%.%.%.")
  end)
end
