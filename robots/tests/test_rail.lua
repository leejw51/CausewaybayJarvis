-- Clicking the rail at the bottom of the dashboard.
--
-- PAGE, FACE and the brain switch are the three ways into the robot system
-- from the map, and they are the only buttons in the client whose effect is
-- to change screen. Nothing else tests them, so a click that stopped
-- working would look exactly like a client that had nothing behind it.
local Dash = require("src.dashboard")
local Layout = require("src.layout")
local Input = require("src.input")
local Robots = require("src.robots")
local UI = require("src.ui")
local Backend = require("src.backend")

return function(F)
  F.describe("dashboard / the rail at the bottom")

  -- One click, at a point on screen, driven through the two frames a click
  -- actually takes: press on one, release on the next.
  local function clickAt(vx, vy)
    local was = love.mouse.getPosition
    love.mouse.getPosition = function()
      return vx * Layout.scale + Layout.ox, vy * Layout.scale + Layout.oy
    end
    Dash.request = nil
    local ok, err = pcall(function()
      Input.begin()
      Input.mousepressed()
      UI.begin(); Dash.draw(); UI.endFrame()
      Input.begin()
      Input.mousereleased()
      UI.begin(); Dash.draw(); UI.endFrame()
      Input.begin()
    end)
    love.mouse.getPosition = was
    if not ok then error(err, 0) end
    return Dash.request
  end

  F.it("reports where its buttons are", function()
    local rects = Dash.railRects(Layout.vw)
    F.ok(rects.page ~= nil, "no PAGE button")
    for name, b in pairs(rects) do
      if type(b) == "table" then
        F.ok(b.x >= 0 and b.x + b.w <= Layout.vw + 0.01, name .. " is off screen: " .. b.x)
        F.ok(b.y >= 0 and b.y + b.h <= Layout.vh + 0.01, name .. " is off screen vertically")
      end
    end
  end)

  -- The shape the operator actually reported the problem in. The rail is
  -- laid out from the canvas width, and a portrait canvas is 360 wide
  -- where landscape is 640 — so a rail that fits one may not fit the
  -- other, and a button pushed past the edge is a button that cannot be
  -- clicked however correct the click handling is.
  F.it("fits, and answers a click, in portrait as well", function()
    local mode, vw, vh = Layout.mode, Layout.vw, Layout.vh
    Layout.mode = "portrait"
    Layout.vw, Layout.vh = 360, 640
    local ok, err = pcall(function()
      local rects = Dash.railRects(Layout.vw)
      for name, b in pairs(rects) do
        if type(b) == "table" then
          F.ok(b.x + b.w <= Layout.vw + 0.01,
            name .. " runs off a portrait canvas: " .. (b.x + b.w) .. " > " .. Layout.vw)
        end
      end
      F.eq(clickAt(rects.page.x + rects.page.w / 2, rects.page.y + 6), "page")
      F.eq(clickAt(rects.provider.x + rects.provider.w / 2, rects.provider.y + 6), "provider")
    end)
    Layout.mode, Layout.vw, Layout.vh = mode, vw, vh
    if not ok then error(err, 0) end
  end)

  F.it("PAGE opens the robot page", function()
    local r = Dash.railRects(Layout.vw).page
    F.eq(clickAt(r.x + r.w / 2, r.y + r.h / 2), "page")
  end)

  F.it("the brain switch switches the brain", function()
    local r = Dash.railRects(Layout.vw).provider
    F.eq(clickAt(r.x + r.w / 2, r.y + r.h / 2), "provider")
  end)

  -- FACE is always on the rail, chosen robot or not, because F4 always
  -- opens a face. A key that works beside a button that is not there is
  -- the shape of "the buttons at the bottom do nothing".
  F.it("FACE is always there, and opens the face", function()
    local rects = Dash.railRects(Layout.vw)
    F.ok(rects.face ~= nil, "no FACE button")
    F.eq(clickAt(rects.face.x + rects.face.w / 2, rects.face.y + rects.face.h / 2), "face")
  end)

  -- The rail is laid out left to right and the brain switch is last, so it
  -- is the one that gets pushed off a narrow canvas — and a button off the
  -- canvas is a button no click can reach.
  F.it("keeps the brain switch on screen even when the label is long", function()
    local mode, vw = Layout.mode, Layout.vw
    local was = Backend.provider
    Layout.mode, Layout.vw = "portrait", 360
    local ok, err = pcall(function()
      for _, p in ipairs({
        { current = "auto", effective = "ondevice" },
        { current = "cloud", effective = "offline" },
        { current = "ondevice", effective = "ondevice" },
      }) do
        Backend.provider = p
        local r = Dash.railRects(Layout.vw)
        F.ok(r.provider.x + r.provider.w <= Layout.vw + 0.01,
          "the brain switch ran off the rail: " .. (r.provider.x + r.provider.w))
        F.ok(r.provider.w >= 24, "the brain switch was squeezed to nothing")
      end
    end)
    Layout.mode, Layout.vw, Backend.provider = mode, vw, was
    if not ok then error(err, 0) end
  end)

  F.it("a click just above the rail is not one of its buttons", function()
    local r = Dash.railRects(Layout.vw).page
    F.eq(clickAt(r.x + r.w / 2, r.y - 6), nil)
  end)
end
