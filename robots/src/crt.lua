local Theme = require("src.theme")
local Layout = require("src.layout")

local CRT = { t = 0 }

function CRT.update(dt)
  CRT.t = CRT.t + dt
end

function CRT.draw()
  local w, h = Layout.vw, Layout.vh
  love.graphics.setColor(0, 0, 0, 0.18)
  for y = 0, h - 1, 2 do
    love.graphics.rectangle("fill", 0, y, w, 1)
  end
  local ry = math.floor((CRT.t * 42) % (h + 12)) - 6
  love.graphics.setColor(Theme.withAlpha(Theme.cyan, 0.045))
  love.graphics.rectangle("fill", 0, ry, w, 8)
  -- occasional phosphor pop
  if math.floor(CRT.t * 9) % 47 == 0 then
    love.graphics.setColor(1, 1, 1, 0.04)
    love.graphics.rectangle("fill", 0, 0, w, h)
  end
  love.graphics.setColor(0, 0, 0, 0.38)
  love.graphics.rectangle("fill", 0, 0, w, 5)
  love.graphics.rectangle("fill", 0, h - 5, w, 5)
  love.graphics.rectangle("fill", 0, 0, 5, h)
  love.graphics.rectangle("fill", w - 5, 0, 5, h)
  love.graphics.setColor(Theme.withAlpha(Theme.teal, 0.03))
  love.graphics.rectangle("fill", 0, 0, w, h)
end

return CRT
