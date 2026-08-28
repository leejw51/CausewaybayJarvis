--- Where everything goes, for either way up.
---
--- The client draws on a canvas of whatever size `best_fit` divides the window
--- into — 720x405 on a 1440x810 one, or the same turned on its side. Every rectangle in the chat scene used to be a constant at the top of
--- the file; this module *is* those constants, computed from the canvas size,
--- so turning the canvas is one call rather than a hunt through the scene.
---
--- Pure arithmetic, no `love.*` anywhere, so the numbers can be checked
--- without a graphics context.
---
--- The two orientations are not a transform of one another. Landscape is two
--- columns — the knight standing beside what he said. Portrait is two bands,
--- him above it, because a column 130 pixels wide cannot hold a transcript and
--- a knight side by side. What is shared is the chrome: the status bar at the
--- top and the input at the bottom, in the same place either way.

local M = {}

--- Every rectangle the chat scene draws, from one canvas size.
---
--- `prefer` overrides which arrangement is used: "portrait" stacks the bands
--- and "landscape" sets the columns, whatever shape the canvas is. Without it
--- the canvas decides, which is what a first run wants.
---
--- It also decides how big the letters are. The font is one face at
--- whole-number scales, and the scale is picked from the width the transcript
--- is about to get, so that it holds roughly fifty to seventy characters
--- however large the canvas is. A 1080x1920 display gives a 540x960 canvas: at
--- one scale that is eighty-seven characters across, which is not a column of
--- prose, it is a spreadsheet.
---
--- The divisor is the knob. Raising it holds one scale over a wider canvas,
--- which means more columns of smaller letters; lowering it steps up sooner.
--- It goes with `FIT` in `main`: that decides how big the canvas is, this
--- decides how big the letters on it are, and moving one without the other
--- just cancels it out.
function M.compute(width, height, prefer, force_scale)
  local portrait = height > width
  if prefer == "portrait" then portrait = true
  elseif prefer == "landscape" then portrait = false end

  local log_w = portrait and (width - 4) or math.floor(width * 0.58)
  local ts = force_scale or math.max(1, math.min(3, math.floor(log_w / 340 + 0.7)))
  ts = math.max(1, math.min(3, ts))

  local L = {
    portrait = portrait,
    width = width,
    height = height,
    text_scale = ts,
    cell = 6 * ts,
    line = 9 * ts,
  }

  local glyph = 8 * ts            -- how tall a letter is at this size
  local margin = 2
  local bar_h = glyph + 10        -- one line of text, and room for a button
  -- The input is a *titled* panel, and a titled panel spends its first line on
  -- the title: it needs room for two. Sized as one line, the prompt was drawn
  -- below the bottom edge, which at three times the font is most of a panel
  -- hanging over the keyboard hints.
  local input_h = glyph * 2 + 10
  local hint_h = glyph + 3
  local input_y = height - hint_h - input_h - 1

  L.bar = { x = 0, y = 0, w = width, h = bar_h }
  -- The two window buttons live in the bar, at the right end of it, where
  -- they are visible on every screen rather than tucked under the keyboard
  -- hints at the bottom of one of them.
  L.button_h = bar_h - 6

  L.input = { x = margin, y = input_y, w = width - margin * 2, h = input_h }
  L.hints = { x = margin + 2, y = input_y + input_h + 1,
              w = width - margin * 2 - 2, h = hint_h }

  local top = bar_h + 2
  -- Four pixels above the input rather than two: the input box now wears a
  -- button on its top rail, and a button lights a two-pixel halo when the
  -- pointer is on it. At a two-pixel gap that halo was drawn through the
  -- bottom course of the transcript panel.
  local body_h = input_y - top - 4

  if portrait then
    -- Two bands. The knight gets the top third: enough for a figure and a
    -- ring of eight sockets, and no more, because everything below it is the
    -- conversation and that is what the screen is for.
    local stage_h = math.floor(body_h * 0.34)
    L.stage = { x = margin, y = top, w = width - margin * 2, h = stage_h }
    L.log = { x = margin, y = top + stage_h + 4, w = width - margin * 2,
              h = body_h - stage_h - 4 }
  else
    -- Two columns. The transcript takes the wider one: it is the thing being
    -- read, and forty-odd characters is the least that reads as prose -- so
    -- at a big font the knight gives up some of his column to it.
    local stage_w = math.floor(width * (ts >= 2 and 0.30 or 0.38))
    L.stage = { x = margin, y = top, w = stage_w, h = body_h }
    L.log = { x = margin + stage_w + 4, y = top,
              w = width - stage_w - 4 - margin * 2, h = body_h }
  end

  -- The knight stands in the middle of the stage, a little above centre in
  -- the tall layout so the thought window can sit under his feet.
  L.avatar = {
    x = L.stage.x + math.floor(L.stage.w / 2),
    y = L.stage.y + math.floor(L.stage.h * (portrait and 0.46 or 0.41)),
  }
  -- The ring has to clear the figure (about 34 wide, 60 tall) and stay inside
  -- the stage, so it is whatever the smaller of those two allows.
  L.ring = math.max(40, math.min(64,
    math.floor(L.stage.w / 2) - 12,
    math.floor(L.stage.h * (portrait and 0.42 or 0.30))))

  -- The tool buttons -- EXPORT and COPY on the transcript, PASTE on the input
  -- box -- are cut into the top rail of their panel, beside the title, and
  -- these are the rows they sit in. They go in the masonry rather than in a
  -- row of their own because neither panel has a row to spare: the transcript
  -- is the thing being read, and the input is one line of prose above the key
  -- strip. A rail is a little taller than the letters in it, the same way the
  -- title is, so a button reads as part of the border rather than as something
  -- resting on it.
  L.rail_h = glyph + 2
  L.log_rail = { x = L.log.x, y = L.log.y - 1, w = L.log.w, h = L.rail_h }
  L.input_rail = { x = L.input.x, y = L.input.y - 1, w = L.input.w, h = L.rail_h }
  -- What a rail button leaves the title. Measured here rather than in the
  -- scene so that the one number deciding whether a title is drawn at all
  -- lives with the rectangles it is decided against.
  L.rail_inset = 6
  L.rail_gap = 3

  -- The thought window: the bottom of the stage, either way up.
  local think_h = math.min(12 + 6 * L.line, math.floor(L.stage.h * 0.40))
  L.think = {
    x = L.stage.x + 4,
    y = L.stage.y + L.stage.h - think_h,
    w = L.stage.w - 8,
    h = think_h,
  }

  return L
end

--- How many characters of the bitmap font fit across a panel's interior.
--- `cell` is `text.CELL_W`; passed in so this file needs no requires.
function M.columns(panel, cell, padding)
  return math.floor((panel.w - (padding or 12)) / cell)
end

return M
