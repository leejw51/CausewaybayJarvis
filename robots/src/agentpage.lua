-- One robot's page: the head, and everything filed under it.
--
-- This is the screen that makes the central idea visible. An agent here is not
-- a prompt with a name on it — it is a GUID, a folder, and four shelves:
-- photos, markdown, files and notes. What the page draws is exactly what the
-- turn retrieves from, so "what does this robot know" has one answer and you
-- can look at it.
--
-- With no robot chosen the same page draws the global space, which is where
-- anything filed without a robot goes.

local Backend = require("src.backend")
local Font = require("src.font")
local Input = require("src.input")
local Layout = require("src.layout")
local Photos = require("src.photos")
local Robots = require("src.robots")
local Sprites = require("src.sprites")
local Theme = require("src.theme")
local UI = require("src.ui")

local Page = {
  shelf = 1,
  cursor = 1,
  scroll = 0,
  t = 0,
}

-- The four shelves, in the order the page shows them. `field` is the key the
-- backend's `page` op answers with.
Page.SHELVES = {
  { id = "gallery",   field = "gallery",   label = "PHOTOS",   color = Theme.cyan },
  { id = "markdowns", field = "markdowns", label = "MARKDOWN", color = Theme.jade },
  { id = "files",     field = "files",     label = "FILES",    color = Theme.amber },
  { id = "notes",     field = "notes",     label = "NOTES",    color = Theme.magenta },
}

local HEADER = 46
local TABS = 15

function Page.enter()
  Page.t = 0
  Page.cursor = 1
  Page.scroll = 0
  if not Robots.pageFresh() then Robots.loadPage() end
end

function Page.shelfDef()
  return Page.SHELVES[Page.shelf] or Page.SHELVES[1]
end

--- The rows of the shelf being looked at. Always a table, so the drawing code
--- never has to ask whether the page has arrived.
function Page.items()
  if not Robots.pageFresh() then return {} end
  local list = Robots.page[Page.shelfDef().field]
  return type(list) == "table" and list or {}
end

function Page.count(shelf)
  if not Robots.pageFresh() then return 0 end
  local list = Robots.page[shelf.field]
  return type(list) == "table" and #list or 0
end

function Page.selected()
  local items = Page.items()
  if #items == 0 then return nil end
  return items[math.max(1, math.min(#items, Page.cursor))]
end

function Page.setShelf(n)
  n = ((n - 1) % #Page.SHELVES) + 1
  if n == Page.shelf then return end
  Page.shelf = n
  Page.cursor = 1
  Page.scroll = 0
end

function Page.move(step)
  local items = Page.items()
  if #items == 0 then return end
  Page.cursor = math.max(1, math.min(#items, Page.cursor + step))
end

-- ------------------------------------------------------------- geometry ---

--- Every rectangle on the page, from the canvas size. Pure arithmetic and no
--- `love.*`, so the arrangement can be checked headlessly.
function Page.rects(w, h, portrait)
  local top = HEADER + TABS + 4
  if portrait then
    -- Two bands: the list above, the preview below. A 360-wide column cannot
    -- hold a list and a picture side by side.
    local listH = math.floor((h - top - 14) * 0.42)
    return {
      header  = { x = 0, y = 0, w = w, h = HEADER },
      tabs    = { x = 0, y = HEADER, w = w, h = TABS },
      list    = { x = 4, y = top, w = w - 8, h = listH },
      preview = { x = 4, y = top + listH + 4, w = w - 8, h = h - top - listH - 18 },
      footer  = { x = 0, y = h - 12, w = w, h = 12 },
    }
  end
  local listW = math.floor(w * 0.38)
  return {
    header  = { x = 0, y = 0, w = w, h = HEADER },
    tabs    = { x = 0, y = HEADER, w = w, h = TABS },
    list    = { x = 4, y = top, w = listW, h = h - top - 14 },
    preview = { x = listW + 8, y = top, w = w - listW - 12, h = h - top - 14 },
    footer  = { x = 0, y = h - 12, w = w, h = 12 },
  }
end

--- The first row to draw, so the cursor stays on screen without the caller
--- having to track a scroll offset.
function Page.window(count, cursor, rows)
  if count <= rows then return 1 end
  local first = cursor - math.floor(rows / 2)
  first = math.max(1, math.min(count - rows + 1, first))
  return first
end

--- Shorten a path to fit, keeping the end -- the filename is the useful half.
function Page.fitPath(path, chars)
  path = tostring(path or "")
  if #path <= chars then return path end
  return "..." .. path:sub(#path - chars + 4)
end

-- ------------------------------------------------------------- behaviour ---

--- Returns "back" when the operator is done with the page.
function Page.update(dt)
  Page.t = Page.t + dt

  -- Only ask when there is something to ask. With no backend built, `call`
  -- answers instantly with its reason, and an unguarded retry here would run
  -- one round of that per frame for as long as the page is open.
  if Backend.ready and not Robots.pageFresh() and not Robots.pageBusy then
    Robots.loadPage()
  end

  if Input.wasKey("escape") then return "back" end
  if Input.wasKey("tab") then
    Page.setShelf(Page.shelf + 1)
  end
  for i = 1, #Page.SHELVES do
    if Input.wasKey(tostring(i)) then Page.setShelf(i) end
  end
  if Input.wasKey("up") then Page.move(-1) end
  if Input.wasKey("down") then Page.move(1) end
  if Input.wasKey("pageup") then Page.move(-6) end
  if Input.wasKey("pagedown") then Page.move(6) end
  if Input.wasKey("left") then Robots.cycle(-1) Page.enter() end
  if Input.wasKey("right") then Robots.cycle(1) Page.enter() end
  if Input.wasKey("r") then
    Robots.page = nil
    Robots.pageFor = false
  end
  if (Input.wheel or 0) ~= 0 then Page.move(Input.wheel > 0 and -1 or 1) end
  return nil
end

-- ------------------------------------------------------------------ draw ---

local function drawHeader(r)
  local robot = Robots.current()
  local accent = Robots.color(robot)
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  love.graphics.setColor(Theme.withAlpha(accent, 0.8))
  love.graphics.rectangle("fill", r.x, r.y + r.h - 1, r.w, 1)

  local size = r.h - 8
  if robot then
    love.graphics.setColor(Theme.withAlpha(accent, 0.14))
    love.graphics.rectangle("fill", 4, 4, size, size)
    Sprites.drawHead(robot.sprite, 4, 4, size, 1)
    love.graphics.setColor(Theme.withAlpha(accent, 0.7))
    love.graphics.rectangle("line", 4.5, 4.5, size - 1, size - 1)
  else
    UI.rings(4 + size / 2, 4 + size / 2, size * 0.42, Page.t, Theme.gold, Theme.cyan)
  end

  -- Three rows, and the third is the folder. It gets a line to itself because
  -- it is sixty characters long and it is the answer to "where does this
  -- actually live" -- which is the question a page like this exists to settle.
  local tx = 8 + size
  local counters = 0
  if Robots.pageFresh() then
    local page = Robots.page
    local msg = string.format("%d MSG", page.messages or 0)
    local size = Photos.size(page.bytes or 0)
    counters = math.max(#msg, #size) * 8 + 8
    Font.print(msg, r.w - counters, 5, Theme.dim, 1)
    Font.print(size, r.w - counters, 15, Theme.dim, 1)
  end

  local room = math.max(8, math.floor((r.w - tx - counters - 6) / 8))
  Font.print(Robots.name(robot):sub(1, math.floor(room / 2)), tx, 5, accent, 2)
  if robot then
    Font.print((tostring(robot.role or "") .. "  //  " .. tostring(robot.kind or "")
      .. "  //  " .. tostring(robot.id):sub(1, 8)):upper():sub(1, room), tx, 23, Theme.paper, 1)
  else
    Font.print(("NO ROBOT CHOSEN  //  GLOBAL SPACE"):sub(1, room), tx, 23, Theme.paper, 1)
  end

  local folder = "READING ARCHIVE..."
  if Robots.pageFresh() then
    folder = Robots.page.folder
  elseif not Backend.ready then
    folder = "ARCHIVE CLOSED"
  end
  Font.print(Page.fitPath(folder, room), tx, 33, Theme.dim, 1)
end

local function drawTabs(r)
  love.graphics.setColor(Theme.panel)
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  local x = 4
  for i, shelf in ipairs(Page.SHELVES) do
    local label = string.format("%s %d", shelf.label, Page.count(shelf))
    local w = #label * 8 + 10
    if UI.button("shelf" .. i, x, r.y + 1, w, r.h - 3, label, {
      on = i == Page.shelf, onColor = shelf.color,
      stroke = Theme.dim, hot = shelf.color, scale = 1,
    }) then
      Page.setShelf(i)
    end
    x = x + w + 3
  end
end

local function drawList(r)
  local shelf = Page.shelfDef()
  UI.panel(r.x, r.y, r.w, r.h, shelf.label, shelf.color)
  local items = Page.items()
  if #items == 0 then
    local why = "SHELF EMPTY"
    if not Backend.ready then
      why = Backend.reason
    elseif not Robots.pageFresh() then
      why = "READING ARCHIVE..."
    end
    Font.printf(why, r.x + 8, r.y + 14, r.w - 16, Theme.dim, 1)
    return
  end
  Page.cursor = math.max(1, math.min(#items, Page.cursor))

  local rowH = 11
  local rows = math.max(1, math.floor((r.h - 14) / rowH))
  local first = Page.window(#items, Page.cursor, rows)
  local chars = math.max(6, math.floor((r.w - 26) / 8))

  for i = first, math.min(#items, first + rows - 1) do
    local item = items[i]
    local y = r.y + 12 + (i - first) * rowH
    local on = i == Page.cursor
    if Layout.hit(r.x + 2, y, r.w - 4, rowH) then
      if Input.pressed then Page.cursor = i end
      love.graphics.setColor(Theme.withAlpha(shelf.color, 0.12))
      love.graphics.rectangle("fill", r.x + 2, y, r.w - 4, rowH)
    end
    if on then
      love.graphics.setColor(Theme.withAlpha(shelf.color, 0.24))
      love.graphics.rectangle("fill", r.x + 2, y, r.w - 4, rowH)
      love.graphics.setColor(shelf.color)
      love.graphics.rectangle("fill", r.x + 2, y, 2, rowH)
    end
    local title = tostring(item.title or ""):upper()
    Font.print(title:sub(1, chars), r.x + 8, y + 2, on and Theme.ice or Theme.paper, 1)
  end

  if #items > rows then
    Font.print(string.format("%d/%d", Page.cursor, #items),
      r.x + r.w - 46, r.y + r.h - 10, Theme.dim, 1)
  end
end

local function drawPreview(r)
  local item = Page.selected()
  local shelf = Page.shelfDef()
  UI.panel(r.x, r.y, r.w, r.h, "ITEM", shelf.color)
  if not item then
    Font.printf("NOTHING ON THIS SHELF YET. DROP A FILE ON THE WINDOW TO FILE ONE " ..
      "WITH THIS ROBOT.", r.x + 8, r.y + 16, r.w - 16, Theme.dim, 1)
    return
  end

  Font.print(tostring(item.title or ""):upper():sub(1, math.floor((r.w - 16) / 8)),
    r.x + 8, r.y + 14, Theme.ice, 1)
  local meta = string.format("#%d  %s  %s", item.id or 0,
    tostring(item.kind or ""):upper(), Photos.size(item.bytes))
  Font.print(meta, r.x + 8, r.y + 24, Theme.dim, 1)

  local bodyY = r.y + 36
  local bodyH = r.h - (bodyY - r.y) - 8

  if item.abs and tostring(item.mime or ""):find("^image/") then
    local img = Photos.get(item.abs)
    if img then
      Sprites.drawFit(img, r.x + 8, bodyY, r.w - 16, bodyH, 1)
    else
      Font.print("CANNOT READ " .. Page.fitPath(item.path, 30), r.x + 8, bodyY, Theme.crimson, 1)
    end
  else
    local body = tostring(item.body or "")
    if body:gsub("%s", "") == "" then
      body = "NO TEXT. " .. tostring(item.mime or "BINARY"):upper() .. "."
    end
    -- The dashboard font is an 8x8 uppercase ROM, so fold to plain caps.
    body = body:gsub("[\128-\255]", " "):gsub("[\r\t]", " "):upper()
    local chars = math.max(8, math.floor((r.w - 16) / 8))
    local lines = math.max(1, math.floor(bodyH / 9))
    local shown, n = {}, 0
    for line in (body .. "\n"):gmatch("(.-)\n") do
      for i = 1, math.max(1, math.ceil(#line / chars)) do
        n = n + 1
        if n > lines then break end
        shown[#shown + 1] = line:sub((i - 1) * chars + 1, i * chars)
      end
      if n > lines then break end
    end
    for i, line in ipairs(shown) do
      Font.print(line, r.x + 8, bodyY + (i - 1) * 9, Theme.paper, 1)
    end
  end

  if item.path then
    Font.print(Page.fitPath(item.path, math.floor((r.w - 16) / 8)),
      r.x + 8, r.y + r.h - 10, Theme.dim, 1)
  end
end

local function drawFooter(r)
  love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.9))
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  Font.print("TAB SHELF   ARROWS PICK   L/R AGENT   F4 FACE   ESC BACK   DROP A FILE TO ADD",
    4, r.y + 2, Theme.dim, 1)
end

function Page.draw()
  local w, h = Layout.vw, Layout.vh
  local r = Page.rects(w, h, Layout.isPortrait())
  love.graphics.setColor(Theme.void)
  love.graphics.rectangle("fill", 0, 0, w, h)
  drawHeader(r.header)
  drawTabs(r.tabs)
  drawList(r.list)
  drawPreview(r.preview)
  drawFooter(r.footer)
end

return Page
