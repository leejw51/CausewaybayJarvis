-- The file box LOVE draws itself: the listing, the geometry, the picks.
-- No folder is opened here except a scratch one this suite makes.

local FileBox = require("src.filebox")
local Picker = require("src.picker")

return function(F)
  F.describe("filebox / the listing")

  F.it("reads ls -1pA: folders first, dotfiles skipped, sorted without case", function()
    local out = "zeta.PNG\n.DS_Store\nnotes/\nApple.jpg\nBeta/\nreadme.txt\n"
    local all = FileBox.parseListing(out, "/x/", "file")
    F.eq(#all, 5)
    F.eq(all[1].name, "Beta")
    F.eq(all[1].dir, true)
    F.eq(all[1].path, "/x/Beta")
    F.eq(all[2].name, "notes")
    F.eq(all[3].name, "Apple.jpg")
    F.eq(all[4].name, "readme.txt")
    F.eq(all[5].name, "zeta.PNG")
    F.eq(all[5].dir, false)
  end)

  F.it("a photo box keeps folders, pictures and videos, and drops the rest", function()
    local out = "a.txt\nb.jpg\nc.MOV\nd/\ne.pdf\nf.webp\n"
    local photo = FileBox.parseListing(out, "/x", "photo")
    local names = {}
    for i, e in ipairs(photo) do names[i] = e.name end
    F.eq(table.concat(names, ","), "d,b.jpg,c.MOV,f.webp")
    F.eq(FileBox.wanted("holiday.mp4", "photo"), true)
    F.eq(FileBox.wanted("holiday.mp4", "file"), true)
    F.eq(FileBox.wanted("notes.md", "photo"), false)
    F.eq(FileBox.ext("IMG.JPEG"), "jpeg")
    F.eq(FileBox.ext("noext"), "")
  end)

  F.it("the parent of a folder, up to the root and no further", function()
    F.eq(FileBox.parent("/Users/x/Pictures"), "/Users/x")
    F.eq(FileBox.parent("/Users/x/Pictures/"), "/Users/x")
    F.eq(FileBox.parent("/Users"), "/")
    F.eq(FileBox.parent("/"), "/")
  end)

  F.describe("filebox / geometry")

  F.it("every pane stays inside the canvas, and the preview goes on a narrow one", function()
    for _, s in ipairs({ { 640, 360 }, { 360, 640 }, { 1280, 720 } }) do
      local r = FileBox.rects(s[1], s[2])
      for name, box in pairs(r) do
        F.ok(box.x >= 0 and box.y >= 0, name .. " starts off screen")
        F.ok(box.x + box.w <= s[1] + 0.01, name .. " runs off the right")
        F.ok(box.y + box.h <= s[2] + 0.01, name .. " runs off the bottom")
      end
      F.ok(r.list.w > 100, "the list is too narrow at " .. s[1])
      if s[1] >= 480 then F.ok(r.preview.w > 0, "no preview at " .. s[1]) else F.eq(r.preview.w, 0) end
      F.ok(r.footer.y > r.list.y + r.list.h, "the footer overlaps the list")
    end
    F.eq(FileBox.window(5, 3, 10), 1)
    F.eq(FileBox.window(100, 100, 10), 91)
  end)

  F.describe("filebox / picks")

  F.it("with nothing picked, ADD takes every file in the folder", function()
    -- Folders come first, so: [1] sub, [2] a.png, [3] b.png.
    FileBox.entries = FileBox.parseListing("a.png\nb.png\nsub/\n", "/x", "photo")
    FileBox.picked, FileBox.pickedList = {}, {}
    FileBox.cursor = 2
    F.eq(FileBox.takingAll(), true)
    local files, dirs = FileBox.split()
    F.eq(#files, 2, "the whole folder, not the one under the cursor")
    F.eq(files[1], "/x/a.png")
    F.eq(files[2], "/x/b.png")
    F.eq(#dirs, 0, "a subfolder is not walked unless it was picked")
    -- Where the cursor sits makes no difference to it.
    FileBox.cursor = 1
    F.eq(#(FileBox.split()), 2, "the cursor on a folder changes nothing")
    -- One file in the folder is still just that file.
    FileBox.entries = FileBox.parseListing("only.png\nsub/\n", "/x", "photo")
    F.eq(#FileBox.picks(), 1)
    FileBox.entries, FileBox.cursor = {}, 1
  end)

  F.it("a hand-made pick wins over the folder, and folders in it are walked", function()
    FileBox.entries = FileBox.parseListing("a.png\nb.png\nsub/\n", "/x", "photo")
    FileBox.picked, FileBox.pickedList = {}, {}
    FileBox.toggle(FileBox.entries[1])   -- the folder
    FileBox.toggle(FileBox.entries[2])   -- a.png
    F.eq(FileBox.takingAll(), false)
    F.eq(#FileBox.picks(), 2, "a folder can be picked")
    local files, dirs = FileBox.split()
    F.eq(#files, 1, "b.png was not picked and must not come along")
    F.eq(files[1], "/x/a.png")
    F.eq(#dirs, 1)
    F.eq(dirs[1], "/x/sub")
    FileBox.toggle(FileBox.entries[1])
    FileBox.toggle(FileBox.entries[2])
    F.eq(FileBox.takingAll(), true, "unpicking everything gives the folder back")
    FileBox.entries, FileBox.cursor = {}, 1
    FileBox.picked, FileBox.pickedList = {}, {}
  end)

  F.it("return on a file takes that one file, whatever ADD would take", function()
    FileBox.entries = FileBox.parseListing("a.png\nb.png\nc.png\n", "/x", "photo")
    FileBox.picked, FileBox.pickedList = {}, {}
    FileBox.cursor = 2
    F.eq(#FileBox.picks(), 3, "ADD would take all three")
    local got
    FileBox.open, FileBox.cb = true, function(paths) got = paths end
    FileBox.activate()
    F.eq(FileBox.open, false)
    F.eq(#got, 1, "return must file exactly what the cursor is on")
    F.eq(got[1], "/x/b.png")
    FileBox.entries, FileBox.cursor = {}, 1
  end)

  F.describe("filebox / walking a picked folder")

  -- A tree on no disk: `FileBox.list` is the only door to one, so stubbing it
  -- is enough to walk a made-up folder a frame at a time.
  local TREE = {
    ["/t"]            = { { name = "one.png", path = "/t/one.png" },
                          { name = "sub", path = "/t/sub", dir = true },
                          { name = "deep", path = "/t/deep", dir = true } },
    ["/t/sub"]        = { { name = "two.png", path = "/t/sub/two.png" } },
    ["/t/deep"]       = { { name = "under", path = "/t/deep/under", dir = true } },
    ["/t/deep/under"] = { { name = "three.png", path = "/t/deep/under/three.png" },
                          { name = "one.png", path = "/t/one.png" } },
  }

  local function withTree(fn)
    local real = FileBox.list
    FileBox.list = function(dir) return TREE[dir] or {} end
    local ok, err = pcall(fn)
    FileBox.list = real
    if not ok then error(err, 0) end
  end

  F.it("reads every folder underneath, and files what it found", function()
    withTree(function()
      local got
      FileBox.open, FileBox.cb = true, function(paths) got = paths end
      FileBox.startScan({ "/t" }, { "/hand/picked.png" })
      F.ok(FileBox.scan ~= nil, "the walk did not start")
      F.eq(FileBox.scan.shown, 0, "the bar starts empty")
      local frames = 0
      while FileBox.scan and frames < 400 do
        FileBox.scanStep(1 / 60)
        frames = frames + 1
      end
      F.eq(FileBox.scan, nil, "the walk never finished")
      F.ok(frames > 1, "the bar was never seen: the walk closed on one frame")
      F.eq(got[1], "/hand/picked.png", "what was picked by hand comes first")
      table.sort(got)
      F.eq(table.concat(got, ","),
        "/hand/picked.png,/t/deep/under/three.png,/t/one.png,/t/sub/two.png",
        "a file seen twice must be filed once")
      FileBox.open = false
    end)
  end)

  F.it("the bar eases toward the reading rather than jumping to it", function()
    withTree(function()
      FileBox.open, FileBox.cb = true, function() end
      FileBox.startScan({ "/t" }, {})
      local seen, last = {}, 0
      for _ = 1, 400 do
        if not FileBox.scan then break end
        FileBox.scanStep(1 / 60)
        if FileBox.scan then
          local now = FileBox.scan.shown
          F.ok(now >= last - 0.001, "the bar went backwards: " .. now)
          F.ok(now >= 0 and now <= 1, "the bar left the rail: " .. now)
          last = now
          seen[#seen + 1] = now
        end
      end
      F.ok(#seen > 4, "the bar had too few readings to be an animation")
      -- An ease, not a jump: the first frame is nowhere near the end even
      -- though the walk itself was over almost at once.
      F.ok(seen[1] < 0.5, "the bar jumped straight to the end")
      FileBox.open = false
    end)
  end)

  F.it("escape stops the walk and leaves the box up", function()
    withTree(function()
      local got
      FileBox.open, FileBox.cb = true, function(paths) got = paths end
      FileBox.startScan({ "/t" }, {})
      FileBox.scanStep(1 / 60)
      FileBox.cancelScan()
      F.eq(FileBox.scan, nil)
      F.eq(FileBox.open, true, "cancelling the walk must not close the box")
      F.eq(got, nil, "nothing was filed")
      FileBox.open, FileBox.cb = false, nil
    end)
  end)

  F.it("a walk from a folder full of folders stops at the cap", function()
    local real, wide = FileBox.list, FileBox.SCAN_MAX_DIRS
    FileBox.SCAN_MAX_DIRS = 40
    -- Every folder holds two more, for ever.
    FileBox.list = function(dir)
      return { { name = "a", path = dir .. "/a", dir = true },
               { name = "b", path = dir .. "/b", dir = true } }
    end
    FileBox.open, FileBox.cb = true, function() end
    FileBox.startScan({ "/endless" }, {})
    local frames = 0
    while FileBox.scan and frames < 600 do
      FileBox.scanStep(1 / 60)
      frames = frames + 1
    end
    FileBox.list, FileBox.SCAN_MAX_DIRS = real, wide
    FileBox.open = false
    F.eq(FileBox.scan, nil, "an endless tree was walked for ever")
  end)

  F.describe("filebox / picks")

  F.it("opens through the picker, on a real folder, and answers when closed", function()
    local wasNative = Picker.native
    Picker.native = false
    Picker.busy = false
    local got
    F.eq(Picker.open("photo", function(paths) got = paths end), true)
    F.eq(FileBox.open, true)
    F.eq(Picker.busy, true)
    F.eq(FileBox.kind, "photo")
    F.ok(FileBox.isDir(FileBox.dir), "the box did not open on a folder: " .. tostring(FileBox.dir))
    FileBox.close({ "/x/a.png" })
    F.eq(FileBox.open, false)
    F.eq(Picker.busy, false)
    F.eq(got[1], "/x/a.png")
    Picker.native = wasNative
  end)
end
