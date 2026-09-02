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

  F.it("cycles through the four shelves and wraps", function()
    Page.shelf = 1
    Page.setShelf(5)
    F.eq(Page.shelf, 1)
    Page.setShelf(0)
    F.eq(Page.shelf, 4)
    F.eq(Page.shelfDef().field, "notes")
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
