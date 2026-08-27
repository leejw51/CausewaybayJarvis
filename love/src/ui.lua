--- Panels, frames and gauges, in the furniture of a tile-mapped RPG.
---
--- Everything is a stone window: a two-pixel masonry border with the courses
--- picked out in two greys, a stud in each corner, a dark fill and a title cut
--- into the top rail. Ultima drew its windows like this because a border of
--- repeating tiles cost one tile; here it costs one loop, and it is still the
--- fastest way to say "this is a thing you may read".

local palette = require("src.palette")
local text = require("src.text")

local M = {}

--- The masonry: alternating courses along each rail so the border reads as
--- blocks rather than as a line.
local function courses(x, y, w, h, light, dark)
  -- The dark course first, unbroken, then the light blocks over it: without
  -- the base the alternation reads as a dashed line rather than as stone.
  palette.set(dark)
  love.graphics.rectangle("fill", x, y, w, 2)
  love.graphics.rectangle("fill", x, y + h - 2, w, 2)
  love.graphics.rectangle("fill", x, y, 2, h)
  love.graphics.rectangle("fill", x + w - 2, y, 2, h)

  local block = 6
  for i = 0, math.ceil(w / block) - 1 do
    palette.set(i % 2 == 0 and light or dark)
    local bw = math.min(block, w - i * block)
    love.graphics.rectangle("fill", x + i * block, y, bw, 2)
    palette.set(i % 2 == 1 and light or dark)
    love.graphics.rectangle("fill", x + i * block, y + h - 2, bw, 2)
  end
  for i = 0, math.ceil(h / block) - 1 do
    palette.set(i % 2 == 1 and light or dark)
    local bh = math.min(block, h - i * block)
    love.graphics.rectangle("fill", x, y + i * block, 2, bh)
    palette.set(i % 2 == 0 and light or dark)
    love.graphics.rectangle("fill", x + w - 2, y + i * block, 2, bh)
  end
end

--- A stone window. Returns the inner rectangle, which is where the caller
--- should draw: `local ix, iy, iw, ih = ui.panel(...)`.
---
--- `options`: `title`, `title_slot`, `slot` and `dark` for the two border
--- greys, `fill` for the interior alpha, `glow` to put a halo on it,
--- `corner` for the stud colour.
---
--- `rail` keeps the title's row clear without drawing a title, for a panel
--- whose top rail carries buttons instead. Without it, a panel that lost its
--- title to a narrow screen handed back an interior starting a whole line
--- higher, and the first two rows of the transcript were drawn underneath the
--- buttons standing in the rail above them.
function M.panel(x, y, w, h, options)
  options = options or {}
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  if w < 8 or h < 8 then return x, y, 0, 0 end

  local light = options.slot or "silver"
  local dark = options.dark or "gray"

  if options.glow then
    palette.set(options.glow, 0.18)
    love.graphics.rectangle("fill", x - 2, y - 2, w + 4, h + 4)
  end

  palette.set("black", options.fill or 0.80)
  love.graphics.rectangle("fill", x, y, w, h)

  courses(x, y, w, h, light, dark)

  -- Studs, one per corner, inside the course.
  palette.set(options.corner or "white")
  for _, corner in ipairs({ { x + 2, y + 2 }, { x + w - 4, y + 2 },
                            { x + 2, y + h - 4 }, { x + w - 4, y + h - 4 } }) do
    love.graphics.rectangle("fill", corner[1], corner[2], 2, 2)
  end

  -- A hairline inside the masonry, so the fill has an edge to stop against.
  palette.set("black")
  love.graphics.rectangle("line", x + 2.5, y + 2.5, w - 5, h - 5)

  if options.title then
    local label = " " .. options.title .. " "
    local tw = text.width(label)
    local tx = x + (options.title_x or 6)
    palette.set("black", 1)
    love.graphics.rectangle("fill", tx, y - 1, tw, text.height() + 1)
    palette.set(options.slot or "silver")
    -- Under the label, not through it: this was a hard 8, and at twice the
    -- font size it ruled a line across the middle of the word.
    love.graphics.rectangle("fill", tx, y + text.height(), tw, 1)
    text.print(label, tx, y, options.title_slot or "gold")
  end

  local top = (options.title or options.rail) and (text.height() + 3) or 4
  return x + 4, y + top, w - 8, h - top - 4
end

--- A flat panel, for the boot screen: one colour, one pixel, no masonry. This
--- is what the machine draws before the cartridge takes over.
function M.flat(x, y, w, h, slot, fill)
  palette.set("black", fill or 1)
  love.graphics.rectangle("fill", x, y, w, h)
  palette.set(slot or "silver")
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
  return x + 3, y + 3, w - 6, h - 6
end

--- A segmented gauge. Segments rather than a smooth bar: a bar of pixels
--- crossing a dither pattern flickers, and a bar of blocks never does.
function M.gauge(x, y, w, h, fraction, options)
  options = options or {}
  fraction = math.max(0, math.min(1, fraction or 0))
  local segment = options.segment or 3
  local gap = options.gap or 1
  local count = math.floor((w + gap) / (segment + gap))
  local lit = math.floor(count * fraction + 0.5)

  palette.set(options.back or "gray", options.back_alpha or 0.5)
  love.graphics.rectangle("fill", x, y, w, h)

  for i = 0, count - 1 do
    local slot
    if i < lit then
      slot = options.slot or "lime"
      if options.ramp then slot = palette.ramp(options.ramp, i / math.max(count - 1, 1)) end
    else
      slot = options.empty or "black"
    end
    palette.set(slot, i < lit and 1 or 0.6)
    love.graphics.rectangle("fill", x + i * (segment + gap), y, segment, h)
  end
  return count
end

--- A small labelled chip -- the things along the status bar.
function M.chip(x, y, label, slot, options)
  options = options or {}
  local w = text.width(label) + 6
  palette.set(options.back or "black", options.alpha or 0.7)
  love.graphics.rectangle("fill", x, y, w, 11)
  palette.set(slot or "silver", options.border_alpha or 0.9)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, 10)
  text.print(label, x + 3, y + 2, slot or "silver")
  return x + w + (options.gap_after or 3)
end

--- A small pressable chip.
---
--- Immediate mode: it draws itself and hands back the rectangle it drew in,
--- which the scene keeps until a click arrives. `hot` is whether the pointer
--- is over it, which the scene works out from the same rectangle it kept last
--- frame -- so a button that has just moved is right one frame later, and
--- nothing here has to own any state.
function M.button(x, y, w, h, label, options)
  options = options or {}
  x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
  local slot = options.slot or "silver"
  local hot = options.hot

  -- A glow behind it while the pointer is on it.
  if hot then
    palette.set(slot, 0.16)
    love.graphics.rectangle("fill", x - 2, y - 2, w + 4, h + 4)
  end

  palette.set(hot and slot or "black", hot and 0.30 or 0.78)
  love.graphics.rectangle("fill", x, y, w, h)
  -- One pixel of bevel: the top edge lights up with hover, the bottom stays
  -- dark. At this size that is all a bevel needs to be.
  palette.set(hot and "white" or slot, hot and 0.9 or 0.5)
  love.graphics.rectangle("fill", x, y, w, 1)
  palette.set("black", 0.6)
  love.graphics.rectangle("fill", x, y + h - 1, w, 1)
  palette.set(hot and "white" or slot, hot and 1 or 0.8)
  love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)

  text.center(label, x, w, y + math.floor((h - text.height()) / 2),
    hot and "white" or slot)
  return { x = x, y = y, w = w, h = h }
end

--- How wide that chip needs to be for a label.
function M.button_width(label) return text.width(label) + 10 end

--- Is a point inside a rectangle the button handed back?
function M.inside(rect, x, y)
  return rect and x >= rect.x and x < rect.x + rect.w
     and y >= rect.y and y < rect.y + rect.h
end

--- A rule with a diamond in the middle, for splitting a panel.
function M.divider(x, y, w, slot)
  palette.set(slot or "gray", 0.8)
  love.graphics.rectangle("fill", x, y, w, 1)
  palette.set(slot or "gray")
  love.graphics.rectangle("fill", x + w / 2 - 2, y - 1, 4, 3)
  palette.set("black")
  love.graphics.rectangle("fill", x + w / 2 - 1, y, 2, 1)
end

--- A ring of dashes, drawn in whole pixels: the rune circle under the core,
--- and the halo a module gets while its hook is firing.
function M.ring(cx, cy, radius, count, phase, slot, alpha, size, squash)
  size = size or 1
  squash = squash or 1
  for i = 0, count - 1 do
    local angle = phase + i / count * math.pi * 2
    palette.set(slot, alpha)
    love.graphics.rectangle("fill",
      math.floor(cx + math.cos(angle) * radius),
      math.floor(cy + math.sin(angle) * radius * squash), size, size)
  end
end

--- A beam of dots between two points -- how an equipped module stays attached
--- to the core.
function M.beam(x1, y1, x2, y2, slot, alpha, spacing, offset)
  spacing = spacing or 3
  local dx, dy = x2 - x1, y2 - y1
  local length = math.sqrt(dx * dx + dy * dy)
  local steps = math.floor(length / spacing)
  if steps < 1 then return end
  palette.set(slot, alpha)
  for i = 0, steps do
    local t = (i + (offset or 0)) % (steps + 1) / steps
    love.graphics.rectangle("fill",
      math.floor(x1 + dx * t), math.floor(y1 + dy * t), 1, 1)
  end
end

--- Solid text on a solid strip: the one-line banner the boot screen and the
--- toast messages use.
function M.banner(y, label, slot, alpha, width)
  width = width or 480
  palette.set("black", alpha or 0.85)
  love.graphics.rectangle("fill", 0, y, width, 11)
  palette.set(slot or "gold", 0.9)
  love.graphics.rectangle("fill", 0, y, width, 1)
  love.graphics.rectangle("fill", 0, y + 10, width, 1)
  text.center(label, 0, width, y + 2, slot or "gold")
end

return M
