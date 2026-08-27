--- The settings page.
---
--- One overlay, shared by the boot screen and the chat, because a machine
--- should be adjustable from wherever you are standing when you notice it is
--- wrong. Every row is a label and a row of chips; the chip that is already
--- true is lit, and clicking another one switches to it.
---
--- Everything it changes goes through the same paths the keys use — the font
--- through `app.set_text_size`, the window through `app.ask_window`, the
--- palette through `palette.use` — so there is one implementation of each and
--- the page is only a way of reaching them.

local app = require("src.app")
local ui = require("src.ui")
local text = require("src.text")
local palette = require("src.palette")
local shaders = require("src.shaders")
local art = require("src.art")
local sfx = require("src.sfx")
local ease = require("src.ease")

local M = { open = false, t = 0, confirm = 0 }

local function human_bytes(n)
  n = tonumber(n) or 0
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local unit = 1
  while n >= 1024 and unit < #units do
    n = n / 1024
    unit = unit + 1
  end
  if unit <= 2 then return string.format("%d %s", n, units[unit]) end
  return string.format("%.1f %s", n, units[unit])
end

--- Where the weights are, in as many lines as it takes.
---
--- The whole path is sixty-four characters and the panel holds about thirty,
--- so on one line it can only be cut — and cut either way it throws away the
--- half you wanted, the front saying which cache and the end saying which
--- model. Two lines say both: the repository, then the directory it sits in.
--- Only when it fits whole is it shown whole.
local function weights_lines(where, columns)
  columns = math.max(8, columns)
  local home = os.getenv("HOME")
  local path = tostring(where.path or "--")
  if home and path:sub(1, #home) == home then path = "~" .. path:sub(#home + 1) end
  if #path <= columns then return { path } end

  local root = path:match("^(.*)/[^/]*$") or path
  local repo = tostring(where.repo or path:match("([^/]*)$") or path)

  local out = {}
  if #repo <= columns then
    out[#out + 1] = repo
  else
    -- The organisation and the model on a line each. Clipping the repository
    -- takes the end off the model name, which is the one part of the whole
    -- string nobody can guess.
    local org, name = repo:match("^(.-)/(.*)$")
    if org and #name <= columns then
      out[#out + 1] = org .. "/"
      out[#out + 1] = name
    else
      out[#out + 1] = text.clip(repo, columns)
    end
  end
  out[#out + 1] = text.clip(root .. "/", columns)
  return out
end

function M.show()
  M.open = true
  M.t = 0
  M.confirm = 0
  app.modal = true
  app.measure_weights()
  sfx.play("open")
end

function M.hide()
  M.open = false
  app.modal = false
  sfx.play("page")
end

function M.toggle()
  if M.open then M.hide() else M.show() end
end

function M.update(dt)
  if not M.open then return end
  M.t = math.min(1, M.t + dt * 4)
  M.confirm = math.max(0, M.confirm - dt)
end

--- The rows, built fresh each frame so every chip reflects the truth.
local function rows()
  local out = {}

  out[#out + 1] = { label = "FONT", chips = {
    { text = "1", on = app.text_pref == 1, act = function() app.set_text_size(1) end },
    { text = "2", on = app.text_pref == 2, act = function() app.set_text_size(2) end },
    { text = "3", on = app.text_pref == 3, act = function() app.set_text_size(3) end },
    { text = "AUTO", on = app.text_pref == nil, act = function() app.set_text_size(nil) end },
  } }

  out[#out + 1] = { label = "LAYOUT", chips = {
    { text = "ACROSS", on = not app.window.portrait, act = function()
        app.window.portrait = false app.ask_window({ portrait = false }) end },
    { text = "DOWN", on = app.window.portrait, act = function()
        app.window.portrait = true app.ask_window({ portrait = true }) end },
  } }

  out[#out + 1] = { label = "SCREEN", chips = {
    { text = "WINDOW", on = not app.window.fullscreen, act = function()
        app.window.fullscreen = false app.ask_window({ fullscreen = false }) end },
    { text = "FULL", on = app.window.fullscreen, act = function()
        app.window.fullscreen = true app.ask_window({ fullscreen = true }) end },
  } }

  local chips = {}
  for _, name in ipairs(palette.order) do
    chips[#chips + 1] = {
      text = palette.sets[name].label,
      on = palette.name == name,
      act = function()
        palette.use(name)
        shaders.send_palette()
        art.rebake()
      end,
    }
  end
  out[#out + 1] = { label = "COLOUR", chips = chips }

  return out
end

--- Draw it, collecting hotspots into `into`.
function M.draw(into)
  if not M.open then return end
  local eased = ease.outBack(M.t)
  local c, lh = app.L.cell, text.height()
  local row_h = lh + 8

  palette.set("black", 0.72 * math.min(M.t * 2, 1))
  love.graphics.rectangle("fill", 0, 0, app.W, app.H)

  local list = rows()
  local pw = math.min(math.max(40 * c, 250), app.W - 12)

  -- The path decides how tall the page is, so it is measured before the panel
  -- that holds it.
  local where = app.weights or {}
  local columns = math.floor((pw - 12) / c)
  local lines = weights_lines(where, columns)

  -- Sized to its rows, then clamped: everything below the divider is drawn
  -- from the panel's own height so a short screen loses the closing hint
  -- rather than printing it past the frame.
  local needed = lh + 3 + #list * row_h + lh * (4 + #lines) + 20
  local ph = math.min(needed, app.H - 16)
  local tight = needed > ph
  local h = math.floor(ph * eased)
  local x, y, w = ui.panel(math.floor((app.W - pw) / 2), math.floor((app.H - h) / 2), pw, h,
    { title = "SETTINGS", slot = "cyan", glow = "cyan" })
  if h < 50 then return end

  local label_w = 7 * c
  for i, row in ipairs(list) do
    local ry = y + (i - 1) * row_h
    text.print(row.label, x + 2, ry, "gray")
    local cx = x + 2 + label_w
    for _, chip in ipairs(row.chips) do
      local cw = ui.button_width(chip.text)
      if cx + cw <= x + w - 2 then
        local hot = app.mouse.x >= cx and app.mouse.x < cx + cw
          and app.mouse.y >= ry - 2 and app.mouse.y < ry - 2 + lh + 4
        local rect = ui.button(cx, ry - 2, cw, lh + 4, chip.text,
          { slot = chip.on and "cyan" or "gray", hot = hot or chip.on })
        into[#into + 1] = { rect = rect, action = function() chip.act() sfx.play("select") end }
      end
      cx = cx + cw + 3
    end
  end

  -- ------------------------------------------------------------ the weights
  local wy = y + #list * row_h + (tight and 0 or 4)
  ui.divider(x + 2, wy, w - 4, "gray")
  wy = wy + 4

  text.print("WEIGHTS", x + 2, wy, "gray")
  text.right(where.bytes and human_bytes(where.bytes) or (app.demo and "-- (demo)" or "measuring"),
    x + w - 2, wy, "yellow")
  for i, line in ipairs(lines) do
    text.print(line, x + 2, wy + lh * i, "cyan", 0.85)
  end

  -- Erasing is two clicks: the second one inside three seconds.
  local ey = wy + lh * (#lines + 1) + 2
  local label = app.clearing and "ERASING..."
    or app.cleared and "ERASED - RESTART TO FETCH"
    or M.confirm > 0 and "PRESS AGAIN TO ERASE"
    or "ERASE THE WEIGHTS"
  local bw = math.min(ui.button_width(label), w - 4)
  local bx = x + math.floor((w - bw) / 2)
  local hot = app.mouse.x >= bx and app.mouse.x < bx + bw
    and app.mouse.y >= ey and app.mouse.y < ey + lh + 4
  local rect = ui.button(bx, ey, bw, lh + 4, text.clip(label, math.floor(bw / c)),
    { slot = M.confirm > 0 and "red" or "maroon", hot = hot })
  if not app.clearing and not app.cleared then
    into[#into + 1] = { rect = rect, action = function()
      if M.confirm > 0 then
        M.confirm = 0
        app.clear_weights()
        sfx.play("damage")
      else
        M.confirm = 3
        sfx.play("deny")
      end
    end }
  end

  if not tight then
    text.center(text.clip("F12 or ESC closes this", math.floor(w / c)),
      x, w, ey + lh + 6, "gray")
  end
end

function M.click(hotspots, x, y)
  if not M.open then return false end
  for _, spot in ipairs(hotspots or {}) do
    if ui.inside(spot.rect, x, y) then spot.action() return true end
  end
  -- A click anywhere else on a modal page closes it.
  M.hide()
  return true
end

function M.keypressed(key)
  if not M.open then return false end
  if key == "escape" or key == "f12" or key == "return" then M.hide() end
  return true
end

return M
