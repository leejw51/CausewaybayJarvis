local Theme = require("src.theme")
local Font = require("src.font")
local Layout = require("src.layout")
local Input = require("src.input")
local Audio = require("src.audio")

local UI = {}
local hot, active

function UI.begin()
  hot = nil
end

function UI.endFrame()
  if not Input.down then active = nil end
end

function UI.isHot()
  return hot ~= nil
end

function UI.hotId()
  return hot
end

function UI.rect(x, y, w, h, fill, stroke)
  if fill then
    love.graphics.setColor(fill)
    love.graphics.rectangle("fill", x, y, w, h)
  end
  if stroke then
    love.graphics.setColor(stroke)
    love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
  end
end

function UI.panel(x, y, w, h, title, accent)
  accent = accent or Theme.gold
  love.graphics.setColor(Theme.panel)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(Theme.withAlpha(accent, 0.9))
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
  love.graphics.setColor(Theme.withAlpha(accent, 0.25))
  love.graphics.rectangle("line", x + 2.5, y + 2.5, w - 5, h - 5)
  -- corner ticks
  love.graphics.setColor(accent)
  local t = 5
  love.graphics.rectangle("fill", x, y, t, 1)
  love.graphics.rectangle("fill", x, y, 1, t)
  love.graphics.rectangle("fill", x + w - t, y, t, 1)
  love.graphics.rectangle("fill", x + w - 1, y, 1, t)
  love.graphics.rectangle("fill", x, y + h - 1, t, 1)
  love.graphics.rectangle("fill", x, y + h - t, 1, t)
  love.graphics.rectangle("fill", x + w - t, y + h - 1, t, 1)
  love.graphics.rectangle("fill", x + w - 1, y + h - t, 1, t)
  love.graphics.setColor(Theme.withAlpha(Theme.paper, 0.08))
  love.graphics.rectangle("fill", x + 3, y + 3, w - 6, 1)
  if title and #title > 0 then
    love.graphics.setColor(Theme.navy)
    love.graphics.rectangle("fill", x + 6, y - 1, #title * 8 + 6, 9)
    Font.print(title, x + 8, y, accent, 1)
  end
end

function UI.led(x, y, on, color)
  color = color or Theme.jade
  love.graphics.setColor(on and color or Theme.dim)
  love.graphics.rectangle("fill", x, y, 4, 4)
  if on then
    love.graphics.setColor(Theme.withAlpha(color, 0.25))
    love.graphics.rectangle("fill", x - 1, y - 1, 6, 6)
  end
end

function UI.bar(x, y, w, h, t, color)
  t = math.max(0, math.min(1, t))
  love.graphics.setColor(Theme.navy)
  love.graphics.rectangle("fill", x, y, w, h)
  love.graphics.setColor(color or Theme.cyan)
  local fw = math.floor((w - 2) * t)
  if fw > 0 then love.graphics.rectangle("fill", x + 1, y + 1, fw, h - 2) end
  love.graphics.setColor(Theme.dim)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
end

function UI.button(id, x, y, w, h, label, opts)
  opts = opts or {}
  local hover = Layout.hit(x, y, w, h)
  if hover then hot = id end
  if hover and Input.pressed then active = id end
  local pressed = active == id and hover
  local clicked = Input.released and active == id and hover
  if clicked and not opts.silent then Audio.play("click") end

  local fill = opts.fill or Theme.panel2
  local stroke = opts.stroke or Theme.gold
  if hover then stroke = opts.hot or Theme.cyan end
  if pressed then fill = Theme.navy end
  if opts.on then stroke = opts.onColor or Theme.jade end

  local oy = pressed and 1 or 0
  love.graphics.setColor(fill)
  love.graphics.rectangle("fill", x, y + oy, w, h)
  love.graphics.setColor(stroke)
  love.graphics.rectangle("line", x + 0.5, y + oy + 0.5, w - 1, h - 1)
  if hover then
    love.graphics.setColor(Theme.withAlpha(stroke, 0.18))
    love.graphics.rectangle("fill", x, y + oy, w, h)
  end
  if not pressed then
    love.graphics.setColor(Theme.withAlpha(Theme.paper, 0.14))
    love.graphics.rectangle("fill", x + 1, y + 1, w - 2, 1)
    love.graphics.setColor(stroke)
    love.graphics.rectangle("fill", x, y + oy, 2, 1)
  end
  local scale = opts.scale or 1
  local tw = #label * 8 * scale
  local tx = x + math.floor((w - tw) / 2)
  local ty = y + oy + math.floor((h - 8 * scale) / 2)
  Font.print(label, tx, ty, opts.labelColor or Theme.paper, scale)
  return clicked
end

function UI.chip(id, x, y, label, on)
  local w = #label * 8 + 10
  local h = 12
  if UI.button(id, x, y, w, h, label, {on = on, stroke = Theme.magenta, hot = Theme.teal}) then
    return true, w
  end
  return false, w
end

function UI.hex(cx, cy, r, color, fill, rot)
  rot = rot or (math.pi / 6)
  local pts = {}
  for i = 0, 5 do
    local a = rot + i * math.pi / 3
    pts[#pts + 1] = cx + math.cos(a) * r
    pts[#pts + 1] = cy + math.sin(a) * r
  end
  love.graphics.setColor(color)
  if fill then love.graphics.polygon("fill", pts) else love.graphics.polygon("line", pts) end
end

function UI.rings(cx, cy, r, t, color, accent)
  UI.hex(cx, cy, r, Theme.withAlpha(color, 0.7), false, t * 0.35)
  UI.hex(cx, cy, r * 0.78, Theme.withAlpha(accent, 0.5), false, -t * 0.55)
  UI.hex(cx, cy, r * 0.58, Theme.withAlpha(color, 0.28), false, t * 0.9)
end

function UI.radar(cx, cy, r, t, color)
  local ang = t * 1.8
	love.graphics.setColor(Theme.withAlpha(color, 0.22))
  love.graphics.circle("line", cx, cy, r)
  love.graphics.circle("line", cx, cy, r * 0.66)
  love.graphics.circle("line", cx, cy, r * 0.33)
  love.graphics.setColor(Theme.withAlpha(color, 0.7))
  love.graphics.line(cx, cy, cx + math.cos(ang) * r, cy + math.sin(ang) * r)
  love.graphics.setColor(Theme.withAlpha(color, 0.08))
  love.graphics.arc("fill", cx, cy, r, ang - 0.55, ang)
end

return UI
