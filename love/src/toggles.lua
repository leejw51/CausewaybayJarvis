--- The two window buttons, drawn the same way wherever they appear.
---
--- Each says what the client *is* rather than what the button does — `ACROSS`
--- when the layout is horizontal, `WINDOW` when it is not fullscreen — because
--- a row of two buttons that name their opposite is a row you have to think
--- about. Clicking one switches it.
---
--- The change itself goes through `app.ask_window`, which hands it to `main`
--- to perform between frames: these are drawn inside a canvas pass, and
--- changing the window mode in the middle of one tears the render target out
--- from under everything that has not been drawn yet.

local app = require("src.app")
local ui = require("src.ui")
local sfx = require("src.sfx")

local M = {}

M.HEIGHT = 13

local function toggle(field, label_on, label_off, slot)
  return {
    label = app.window[field] and label_on or label_off,
    slot = slot,
    action = function()
      local wanted = not app.window[field]
      app.window[field] = wanted          -- so the label is right immediately
      app.ask_window({ [field] = wanted })
      sfx.play("select")
    end,
  }
end

--- Draw both, right-aligned so they end at `right`. Hotspots are appended to
--- `into`, which the scene checks when a click arrives. Returns the x it
--- reached, so whatever shares the row can be clipped to it.
function M.draw(right, y, into, height)
  local h = height or app.L.button_h or M.HEIGHT
  for _, item in ipairs({
    toggle("fullscreen", "FULL", "WINDOW", "cyan"),
    toggle("portrait", "DOWN", "ACROSS", "magenta"),
  }) do
    local w = ui.button_width(item.label)
    right = right - w
    local hot = app.mouse.x >= right and app.mouse.x < right + w
            and app.mouse.y >= y and app.mouse.y < y + h
    local rect = ui.button(right, y, w, h, item.label, { slot = item.slot, hot = hot })
    into[#into + 1] = { rect = rect, action = item.action }
    right = right - 3
  end
  return right
end

--- Walk the hotspots a scene collected and fire the first one hit.
function M.click(hotspots, x, y)
  for _, spot in ipairs(hotspots or {}) do
    if ui.inside(spot.rect, x, y) then
      spot.action()
      return true
    end
  end
  return false
end

return M
