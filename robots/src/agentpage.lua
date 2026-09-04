-- One robot's page: the head, and everything filed under it.
--
-- This is the screen that makes the central idea visible. An agent here is not
-- a prompt with a name on it — it is a GUID, a folder, and six shelves:
-- photos, videos, markdown, files, notes, and the papers drawn from all of
-- those. A video plays as the three-second Ogg Theora clip the backend made
-- beside it, because that is the one moving picture LOVE can decode.
-- What the page draws is exactly what the turn retrieves from, so "what does
-- this robot know" has one answer and you can look at it.
--
-- With no robot chosen the same page draws the global space — and the
-- photo shelf, in that case, is every robot's photos at once, each with its
-- owner's name on it, because nobody chosen means all of them.
--
-- The photo shelf has two shapes: a list with a preview, and a grid of
-- thumbnails (`G`, or the GRID button). `/` opens a search box that runs
-- BM25 and vectors over the chosen robot's own database — or over every
-- robot, with nobody chosen — and puts the hits on a shelf of their own.

local Actions = require("src.actions")
local Backend = require("src.backend")
local Font = require("src.font")
local Input = require("src.input")
local Layout = require("src.layout")
local Json = require("src.json")
local Photos = require("src.photos")
local Robots = require("src.robots")
local Sprites = require("src.sprites")
local Theme = require("src.theme")
local UI = require("src.ui")
local Videos = require("src.videos")

local Page = {
  shelf = 1,
  cursor = 1,
  scroll = 0,
  t = 0,
  -- The photo shelf as thumbnails rather than a list.
  grid = false,
  -- The search box: open, what is in it, and what it found.
  searching = false,
  query = "",
  hits = nil,        -- the last reply's hit list, or nil
  hitsFor = nil,     -- the query those hits answer
  searchBusy = false,
  searchError = nil,
  -- A one-line notice under the header: what the last action did.
  notice = nil,
  noticeTone = "info",
  noticeT = 0,
}

-- The shelves, in the order the page shows them. `field` is the key the
-- backend's `page` op answers with; the last is the search, whose rows come
-- from a `search` reply instead.
Page.SHELVES = {
  { id = "gallery",   field = "gallery",   label = "PHOTOS",   color = Theme.cyan },
  { id = "videos",    field = "videos",    label = "VIDEO",    color = Theme.violet },
  { id = "markdowns", field = "markdowns", label = "MARKDOWN", color = Theme.jade },
  { id = "files",     field = "files",     label = "FILES",    color = Theme.amber },
  { id = "notes",     field = "notes",     label = "NOTES",    color = Theme.magenta },
  { id = "papers",    field = "papers",    label = "PAPER",    color = Theme.paper },
  { id = "search",    field = nil,         label = "SEARCH",   color = Theme.gold },
}
Page.GALLERY = 1
Page.VIDEOS = 2
Page.PAPERS = 6
Page.SEARCH = 7

local HEADER = 46
local TABS = 15
local NOTICE = 11

function Page.enter()
  Page.t = 0
  Page.cursor = 1
  Page.scroll = 0
  Page.searching = false
  if not Robots.pageFresh() then Robots.loadPage() end
end

function Page.shelfDef()
  return Page.SHELVES[Page.shelf] or Page.SHELVES[1]
end

--- Open on the photo shelf, as a grid. What `gallery` asks for.
function Page.showGallery()
  Page.setShelf(Page.GALLERY)
  Page.grid = true
  Page.searching = false
end

--- Open on the paper shelf, newest paper under the cursor.
function Page.showPapers()
  Page.setShelf(Page.PAPERS)
  Page.grid = false
  Page.cursor = 1
  Page.searching = false
  Robots.page = nil
  Robots.pageFor = false
end

--- Is the photo shelf showing everybody's photos? Only with nobody chosen.
function Page.galleryIsEverybody()
  return Page.shelfDef().id == "gallery" and Robots.selected == nil
end

--- The rows of the shelf being looked at. Always a table, so the drawing code
--- never has to ask whether the page has arrived.
function Page.items()
  local shelf = Page.shelfDef()
  if shelf.id == "search" then
    local out = {}
    for _, hit in ipairs(Page.hits or {}) do
      local item = hit.item or {}
      item.abs = item.abs or hit.abs
      item.agent_name = hit.agent_name
      item.via = hit.via
      item.score = hit.score
      out[#out + 1] = item
    end
    return out
  end
  -- Nobody chosen: everybody's photos, once they have arrived. Until
  -- then the global page's own photos, so the shelf is never blank for
  -- the length of a round trip.
  if Page.galleryIsEverybody() and type(Robots.galleryAll) == "table" then
    return Robots.galleryAll
  end
  if not Robots.pageFresh() then return {} end
  local list = Robots.page[shelf.field]
  return type(list) == "table" and list or {}
end

function Page.count(shelf)
  if shelf.id == "search" then return #(Page.hits or {}) end
  if shelf.id == "gallery" and Robots.selected == nil and type(Robots.galleryAll) == "table" then
    return #Robots.galleryAll
  end
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

function Page.say(text, tone)
  Page.notice = tostring(text or ""):upper()
  Page.noticeTone = tone or "info"
  Page.noticeT = 0
end

-- ------------------------------------------------------------- geometry ---

--- Every rectangle on the page, from the canvas size. Pure arithmetic and no
--- `love.*`, so the arrangement can be checked headlessly.
function Page.rects(w, h, portrait)
  local top = HEADER + TABS + NOTICE + 4
  if portrait then
    -- Two bands: the list above, the preview below. A 360-wide column cannot
    -- hold a list and a picture side by side.
    local listH = math.floor((h - top - 14) * 0.42)
    return {
      header  = { x = 0, y = 0, w = w, h = HEADER },
      tabs    = { x = 0, y = HEADER, w = w, h = TABS },
      notice  = { x = 0, y = HEADER + TABS, w = w, h = NOTICE },
      list    = { x = 4, y = top, w = w - 8, h = listH },
      preview = { x = 4, y = top + listH + 4, w = w - 8, h = h - top - listH - 18 },
      grid    = { x = 4, y = top, w = w - 8, h = h - top - 14 },
      footer  = { x = 0, y = h - 12, w = w, h = 12 },
    }
  end
  local listW = math.floor(w * 0.38)
  return {
    header  = { x = 0, y = 0, w = w, h = HEADER },
    tabs    = { x = 0, y = HEADER, w = w, h = TABS },
    notice  = { x = 0, y = HEADER + TABS, w = w, h = NOTICE },
    list    = { x = 4, y = top, w = listW, h = h - top - 14 },
    preview = { x = listW + 8, y = top, w = w - listW - 12, h = h - top - 14 },
    grid    = { x = 4, y = top, w = w - 8, h = h - top - 14 },
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

--- How a grid of `count` thumbnails fits a rectangle: the columns, the cell,
--- and the first row drawn so the cursor's row is on screen. Pure.
function Page.gridLayout(r, count, cursor, cell, gap)
  cell = cell or 64
  gap = gap or 6
  local inner = r.w - gap * 2
  local cols = math.max(1, math.floor((inner + gap) / (cell + gap)))
  -- Widen the cells to use the row, rather than leaving a margin on the right.
  cell = math.floor((inner - gap * (cols - 1)) / cols)
  local rowsTotal = math.max(1, math.ceil(math.max(count, 1) / cols))
  local rowsVisible = math.max(1, math.floor((r.h - 12 - gap + gap) / (cell + 14 + gap)))
  local cursorRow = math.floor((math.max(1, cursor) - 1) / cols) + 1
  local first = Page.window(rowsTotal, cursorRow, rowsVisible)
  return {
    cols = cols, cell = cell, gap = gap,
    rows = rowsTotal, rowsVisible = rowsVisible, first = first,
    x = r.x + gap, y = r.y + 12 + gap,
  }
end

--- Where thumbnail `i` goes under that layout, or nil when it is scrolled off.
function Page.gridPos(g, i)
  local col = (i - 1) % g.cols
  local row = math.floor((i - 1) / g.cols) + 1
  if row < g.first or row >= g.first + g.rowsVisible then return nil end
  return g.x + col * (g.cell + g.gap), g.y + (row - g.first) * (g.cell + 14 + g.gap), row, col
end

--- The tab labels that fit a row `w` wide: the full names with counts, or
--- the names without counts on the tabs not chosen, or three-letter names
--- — whichever is the longest form that fits. Pure; `counts[i]` is the
--- number on tab `i`, `shown[i]` whether the tab is drawn at all.
function Page.tabLabels(w, counts, shown, chosen)
  local function width(labels)
    local total = 4
    for i, label in ipairs(labels) do
      if shown[i] then total = total + #label * 8 + 10 + 3 end
    end
    return total
  end
  local forms = {
    function(i, s) return string.format("%s %d", s.label, counts[i] or 0) end,
    function(i, s)
      if i == chosen then return string.format("%s %d", s.label, counts[i] or 0) end
      return s.label
    end,
    function(i, s) return s.label:sub(1, 3) .. " " .. tostring(counts[i] or 0) end,
    function(i, s) return s.label:sub(1, 3) end,
  }
  local labels
  for _, form in ipairs(forms) do
    labels = {}
    for i, s in ipairs(Page.SHELVES) do labels[i] = form(i, s) end
    if width(labels) <= w - 48 then return labels end
  end
  return labels
end

--- Shorten a path to fit, keeping the end -- the filename is the useful half.
function Page.fitPath(path, chars)
  path = tostring(path or "")
  if #path <= chars then return path end
  return "..." .. path:sub(#path - chars + 4)
end

-- ------------------------------------------------------------- behaviour ---

--- Run the box's query against the chosen robot, or everybody.
function Page.search(query)
  query = tostring(query or Page.query):gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then return false end
  Page.query = query
  Page.searchBusy = true
  Page.searchError = nil
  Page.setShelf(Page.SEARCH)
  Page.say("SEARCHING " .. (Robots.selected and Robots.name() or "ALL AGENTS") .. " FOR " .. query, "info")
  return Robots.search(query, "hybrid", function(data, err)
    Page.searchBusy = false
    if err or type(data) ~= "table" then
      Page.searchError = err or "NO ANSWER"
      Page.hits = {}
      Page.say("SEARCH FAILED  " .. tostring(err or ""), "warn")
      return
    end
    Page.hits = data.hits or {}
    Page.hitsFor = query
    Page.cursor = 1
    Actions.lastSearch = data
    Page.say(string.format("%d HIT%s FOR %s  //  %s", #Page.hits, #Page.hits == 1 and "" or "S",
      query, tostring(data.scope) == "all" and "ALL AGENTS" or Robots.name()),
      #Page.hits > 0 and "good" or "info")
  end)
end

local function handleSearchInput()
  if Input.text ~= "" then
    Page.query = Page.query .. Input.text
  end
  if Input.backspace and #Page.query > 0 then
    Page.query = Page.query:sub(1, -2)
  end
  if Input.wasKey("return") or Input.wasKey("kpenter") then
    Page.searching = false
    Page.search(Page.query)
  end
  if Input.wasKey("escape") then
    Page.searching = false
  end
end

--- Returns "back" when the operator is done with the page.
function Page.update(dt)
  Page.t = Page.t + dt
  Page.noticeT = Page.noticeT + dt

  -- Only ask when there is something to ask. With no backend built, `call`
  -- answers instantly with its reason, and an unguarded retry here would run
  -- one round of that per frame for as long as the page is open.
  if Backend.ready and not Robots.pageFresh() and not Robots.pageBusy then
    Robots.loadPage()
  end
  if Backend.ready and Page.galleryIsEverybody() and not Robots.galleryAll and not Robots.galleryBusy then
    Robots.loadGallery()
  end

  if Page.searching then
    handleSearchInput()
    return nil
  end

  if Input.wasKey("escape") then return "back" end
  if Input.wasKey("tab") then
    Page.setShelf(Page.shelf + 1)
  end
  for i = 1, #Page.SHELVES do
    if Input.wasKey(tostring(i)) then Page.setShelf(i) end
  end
  if Input.wasKey("g") then Page.grid = not Page.grid end
  if Input.wasKey("/") or Input.wasKey("s") then
    Page.searching = true
  end
  if Input.wasKey("p") then Actions.run("photo", nil, Page.say) end
  if Input.wasKey("f") then Actions.run("file", nil, Page.say) end
  if Input.wasKey("x") then Actions.run("paper", nil, Page.say) end

  local inGrid = Page.grid and Page.shelfDef().id == "gallery"
  if inGrid then
    local g = Page.gridLayout(Page.rects(Layout.vw, Layout.vh, Layout.isPortrait()).grid,
      #Page.items(), Page.cursor)
    if Input.wasKey("left") then Page.move(-1) end
    if Input.wasKey("right") then Page.move(1) end
    if Input.wasKey("up") then Page.move(-g.cols) end
    if Input.wasKey("down") then Page.move(g.cols) end
    if Input.wasKey("return") or Input.wasKey("kpenter") then Page.grid = false end
    if (Input.wheel or 0) ~= 0 then Page.move(Input.wheel > 0 and -g.cols or g.cols) end
  else
    if Input.wasKey("up") then Page.move(-1) end
    if Input.wasKey("down") then Page.move(1) end
    if Input.wasKey("pageup") then Page.move(-6) end
    if Input.wasKey("pagedown") then Page.move(6) end
    if Input.wasKey("left") then Robots.cycle(-1) Page.enter() end
    if Input.wasKey("right") then Robots.cycle(1) Page.enter() end
    if (Input.wheel or 0) ~= 0 then Page.move(Input.wheel > 0 and -1 or 1) end
  end
  if Input.wasKey("r") then
    Robots.page = nil
    Robots.pageFor = false
    Robots.galleryAll = nil
  end
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
    Font.print(("NO ROBOT CHOSEN  //  GLOBAL SPACE  //  ALL AGENTS SEARCHED"):sub(1, room), tx, 23, Theme.paper, 1)
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
  local counts, shown = {}, {}
  for i, shelf in ipairs(Page.SHELVES) do
    counts[i] = Page.count(shelf)
    -- The search shelf is a tab only once there is something on it.
    shown[i] = shelf.id ~= "search" or Page.hits ~= nil or Page.searchBusy
  end
  local labels = Page.tabLabels(r.w, counts, shown, Page.shelf)
  local x = 4
  for i, shelf in ipairs(Page.SHELVES) do
    if shown[i] then
      local label = labels[i]
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
  -- The grid switch lives with the tabs, because it is a way of looking at
  -- one of them.
  if Page.shelfDef().id == "gallery" and x + 44 <= r.w - 4 then
    if UI.button("grid", r.w - 46, r.y + 1, 42, r.h - 3, Page.grid and "LIST" or "GRID",
      { stroke = Theme.cyan, on = Page.grid, onColor = Theme.cyan, scale = 1 }) then
      Page.grid = not Page.grid
    end
  end
end

local TONE = { info = Theme.dim, good = Theme.jade, warn = Theme.crimson }

local function drawNotice(r)
  love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.8))
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  if Page.searching then
    -- The box, in place of the notice: a prompt and the query with a caret.
    local where = Robots.selected and Robots.name() or "ALL AGENTS"
    local prompt = "SEARCH " .. where .. "> "
    Font.print(prompt, 4, r.y + 2, Theme.gold, 1)
    local chars = math.max(8, math.floor((r.w - 8) / 8) - #prompt - 1)
    local q = Page.query:upper()
    if #q > chars then q = q:sub(#q - chars + 1) end
    Font.print(q, 4 + #prompt * 8, r.y + 2, Theme.paper, 1)
    if math.floor(Page.t * 2) % 2 == 0 then
      love.graphics.setColor(Theme.paper)
      love.graphics.rectangle("fill", 4 + (#prompt + #q) * 8, r.y + 2, 6, 8)
    end
    return
  end
  if Page.notice and Page.noticeT < 12 then
    Font.print(Page.notice:sub(1, math.floor((r.w - 8) / 8)), 4, r.y + 2,
      TONE[Page.noticeTone] or Theme.dim, 1)
  elseif Page.searchBusy then
    Font.print("SEARCHING...", 4, r.y + 2, Theme.gold, 1)
  end
end

--- The label a row gets: the title, and the owner when it is not this page's.
local function rowLabel(item)
  local title = tostring(item.title or ""):upper()
  -- A message's title is its role; the words are what the row is about.
  if item.kind == "message" then
    local words = tostring(item.body or ""):gsub("%s+", " "):gsub("^%s+", "")
    title = title:sub(1, 4) .. "> " .. words:upper()
  end
  if item.agent_name then
    title = tostring(item.agent_name):upper() .. ": " .. title
  end
  return title
end

local function emptyWhy()
  local shelf = Page.shelfDef()
  if not Backend.ready then return Backend.reason end
  if shelf.id == "search" then
    if Page.searchBusy then return "SEARCHING..." end
    if Page.searchError then return "SEARCH FAILED  " .. tostring(Page.searchError) end
    return "NO HITS. PRESS / TO SEARCH AGAIN."
  end
  if Page.galleryIsEverybody() then
    if Robots.galleryBusy or not Robots.galleryAll then return "READING EVERY FOLDER..." end
    return "NO PHOTOS IN ANY FOLDER YET. TYPE PHOTO, OR DROP ONE ON THE WINDOW."
  end
  if not Robots.pageFresh() then return "READING ARCHIVE..." end
  if shelf.id == "papers" then return "NO PAPER DRAWN YET. PRESS X, OR THE PAPER BUTTON." end
  if shelf.id == "videos" then
    return "NO VIDEOS YET. DROP A .MOV OR .MP4 ON THE WINDOW: THE ORIGINAL IS KEPT, " ..
      "AND A 3-SECOND CLIP IS MADE FOR THIS SCREEN."
  end
  return "SHELF EMPTY"
end

local function drawList(r)
  local shelf = Page.shelfDef()
  local title = shelf.label
  if shelf.id == "search" and Page.hitsFor then title = "SEARCH: " .. Page.hitsFor:upper():sub(1, 20) end
  UI.panel(r.x, r.y, r.w, r.h, title, shelf.color)
  local items = Page.items()
  if #items == 0 then
    Font.printf(emptyWhy(), r.x + 8, r.y + 14, r.w - 16, Theme.dim, 1)
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
    Font.print(rowLabel(item):sub(1, chars), r.x + 8, y + 2, on and Theme.ice or Theme.paper, 1)
  end

  if #items > rows then
    Font.print(string.format("%d/%d", Page.cursor, #items),
      r.x + r.w - 46, r.y + r.h - 10, Theme.dim, 1)
  end
end

--- What a video row says about its clip: the backend's `meta`, decoded.
function Page.clipMeta(item)
  local ok, meta = pcall(Json.decode, tostring(item and item.meta or ""))
  return ok and type(meta) == "table" and meta or {}
end

--- The video shelf's preview: the LOVE clip looping, the poster frame when
--- there is no clip yet, and the reason when there is neither.
local function drawVideo(item, x, y, w, h)
  local meta = Page.clipMeta(item)
  local video = item.clip and Videos.get(item.clip) or nil
  if video then
    Videos.tick(video)
    Sprites.drawFit(video, x, y, w, h - 12, 1)
    local line = string.format("LOVE CLIP  %s  %dX%d  %s",
      tostring(meta.seconds and (math.floor(meta.seconds + 0.5) .. "S") or "3S"),
      video:getWidth(), video:getHeight(), Photos.size(meta.bytes))
    Font.print(line:sub(1, math.floor(w / 8)), x, y + h - 9, Theme.violet, 1)
    return
  end
  local poster = item.poster and Photos.get(item.poster) or nil
  if poster then
    Sprites.drawFit(poster, x, y, w, h - 12, 0.7)
  end
  local why
  if item.clip then
    why = "CANNOT PLAY " .. Page.fitPath(item.clip, 30)
  else
    why = "NO LOVE CLIP: " .. tostring(meta.why or "NOT MADE YET")
  end
  Font.printf(why:upper(), x, poster and (y + h - 9) or y, w, Theme.crimson, 1)
end

local function drawPreview(r)
  local item = Page.selected()
  local shelf = Page.shelfDef()
  UI.panel(r.x, r.y, r.w, r.h, "ITEM", shelf.color)
  if not item then
    Font.printf("NOTHING ON THIS SHELF YET. TYPE PHOTO OR FILE, PRESS P OR F, OR DROP A FILE " ..
      "ON THE WINDOW TO FILE ONE WITH THIS ROBOT.", r.x + 8, r.y + 16, r.w - 16, Theme.dim, 1)
    return
  end

  Font.print(tostring(item.title or ""):upper():sub(1, math.floor((r.w - 16) / 8)),
    r.x + 8, r.y + 14, Theme.ice, 1)
  local meta = string.format("#%d  %s  %s", item.id or 0,
    tostring(item.kind or ""):upper(), Photos.size(item.bytes))
  if item.agent_name then meta = meta .. "  FROM " .. tostring(item.agent_name):upper() end
  if item.via then meta = meta .. "  VIA " .. tostring(item.via):upper() end
  Font.print(meta:sub(1, math.floor((r.w - 16) / 8)), r.x + 8, r.y + 24, Theme.dim, 1)

  local bodyY = r.y + 36
  local bodyH = r.h - (bodyY - r.y) - 8

  if item.kind == "video" then
    drawVideo(item, r.x + 8, bodyY, r.w - 16, bodyH)
  elseif item.abs and tostring(item.mime or ""):find("^image/") then
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

--- The photo shelf as thumbnails. Every cell is a picture and a caption; the
--- caption is the owner's name when the shelf is everybody's.
local function drawGrid(r)
  local shelf = Page.shelfDef()
  local items = Page.items()
  local title = Page.galleryIsEverybody() and "PHOTOS  //  EVERY AGENT" or "PHOTOS"
  UI.panel(r.x, r.y, r.w, r.h, title, shelf.color)
  if #items == 0 then
    Font.printf(emptyWhy(), r.x + 8, r.y + 14, r.w - 16, Theme.dim, 1)
    return
  end
  Page.cursor = math.max(1, math.min(#items, Page.cursor))
  local g = Page.gridLayout(r, #items, Page.cursor)
  for i, item in ipairs(items) do
    local x, y = Page.gridPos(g, i)
    if x then
      local on = i == Page.cursor
      if Layout.hit(x, y, g.cell, g.cell + 12) then
        if Input.pressed then
          if Page.cursor == i then Page.grid = false else Page.cursor = i end
        end
        love.graphics.setColor(Theme.withAlpha(shelf.color, 0.12))
        love.graphics.rectangle("fill", x - 1, y - 1, g.cell + 2, g.cell + 14)
      end
      love.graphics.setColor(Theme.panel2)
      love.graphics.rectangle("fill", x, y, g.cell, g.cell)
      local img = item.abs and Photos.get(item.abs) or nil
      if img then
        Sprites.drawCover(img, x, y, g.cell, g.cell, 1)
      else
        Font.print("?", x + g.cell / 2 - 4, y + g.cell / 2 - 4, Theme.dim, 1)
      end
      love.graphics.setColor(on and Theme.ice or Theme.withAlpha(shelf.color, 0.5))
      love.graphics.rectangle("line", x + 0.5, y + 0.5, g.cell - 1, g.cell - 1)
      local caption = item.agent_name and tostring(item.agent_name) or tostring(item.title or "")
      Font.print(caption:upper():sub(1, math.floor(g.cell / 8)), x, y + g.cell + 3,
        on and Theme.ice or Theme.dim, 1)
    end
  end
  Font.print(string.format("%d/%d", Page.cursor, #items), r.x + r.w - 46, r.y + r.h - 10, Theme.dim, 1)
end

local function drawFooter(r)
  love.graphics.setColor(Theme.withAlpha(Theme.navy, 0.9))
  love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
  -- The buttons: the same five actions the console words run.
  local x = 2
  local function btn(id, label, color, action)
    local w = #label * 8 + 8
    if UI.button("pg" .. id, x, r.y + 1, w, r.h - 2, label, { stroke = color, scale = 1 }) then
      action()
    end
    x = x + w + 2
  end
  btn("photo", "PHOTO", Theme.cyan, function() Actions.run("photo", nil, Page.say) end)
  btn("file", "FILE", Theme.amber, function() Actions.run("file", nil, Page.say) end)
  btn("paper", "PAPER", Theme.paper, function() Actions.run("paper", nil, Page.say) end)
  btn("search", "SEARCH", Theme.gold, function() Page.searching = true end)
  local hint = "TAB SHELF  ARROWS PICK  G GRID  / SEARCH  L/R AGENT  ESC BACK  DROP A FILE TO ADD"
  local room = math.floor((r.w - x - 4) / 8)
  if room > 8 then Font.print(hint:sub(1, room), x + 2, r.y + 2, Theme.dim, 1) end
end

function Page.draw()
  local w, h = Layout.vw, Layout.vh
  local r = Page.rects(w, h, Layout.isPortrait())
  love.graphics.setColor(Theme.void)
  love.graphics.rectangle("fill", 0, 0, w, h)
  drawHeader(r.header)
  drawTabs(r.tabs)
  drawNotice(r.notice)
  if Page.grid and Page.shelfDef().id == "gallery" then
    drawGrid(r.grid)
  else
    drawList(r.list)
    drawPreview(r.preview)
  end
  drawFooter(r.footer)
end

return Page
