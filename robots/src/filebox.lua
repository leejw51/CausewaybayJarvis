-- A file box drawn by LOVE itself.
--
-- The operating system's dialog opens *behind* a fullscreen LOVE window on
-- macOS, so `photo` and `file` used to open a box nobody could see. This
-- one is a screen of this client, drawn over whatever was showing: the
-- folder's name, a column of places to jump to, the entries with the
-- folders first, a preview of the picture under the cursor, and a button
-- that files what was picked. Nothing leaves the window.
--
-- The disk is read with `ls -1pA`, one folder at a time, on the frame the
-- folder is entered: `love.filesystem` cannot see outside the sandbox, and
-- a listing is cheap enough that a thread would only add a round trip.
--
--   up / down, pageup / pagedown, home / end   move
--   return                                     open the folder, or file just that file
--   space                                      pick this entry (several at once)
--   cmd/ctrl + a                               pick everything in the folder
--   backspace                                  the parent folder
--   letters                                    jump to a name
--   escape                                     cancel
--   click                                      move there; twice, open or file it
--
-- `photo` narrows the entries to pictures and videos; `file` shows everything.
--
-- ADD with nothing picked takes **every file in the folder being looked at**:
-- a folder of pictures is opened in order to add the pictures, and sixty
-- presses of `space` was the wrong default. `return` files just the one file.
--
-- A picked folder is not filed either: ADD reads it all the way down and
-- files what is inside, so a holiday is one pick rather than sixty. That
-- walk runs a few folders a frame with a bar over the box.

local Ease = require("src.ease")
local Font = require("src.font")
local Input = require("src.input")
local Layout = require("src.layout")
local Photos = require("src.photos")
local Theme = require("src.theme")
local UI = require("src.ui")

local FileBox = {
  open = false,
  kind = "file",
  dir = nil,          -- the folder being looked at
  entries = {},       -- { name, path, dir = bool }, folders first
  cursor = 1,
  picked = {},        -- path -> true, in this folder or another
  pickedList = {},    -- the same, in the order they were picked
  cb = nil,
  error = nil,
  t = 0,
  lastClick = { i = 0, t = -1 },
  typed = "",
  typedAt = -1,
  -- The recursive walk behind a picked folder, while it runs.
  scan = nil,
}

FileBox.IMAGE_EXT = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true }
FileBox.VIDEO_EXT = { mp4 = true, mov = true, m4v = true, webm = true, mkv = true, avi = true, ogv = true }

local ROW = 11
local PLACES_W = 76

local function home()
  return os.getenv("HOME") or "/"
end

--- The places on the left: the folders a picture or a file is likely to be.
--- Only the ones that exist are shown, so a machine without a Movies folder
--- does not offer one.
function FileBox.places()
  local h = home()
  local out = {}
  local function add(label, path)
    if FileBox.isDir(path) then out[#out + 1] = { label = label, path = path } end
  end
  add("HOME", h)
  add("DESKTOP", h .. "/Desktop")
  add("DOWNLOAD", h .. "/Downloads")
  add("PICTURES", h .. "/Pictures")
  add("MOVIES", h .. "/Movies")
  add("DOCS", h .. "/Documents")
  add("VOLUMES", "/Volumes")
  add("ROOT", "/")
  return out
end

function FileBox.isDir(path)
  if not path or path == "" then return false end
  local ok = os.execute("[ -d '" .. path:gsub("'", "'\\''") .. "' ]")
  return ok == 0 or ok == true
end

--- The extension of a name, lower-cased, or "".
function FileBox.ext(name)
  return (tostring(name or ""):match("%.([%w]+)$") or ""):lower()
end

--- Does a `photo` box show this file? Pictures and videos: a video is what
--- the phone's camera roll is half made of, and it lands on its own shelf.
function FileBox.wanted(name, kind)
  if kind ~= "photo" then return true end
  local e = FileBox.ext(name)
  return FileBox.IMAGE_EXT[e] == true or FileBox.VIDEO_EXT[e] == true
end

--- `ls -1pA` output into entries: a trailing `/` marks a folder, dotfiles
--- are skipped, folders come first and each half is sorted without regard
--- to case. Pure, for the tests.
function FileBox.parseListing(out, dir, kind)
  local dirs, files = {}, {}
  dir = tostring(dir or "/"):gsub("/+$", "")
  for line in tostring(out or ""):gmatch("[^\r\n]+") do
    local isDir = line:sub(-1) == "/"
    local name = isDir and line:sub(1, -2) or line
    if name ~= "" and name:sub(1, 1) ~= "." then
      local path = dir .. "/" .. name
      if isDir then
        dirs[#dirs + 1] = { name = name, path = path, dir = true }
      elseif FileBox.wanted(name, kind) then
        files[#files + 1] = { name = name, path = path, dir = false }
      end
    end
  end
  local function byName(a, b) return a.name:lower() < b.name:lower() end
  table.sort(dirs, byName)
  table.sort(files, byName)
  for _, f in ipairs(files) do dirs[#dirs + 1] = f end
  return dirs
end

--- The folder above. `/` is its own parent.
function FileBox.parent(path)
  path = tostring(path or "/"):gsub("/+$", "")
  if path == "" then return "/" end
  local up = path:match("^(.*)/[^/]+$")
  if not up or up == "" then return "/" end
  return up
end

--- Read one folder off the disk.
function FileBox.list(dir, kind)
  local quoted = "'" .. tostring(dir):gsub("'", "'\\''") .. "'"
  local pipe = io.popen("ls -1pA -- " .. quoted .. " 2>/dev/null", "r")
  if not pipe then return {}, "CANNOT LIST " .. tostring(dir) end
  local out = pipe:read("*a") or ""
  pipe:close()
  return FileBox.parseListing(out, dir, kind), nil
end

--- Go to a folder: list it and put the cursor at the top.
function FileBox.enter(dir)
  dir = tostring(dir or home()):gsub("/+$", "")
  if dir == "" then dir = "/" end
  local entries, err = FileBox.list(dir, FileBox.kind)
  FileBox.dir = dir
  FileBox.entries = entries
  FileBox.cursor = 1
  FileBox.error = err
  FileBox.typed = ""
end

--- Open the box. `cb(paths)` fires once, with the paths picked — none
--- when the box was cancelled.
function FileBox.show(kind, cb)
  FileBox.kind = kind == "photo" and "photo" or "file"
  FileBox.cb = cb
  FileBox.picked = {}
  FileBox.pickedList = {}
  FileBox.open = true
  FileBox.t = 0
  FileBox.error = nil
  local start = FileBox.dir
  if not start or not FileBox.isDir(start) then
    -- A photo box opens on the pictures, a file box on the desk.
    start = FileBox.kind == "photo" and home() .. "/Pictures" or home() .. "/Desktop"
    if not FileBox.isDir(start) then start = home() end
  end
  FileBox.enter(start)
  return true
end

--- Close it, answering with `paths`.
function FileBox.close(paths)
  if not FileBox.open then return end
  FileBox.open = false
  local cb = FileBox.cb
  FileBox.cb = nil
  FileBox.picked = {}
  FileBox.pickedList = {}
  if cb then cb(paths or {}) end
end

function FileBox.selected()
  return FileBox.entries[math.max(1, math.min(#FileBox.entries, FileBox.cursor))]
end

--- Pick an entry, or unpick it. A folder may be picked: ADD walks it and
--- files everything underneath, which is what picking a folder means.
--- What is remembered is `"dir"` or `"file"`, because by the time ADD runs
--- the entry itself is long gone.
function FileBox.toggle(entry)
  if not entry then return end
  if FileBox.picked[entry.path] then
    FileBox.picked[entry.path] = nil
    for i, p in ipairs(FileBox.pickedList) do
      if p == entry.path then table.remove(FileBox.pickedList, i) break end
    end
  else
    FileBox.picked[entry.path] = entry.dir and "dir" or "file"
    FileBox.pickedList[#FileBox.pickedList + 1] = entry.path
  end
end

--- What ADD takes, sorted into the files that go straight out and the
--- folders that have to be read first.
---
--- With nothing picked it is **every file in the folder being looked at**,
--- rather than the one under the cursor: a folder of pictures is opened in
--- order to add the pictures, and making that sixty presses of `space` was
--- the wrong default. Subfolders are left alone -- picking one with `space`
--- is how you say you want what is under it too. `return` on a single file
--- is still the way to file exactly that one.
function FileBox.split()
  local files, dirs = {}, {}
  if #FileBox.pickedList > 0 then
    for _, p in ipairs(FileBox.pickedList) do
      if FileBox.picked[p] == "dir" then dirs[#dirs + 1] = p else files[#files + 1] = p end
    end
    return files, dirs
  end
  for _, e in ipairs(FileBox.entries) do
    if not e.dir then files[#files + 1] = e.path end
  end
  return files, dirs
end

--- Those same paths in one list, for the count on the button.
function FileBox.picks()
  local files, dirs = FileBox.split()
  for _, d in ipairs(dirs) do files[#files + 1] = d end
  return files
end

--- Whether ADD is about to take the whole folder rather than a hand-made
--- pick, which is what the button says.
function FileBox.takingAll()
  return #FileBox.pickedList == 0
end

--- ADD. Plain files go straight out; a folder among the picks starts the
--- walk below, and the box stays up with a bar on it until that is done.
function FileBox.commit()
  local files, dirs = FileBox.split()
  if #dirs == 0 then FileBox.close(files) return end
  FileBox.startScan(dirs, files)
end

--- Return, or a second click: into a folder, or out with exactly the file
--- under the cursor. A folder still *opens* here -- walking it is what ADD
--- is for, and a box where return sometimes navigates and sometimes files
--- would be a trap. This is also the way to file one file out of a folder
--- of a hundred, now that ADD means all of them.
function FileBox.activate()
  local e = FileBox.selected()
  if not e then return end
  if e.dir then
    FileBox.enter(e.path)
  else
    FileBox.close({ e.path })
  end
end

function FileBox.move(step)
  if #FileBox.entries == 0 then return end
  FileBox.cursor = math.max(1, math.min(#FileBox.entries, FileBox.cursor + step))
end

-- ---------------------------------------------------------------- the walk ---
--
-- A picked folder is read all the way down. The walk is spread across frames
-- rather than done in one `find`: a folder of ten thousand pictures would
-- otherwise freeze the window for as long as the disk took, and a bar that
-- only appears after the work is finished is not a bar. So a queue of folders
-- is kept and a handful are read each frame, which is also where the count
-- that drives the bar comes from -- folders read against folders still owed.
--
-- Both caps are there because a walk from `/` is one keypress away.

FileBox.SCAN_DIRS_PER_FRAME = 6
FileBox.SCAN_MAX_FILES = 4000
FileBox.SCAN_MAX_DIRS = 3000
-- How long the bar takes to glide to a new reading, in seconds.
FileBox.SCAN_GLIDE = 0.42

--- Begin the walk. `files` are the plain picks, kept at the front of what is
--- finally filed so that what was picked by hand arrives first.
function FileBox.startScan(dirs, files)
  local scan = {
    queue = {},
    files = {},
    have = {},
    roots = #dirs,
    dirsRead = 0,
    at = dirs[1] or "",
    capped = false,
    t = 0,
    shown = 0, from = 0, to = 0, tw = 1,
  }
  for _, p in ipairs(files or {}) do
    if not scan.have[p] then
      scan.have[p] = true
      scan.files[#scan.files + 1] = p
    end
  end
  for _, d in ipairs(dirs) do scan.queue[#scan.queue + 1] = d end
  FileBox.scan = scan
  return scan
end

--- Give up on the walk and go back to the box.
function FileBox.cancelScan()
  FileBox.scan = nil
end

--- Read up to `SCAN_DIRS_PER_FRAME` folders, then move the bar. Split out so
--- a test can drive it a frame at a time with `FileBox.list` stubbed.
function FileBox.scanStep(dt)
  local s = FileBox.scan
  if not s then return end
  s.t = s.t + (dt or 0)

  for _ = 1, FileBox.SCAN_DIRS_PER_FRAME do
    local dir = table.remove(s.queue, 1)
    if not dir then break end
    s.at = dir
    s.dirsRead = s.dirsRead + 1
    for _, e in ipairs(FileBox.list(dir, FileBox.kind)) do
      if e.dir then
        if s.dirsRead + #s.queue < FileBox.SCAN_MAX_DIRS then
          s.queue[#s.queue + 1] = e.path
        else
          s.capped = true
        end
      elseif #s.files >= FileBox.SCAN_MAX_FILES then
        s.capped = true
      elseif not s.have[e.path] then
        s.have[e.path] = true
        s.files[#s.files + 1] = e.path
      end
    end
    if s.capped and #s.files >= FileBox.SCAN_MAX_FILES then
      s.queue = {}
      break
    end
  end

  -- The reading the bar is heading for. It is honest rather than smooth:
  -- a folder full of folders pushes the target back down, and the glide
  -- below is what keeps that from looking like a stutter.
  local target = #s.queue == 0 and 1 or s.dirsRead / math.max(1, s.dirsRead + #s.queue)
  if math.abs(target - s.to) > 0.0005 then
    s.from, s.to, s.tw = s.shown, target, 0
  end
  s.tw = math.min(1, s.tw + (dt or 0) / FileBox.SCAN_GLIDE)
  s.shown = s.from + (s.to - s.from) * Ease.inOutExpo(s.tw)

  -- The box does not shut the instant the queue empties: the bar is let run
  -- to the end first, so a walk that took no time still reads as one.
  if #s.queue == 0 and s.tw >= 1 then
    local files = s.files
    FileBox.scan = nil
    FileBox.close(files)
  end
end

--- Jump to the first name that starts with what was typed in the last
--- second or so.
function FileBox.jump(text)
  if FileBox.t - FileBox.typedAt > 1.2 then FileBox.typed = "" end
  FileBox.typed = (FileBox.typed .. text):lower()
  FileBox.typedAt = FileBox.t
  for i, e in ipairs(FileBox.entries) do
    if e.name:lower():sub(1, #FileBox.typed) == FileBox.typed then
      FileBox.cursor = i
      return
    end
  end
end

-- ------------------------------------------------------------- geometry ---

--- Every rectangle, from the canvas size. Pure, so it is tested headlessly.
--- Below 480 wide there is no preview: the list needs the room more.
function FileBox.rects(w, h)
  local margin = 8
  local box = { x = margin, y = margin, w = w - margin * 2, h = h - margin * 2 }
  local top = box.y + 14
  local path = { x = box.x + 6, y = top, w = box.w - 12, h = 10 }
  local footer = { x = box.x + 6, y = box.y + box.h - 18, w = box.w - 12, h = 14 }
  local listY = top + 14
  local listH = footer.y - listY - 6
  local places = { x = box.x + 6, y = listY, w = PLACES_W, h = listH }
  local previewW = w >= 480 and math.floor((box.w - PLACES_W - 24) * 0.36) or 0
  local list = {
    x = places.x + places.w + 6, y = listY,
    w = box.w - 12 - places.w - 6 - (previewW > 0 and previewW + 6 or 0), h = listH,
  }
  local preview = { x = list.x + list.w + 6, y = listY, w = previewW, h = listH }
  return { box = box, path = path, places = places, list = list, preview = preview, footer = footer }
end

--- The first row drawn, so the cursor is on screen.
function FileBox.window(count, cursor, rows)
  if count <= rows then return 1 end
  return math.max(1, math.min(count - rows + 1, cursor - math.floor(rows / 2)))
end

-- ------------------------------------------------------------ behaviour ---

--- One frame of keys and the wheel. The buttons are handled in `draw`,
--- because that is where they are.
function FileBox.update(dt)
  if not FileBox.open then return end
  FileBox.t = FileBox.t + (dt or 0)
  local r = FileBox.rects(Layout.vw, Layout.vh)
  local rows = math.max(1, math.floor((r.list.h - 14) / ROW))

  -- While a folder is being read the box is not steerable: the walk owns
  -- the frame, and escape backs out of it rather than out of the box.
  if FileBox.scan then
    if Input.wasKey("escape") then FileBox.cancelScan() return end
    FileBox.scanStep(dt)
    return
  end

  if Input.wasKey("escape") then FileBox.close({}) return end
  if Input.wasKey("return") or Input.wasKey("kpenter") then FileBox.activate() return end
  if Input.backspace then FileBox.enter(FileBox.parent(FileBox.dir)) return end
  if Input.wasKey("space") then FileBox.toggle(FileBox.selected()) end
  if Input.wasKey("up") then FileBox.move(-1) end
  if Input.wasKey("down") then FileBox.move(1) end
  if Input.wasKey("pageup") then FileBox.move(-rows) end
  if Input.wasKey("pagedown") then FileBox.move(rows) end
  if Input.wasKey("home") then FileBox.cursor = 1 end
  if Input.wasKey("end") then FileBox.cursor = math.max(1, #FileBox.entries) end
  local kb = love.keyboard
  local mod = kb and (kb.isDown("lgui") or kb.isDown("rgui") or kb.isDown("lctrl") or kb.isDown("rctrl"))
  if Input.wasKey("a") and mod then
    -- Every entry, rather than the inverse of what is picked: CMD+A on a
    -- half-picked folder should leave it wholly picked.
    local all = true
    for _, e in ipairs(FileBox.entries) do
      if not FileBox.picked[e.path] then all = false break end
    end
    for _, e in ipairs(FileBox.entries) do
      if all or not FileBox.picked[e.path] then FileBox.toggle(e) end
    end
  end
  if (Input.wheel or 0) ~= 0 then FileBox.move(Input.wheel > 0 and -3 or 3) end
  if Input.text ~= "" and Input.text ~= " " and not mod then FileBox.jump(Input.text) end
end

-- ----------------------------------------------------------------- draw ---

local function drawPlaces(r)
  local y = r.y
  for _, place in ipairs(FileBox.places()) do
    if y + 12 > r.y + r.h then break end
    local on = FileBox.dir == place.path
    if UI.button("fb-" .. place.label, r.x, y, r.w, 11, place.label, {
      on = on, onColor = Theme.cyan, stroke = Theme.dim, hot = Theme.cyan, scale = 1, silent = true,
    }) then
      FileBox.enter(place.path)
    end
    y = y + 13
  end
end

local function drawList(r)
  local accent = FileBox.kind == "photo" and Theme.cyan or Theme.amber
  local n = #FileBox.entries
  local count = 0
  for _ in pairs(FileBox.picked) do count = count + 1 end
  local title = string.format("%d ENTR%s", n, n == 1 and "Y" or "IES")
  if count > 0 then title = title .. string.format("  //  %d PICKED", count) end
  UI.panel(r.x, r.y, r.w, r.h, title, accent)
  if n == 0 then
    Font.printf(FileBox.error and FileBox.error:upper()
      or (FileBox.kind == "photo" and "NO PICTURES OR VIDEOS HERE. BACKSPACE GOES UP." or "EMPTY FOLDER. BACKSPACE GOES UP."),
      r.x + 8, r.y + 14, r.w - 16, Theme.dim, 1)
    return
  end
  FileBox.cursor = math.max(1, math.min(n, FileBox.cursor))
  local rows = math.max(1, math.floor((r.h - 14) / ROW))
  local first = FileBox.window(n, FileBox.cursor, rows)
  local chars = math.max(6, math.floor((r.w - 30) / 8))
  for i = first, math.min(n, first + rows - 1) do
    local e = FileBox.entries[i]
    local y = r.y + 12 + (i - first) * ROW
    local on = i == FileBox.cursor
    if Layout.hit(r.x + 2, y, r.w - 4, ROW) then
      love.graphics.setColor(Theme.withAlpha(accent, 0.12))
      love.graphics.rectangle("fill", r.x + 2, y, r.w - 4, ROW)
      if Input.pressed then
        -- A second click on the same row within a moment opens it.
        if FileBox.lastClick.i == i and FileBox.t - FileBox.lastClick.t < 0.45 then
          FileBox.cursor = i
          FileBox.lastClick = { i = 0, t = -1 }
          FileBox.activate()
          return
        end
        FileBox.cursor = i
        FileBox.lastClick = { i = i, t = FileBox.t }
      end
    end
    if on then
      love.graphics.setColor(Theme.withAlpha(accent, 0.24))
      love.graphics.rectangle("fill", r.x + 2, y, r.w - 4, ROW)
      love.graphics.setColor(accent)
      love.graphics.rectangle("fill", r.x + 2, y, 2, ROW)
    end
    local mark = e.dir and ">" or (FileBox.picked[e.path] and "*" or " ")
    local color = e.dir and Theme.gold or (FileBox.picked[e.path] and Theme.jade or (on and Theme.ice or Theme.paper))
    Font.print(mark, r.x + 8, y + 2, e.dir and Theme.gold or Theme.jade, 1)
    Font.print(Font.clip(Font.upper(e.name), chars), r.x + 18, y + 2, color, 1)
  end
  if n > rows then
    Font.print(string.format("%d/%d", FileBox.cursor, n), r.x + r.w - 46, r.y + r.h - 10, Theme.dim, 1)
  end
end

local function drawPreview(r)
  if r.w <= 0 then return end
  UI.panel(r.x, r.y, r.w, r.h, "PREVIEW", Theme.violet)
  local e = FileBox.selected()
  if not e then return end
  local ext = FileBox.ext(e.name)
  local body = { x = r.x + 6, y = r.y + 14, w = r.w - 12, h = r.h - 30 }
  if e.dir then
    Font.printf("FOLDER. RETURN OPENS IT.", body.x, body.y, body.w, Theme.dim, 1)
  elseif FileBox.IMAGE_EXT[ext] then
    local img = Photos.get(e.path)
    if img then
      local Sprites = require("src.sprites")
      Sprites.drawFit(img, body.x, body.y, body.w, body.h, 1)
      Font.print(string.format("%dX%d", img:getWidth(), img:getHeight()), body.x, r.y + r.h - 10, Theme.dim, 1)
    else
      Font.printf("CANNOT DECODE THIS PICTURE.", body.x, body.y, body.w, Theme.crimson, 1)
    end
  elseif FileBox.VIDEO_EXT[ext] then
    Font.printf("VIDEO. THE ORIGINAL IS KEPT AND A 3-SECOND CLIP IS MADE FOR THE VIDEO SHELF.",
      body.x, body.y, body.w, Theme.violet, 1)
  else
    Font.printf(ext ~= "" and (ext:upper() .. " FILE.") or "A FILE.", body.x, body.y, body.w, Theme.dim, 1)
  end
end

--- The bar over the box while a folder is being read. The fill is the eased
--- reading rather than the raw one, so it glides instead of jumping; the
--- sweep behind it rides the same curve back and forth, which is what says
--- the walk is alive on a folder deep enough that the reading barely moves.
function FileBox.drawScan(box)
  local s = FileBox.scan
  if not s then return end
  local w, h = 260, 62
  local x = box.x + math.floor((box.w - w) / 2)
  local y = box.y + math.floor((box.h - h) / 2)

  love.graphics.setColor(0, 0, 0, 0.82)
  love.graphics.rectangle("fill", box.x, box.y, box.w, box.h)
  UI.panel(x, y, w, h, "READING", Theme.jade)

  Font.print(Font.clip(Font.upper(s.at), math.floor((w - 16) / 8)), x + 8, y + 16, Theme.ice, 1)
  Font.print(string.format("%d FILE%s  //  %d FOLDER%s LEFT%s",
    #s.files, #s.files == 1 and "" or "S",
    #s.queue, #s.queue == 1 and "" or "S",
    s.capped and "  //  CAPPED" or ""),
    x + 8, y + 27, s.capped and Theme.amber or Theme.dim, 1)

  local bx, by, bw, bh = x + 8, y + 40, w - 16, 8
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", bx, by, bw, bh)
  -- The sweep: a band travelling the bar on the same ease, dimmed under the
  -- fill so it reads as motion rather than a second reading.
  local sweep = Ease.inOutExpo((s.t * 0.9) % 2 > 1 and 2 - (s.t * 0.9) % 2 or (s.t * 0.9) % 2)
  love.graphics.setColor(Theme.withAlpha(Theme.jade, 0.18))
  love.graphics.rectangle("fill", bx + sweep * (bw - 28), by, 28, bh)
  love.graphics.setColor(Theme.jade)
  love.graphics.rectangle("fill", bx, by, math.max(0, math.min(1, s.shown)) * bw, bh)
  love.graphics.setColor(Theme.dim)
  love.graphics.rectangle("line", bx + 0.5, by + 0.5, bw - 1, bh - 1)

  Font.print(string.format("%3d%%", math.floor(s.shown * 100 + 0.5)), x + w - 40, y + h - 12, Theme.jade, 1)
  Font.print("ESC STOPS", x + 8, y + h - 12, Theme.dim, 1)
end

function FileBox.draw()
  if not FileBox.open then return end
  local w, h = Layout.vw, Layout.vh
  local r = FileBox.rects(w, h)
  local accent = FileBox.kind == "photo" and Theme.cyan or Theme.amber

  love.graphics.setColor(0, 0, 0, 0.72)
  love.graphics.rectangle("fill", 0, 0, w, h)
  local title = (FileBox.kind == "photo" and "PHOTO BOX" or "FILE BOX") .. "  //  "
    .. (FileBox.kind == "photo" and "PICTURES AND VIDEOS" or "ANY FILE")
  UI.panel(r.box.x, r.box.y, r.box.w, r.box.h, title, accent)

  -- The folder, shortened from the left: the end of a path is the part
  -- that says where you are.
  local chars = math.floor(r.path.w / 8)
  local shown = Font.upper(tostring(FileBox.dir or ""))
  local wide = Font.len(shown)
  if wide > chars then shown = "..." .. Font.drop(shown, wide - chars + 3) end
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", r.path.x, r.path.y, r.path.w, r.path.h)
  Font.print(shown, r.path.x + 2, r.path.y + 1, Theme.ice, 1)

  drawPlaces(r.places)
  drawList(r.list)
  drawPreview(r.preview)

  -- The footer: what will be filed, and the three buttons.
  local f = r.footer
  local picks = FileBox.picks()
  -- The button says which of the two it is about to do, because "add" over
  -- a folder of two hundred should never be a surprise.
  local label = "ADD"
  if #picks > 0 then
    label = (FileBox.takingAll() and #picks > 1) and string.format("ADD ALL %d", #picks)
      or string.format("ADD %d", #picks)
  end
  local x = f.x
  local function btn(id, text, color, action, opts)
    local bw = #text * 8 + 10
    if UI.button("fb-" .. id, x, f.y, bw, f.h, text, { stroke = color, hot = color, scale = 1, on = opts and opts.on, onColor = color }) then
      action()
    end
    x = x + bw + 4
  end
  btn("add", label, Theme.jade, FileBox.commit, { on = #picks > 0 })
  btn("up", "UP", Theme.gold, function() FileBox.enter(FileBox.parent(FileBox.dir)) end)
  btn("cancel", "CANCEL", Theme.crimson, function() FileBox.close({}) end)
  local hint = "ADD TAKES THE FOLDER  RETURN TAKES ONE  SPACE PICKS  BKSP UP  ESC CANCEL"
  local room = math.floor((f.x + f.w - x) / 8)
  if room > 10 then Font.print(hint:sub(1, room), x + 2, f.y + 3, Theme.dim, 1) end

  FileBox.drawScan(r.box)
end

return FileBox
