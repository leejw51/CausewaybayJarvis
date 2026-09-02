-- Orientation and window mode survive a restart via display.jsonl.
local Store = require("src.store")
local Json = require("src.json")
local Layout = require("src.layout")

return function(t)
  t.describe("layout persistence")

  local scratch = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/jarvis2-layout-test"

  local function fresh()
    Store.use(scratch)
    Store.remove(Layout.LOG)
    Layout.mode = "landscape"
    Layout.fullscreen = true
    Layout.compact = false
  end

  t.it("appends one json line per toggle", function()
    fresh()
    Layout.toggleOrientation()
    Layout.toggleFullscreen()
    local lines = Store.lines(Layout.LOG)
    t.eq(#lines, 2)
    local first = Json.decode(lines[1])
    t.eq(first.mode, "portrait")
    t.eq(first.fullscreen, true)
    t.eq(first.compact, false)
    local second = Json.decode(lines[2])
    t.eq(second.mode, "portrait")
    t.eq(second.fullscreen, false)
    t.eq(second.compact, false)
    t.ok(second.at and #second.at > 0, "each record is stamped")
  end)

  t.it("restores the last record on load", function()
    fresh()
    Layout.toggleOrientation()
    Layout.toggleFullscreen()
    Layout.mode = "landscape"
    Layout.fullscreen = true
    Layout.compact = true
    t.eq(Layout.load(), true)
    t.eq(Layout.mode, "portrait")
    t.eq(Layout.fullscreen, false)
    t.eq(Layout.compact, false)
  end)

  t.it("keeps the defaults when nothing was ever saved", function()
    fresh()
    t.eq(Layout.load(), false)
    t.eq(Layout.mode, "landscape")
    t.eq(Layout.fullscreen, true)
    t.eq(Layout.compact, false)
  end)

  t.describe("layout / how much of the window gets used")

  -- 640x360 landscape, on a tall screen. The old arithmetic handed back
  -- the base size and letterboxed the rest away.
  t.it("stretches into a window the layout was not shaped for", function()
    local scale, vw, vh = Layout.viewport(1080, 1920, 640, 360, false)
    t.eq(vw, 640, "the constrained axis is unchanged")
    t.ok(vh > 360, "the long axis should be used, not blacked out: " .. vh)
    -- Never more than the cap: a layout stretched without limit is a
    -- layout with its furniture in the wrong places.
    t.ok(vh <= math.floor(360 * 1.6), "stretched past the cap: " .. vh)
    t.ok(vh * scale <= 1920, "drew past the bottom of the window")
  end)

  t.it("never goes below the size the screens are designed for", function()
    -- A window smaller than the base: the canvas scales down to fit rather
    -- than the layout being asked to lay itself out in less room than it
    -- has. More than the base is fine and expected — the guarantee is a
    -- floor, not an equality.
    local scale, vw, vh = Layout.viewport(320, 200, 640, 360, false)
    t.ok(vw >= 640, "narrower than the design: " .. vw)
    t.ok(vh >= 360, "shorter than the design: " .. vh)
    t.ok(vw * scale <= 320 + 1, "drew past the right edge")
    t.ok(vh * scale <= 200 + 1, "drew past the bottom edge")
  end)

  t.it("fills exactly when the window is a whole multiple", function()
    local scale, vw, vh = Layout.viewport(1080, 1920, 360, 640, false)
    t.eq(scale, 3)
    t.eq(vw, 360)
    t.eq(vh, 640)
  end)

  t.it("takes the orientation from the window when nothing was saved", function()
    t.eq(Layout.orientationFor(1080, 1920), "portrait")
    t.eq(Layout.orientationFor(1920, 1080), "landscape")
    t.eq(Layout.orientationFor(1000, 1000), "landscape", "square is not tall")
  end)

  t.it("persists compact hud mode", function()
    fresh()
    Layout.toggleCompact()
    t.eq(Layout.compact, true)
    local rec = Json.decode(Store.lines(Layout.LOG)[1])
    t.eq(rec.compact, true)
    Layout.compact = false
    t.eq(Layout.load(), true)
    t.eq(Layout.compact, true)
  end)

  t.it("skips a truncated tail line and uses the last good one", function()
    fresh()
    Store.write(Layout.LOG, '{"mode":"portrait","fullscreen":false}\n{"mode":"land\n')
    Layout.mode = "landscape"
    Layout.fullscreen = true
    t.eq(Layout.load(), true)
    t.eq(Layout.mode, "portrait")
    t.eq(Layout.fullscreen, false)
  end)

  t.it("ignores a record with an unknown mode", function()
    fresh()
    Store.write(Layout.LOG, '{"mode":"diagonal"}\n')
    t.eq(Layout.load(), false)
    t.eq(Layout.mode, "landscape")
  end)

  t.it("trims the log so it cannot grow without bound", function()
    fresh()
    local seed = {}
    for _ = 1, 205 do seed[#seed + 1] = '{"mode":"landscape","fullscreen":true}' end
    Store.write(Layout.LOG, table.concat(seed, "\n") .. "\n")
    Layout.toggleOrientation()
    local lines = Store.lines(Layout.LOG)
    t.ok(#lines <= 40, "trimmed down, got " .. #lines)
    t.eq(Json.decode(lines[#lines]).mode, "portrait", "the newest record survives")
  end)

  t.describe("fullscreen mode")

  t.it("defaults to the borderless mode macOS screen capture can see", function()
    Layout.fullscreenPref = nil
    t.eq(Layout.fullscreenType(), "desktop")
  end)

  t.it("honours an explicit exclusive preference", function()
    Layout.fullscreenPref = "exclusive"
    t.eq(Layout.fullscreenType(), "exclusive")
    Layout.fullscreenPref = nil
  end)

  t.it("falls back to desktop for an unknown preference", function()
    Layout.fullscreenPref = "borderless"
    t.eq(Layout.fullscreenType(), "desktop")
    Layout.fullscreenPref = nil
  end)

  t.describe("layout persistence")

  t.it("restores the real store for the suites that follow", function()
    Store.remove(Layout.LOG)
    Store.use(nil)
    Layout.mode = "landscape"
    Layout.fullscreen = true
    Layout.compact = false
  end)
end
