--- Drawing with the bitmap font.
---
--- One texture atlas, one quad per glyph, nearest filtering, integer
--- positions. Everything else in the client draws through here, which is why
--- there is markup: `{gold}` inside a string switches colour until `{}` closes
--- it, so a status line can be one string instead of nine draw calls with
--- widths measured by hand.
---
---     text.print("{gold}JARVIS{} online", 4, 4)
---     text.print("MEM", x, y, "silver", 0.5)
---     text.icon("cart", x, y, "yellow")
---
--- `text.wrap` breaks a paragraph to a column count; the chat log keeps its
--- lines pre-wrapped so that scrolling costs nothing.

local font = require("src.pixelfont")
local palette = require("src.palette")
local utf8 = require("utf8")

local M = {
  CELL_W = font.CELL_W,
  CELL_H = font.CELL_H,
  LINE = font.LINE,
  -- One face at whole-number scales. Scaling a bitmap font by two or three
  -- with a nearest filter keeps every edge exactly on a pixel; a second,
  -- larger raster would not match it. `main` sets this from the canvas size,
  -- so a big screen gets big letters rather than more of them.
  scale = 1,
}

--- The size of a character cell at the current scale. Everything that
--- measures, wraps or steps a line uses these rather than the constants.
function M.cell() return font.CELL_W * M.scale end
function M.line() return font.LINE * M.scale end
function M.height() return font.CELL_H * M.scale end

--- Draw something at a fixed size, whatever the interface is using. Labels
--- painted *on* an object — the letters on the cartridge, the game's own logo
--- — belong to the object and must not grow with the rest of the chrome.
function M.at(scale, fn)
  local previous = M.scale
  M.scale = scale
  local ok, err = pcall(fn)
  M.scale = previous
  if not ok then error(err, 0) end
end

--- Set the scale, in whole numbers. Returns true if it changed.
function M.set_scale(n)
  n = math.max(1, math.min(4, math.floor(n or 1)))
  if n == M.scale then return false end
  M.scale = n
  return true
end

local atlas, quads
local FIRST, LAST = 32, 126
local COLS = 16

--- Build the atlas: printable ASCII first, in code order, then the icons.
function M.load()
  local slots = (LAST - FIRST + 1)
  local names = {}
  for name in pairs(font.icons) do names[#names + 1] = name end
  table.sort(names)

  local total = slots + #names
  local rows = math.ceil(total / COLS)
  local data = love.image.newImageData(COLS * font.CELL_W, rows * font.CELL_H)

  quads = {}
  local index = 0
  local function place(key, pattern)
    local cx, cy = (index % COLS) * font.CELL_W, math.floor(index / COLS) * font.CELL_H
    for y, row in ipairs(font.rows(pattern)) do
      for x = 1, #row do
        if row:sub(x, x) == "#" then data:setPixel(cx + x - 1, cy + y - 1, 1, 1, 1, 1) end
      end
    end
    quads[key] = love.graphics.newQuad(cx, cy, font.CELL_W, font.CELL_H,
      data:getWidth(), data:getHeight())
    index = index + 1
  end

  for code = FIRST, LAST do
    local char = string.char(code)
    place(char, font.glyphs[char] or font.glyphs["?"])
  end
  for _, name in ipairs(names) do place("@" .. name, font.icons[name]) end

  atlas = love.graphics.newImage(data)
  atlas:setFilter("nearest", "nearest")
  return M
end

-- ---------------------------------------------------------------- ASCII ---

-- A 6x8 font of ninety-five glyphs has no room for the rest of Unicode, and a
-- model writing about Prague produces plenty of it -- em dashes, curly
-- quotes, and the hacek on every other Czech consonant. Rather than draw a
-- question mark per *byte*, which is what iterating the string would do,
-- codepoints are folded to the nearest ASCII the font does have.
local FOLD = {
  [0x00A0] = " ", [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-",
  [0x2014] = "--", [0x2015] = "--", [0x2212] = "-", [0x00AD] = "",
  [0x2018] = "'", [0x2019] = "'", [0x201A] = ",", [0x201B] = "'",
  [0x201C] = '"', [0x201D] = '"', [0x201E] = '"', [0x00AB] = '"', [0x00BB] = '"',
  [0x2026] = "...", [0x2022] = "-", [0x00B7] = "-", [0x2027] = "-",
  [0x00D7] = "x", [0x00F7] = "/", [0x00B0] = " deg", [0x2032] = "'", [0x2033] = '"',
  [0x2190] = "<-", [0x2192] = "->", [0x2191] = "^", [0x2193] = "v", [0x21D2] = "=>",
  [0x2264] = "<=", [0x2265] = ">=", [0x2260] = "/=", [0x00A9] = "(C)", [0x00AE] = "(R)",
  [0x2122] = "(TM)", [0x20AC] = "EUR", [0x00A3] = "GBP", [0x00A5] = "JPY",
  [0x00BD] = "1/2", [0x00BC] = "1/4", [0x00BE] = "3/4", [0x2044] = "/",
  [0x0161] = "s", [0x0160] = "S", [0x010D] = "c", [0x010C] = "C",
  [0x0159] = "r", [0x0158] = "R", [0x017E] = "z", [0x017D] = "Z",
  [0x011B] = "e", [0x011A] = "E", [0x0148] = "n", [0x0147] = "N",
  [0x0165] = "t", [0x0164] = "T", [0x010F] = "d", [0x010E] = "D",
  [0x016F] = "u", [0x016E] = "U", [0x0142] = "l", [0x0141] = "L",
  [0x00DF] = "ss", [0x00E6] = "ae", [0x00C6] = "AE", [0x00F8] = "o", [0x00D8] = "O",
}

-- The accented Latin-1 block folds by table: a run of codepoints per letter.
local RUNS = {
  { 0x00C0, 0x00C5, "A" }, { 0x00C8, 0x00CB, "E" }, { 0x00CC, 0x00CF, "I" },
  { 0x00D2, 0x00D6, "O" }, { 0x00D9, 0x00DC, "U" }, { 0x00E0, 0x00E5, "a" },
  { 0x00E8, 0x00EB, "e" }, { 0x00EC, 0x00EF, "i" }, { 0x00F2, 0x00F6, "o" },
  { 0x00F9, 0x00FC, "u" }, { 0x00C7, 0x00C7, "C" }, { 0x00E7, 0x00E7, "c" },
  { 0x00D1, 0x00D1, "N" }, { 0x00F1, 0x00F1, "n" }, { 0x00DD, 0x00DD, "Y" },
  { 0x00FD, 0x00FD, "y" }, { 0x00FF, 0x00FF, "y" },
  { 0x0100, 0x0105, "a" }, { 0x0106, 0x010B, "c" }, { 0x0112, 0x0119, "e" },
  { 0x011C, 0x0123, "g" }, { 0x0124, 0x0127, "h" }, { 0x0128, 0x0131, "i" },
  { 0x0143, 0x0146, "n" }, { 0x014C, 0x0151, "o" }, { 0x015A, 0x015F, "s" },
  { 0x0168, 0x0173, "u" }, { 0x0179, 0x017C, "z" },
}

local function fold(code)
  local direct = FOLD[code]
  if direct then return direct end
  for _, run in ipairs(RUNS) do
    if code >= run[1] and code <= run[2] then return run[3] end
  end
  return "?"
end

--- Fold a string to what this font can draw. Bytes below 128 pass straight
--- through, so ASCII costs one `find` and nothing else.
function M.ascii(s)
  s = tostring(s)
  if not s:find("[\128-\255]") then return s end
  local out, i = {}, 1
  while i <= #s do
    local byte = s:byte(i)
    if byte < 0x80 then
      out[#out + 1] = s:sub(i, i)
      i = i + 1
    else
      local width = byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
      local ok, code = pcall(utf8.codepoint, s, i)
      out[#out + 1] = ok and fold(code) or "?"
      i = i + width
    end
  end
  return table.concat(out)
end

-- ------------------------------------------------------------- measuring ---

--- Strip the markup, so that widths are measured in glyphs actually drawn.
function M.plain(s)
  return (tostring(s):gsub("{[%a]*}", ""))
end

function M.width(s) return #M.plain(s) * M.cell() end
function M.cols(s) return #M.plain(s) end

--- Break a paragraph at `columns`, on spaces where there are any and mid-word
--- where a word is longer than the line -- a URL must not push the panel out.
function M.wrap(s, columns)
  local lines = {}
  for paragraph in (tostring(s) .. "\n"):gmatch("([^\n]*)\n") do
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        while #word > columns do
          if #line > 0 then lines[#lines + 1] = line line = "" end
          lines[#lines + 1] = word:sub(1, columns)
          word = word:sub(columns + 1)
        end
        if line == "" then
          line = word
        elseif #line + 1 + #word <= columns then
          line = line .. " " .. word
        else
          lines[#lines + 1] = line
          line = word
        end
      end
      lines[#lines + 1] = line
    end
  end
  return lines
end

-- -------------------------------------------------------------- printing ---

local function glyph(char)
  return quads[char] or quads["?"]
end

--- Draw one string. `slot` is the palette role it starts in; `{name}` inside
--- the string switches, `{}` returns to the start colour. `wobble(i)` may
--- return a vertical offset per character, which is how speech shakes.
---
--- Returns the x it stopped at, so runs can be chained.
function M.print(s, x, y, slot, alpha, wobble)
  s = tostring(s)
  local base = slot or "white"
  local current = base
  local i, col = 1, 0
  x, y = math.floor(x), math.floor(y)

  while i <= #s do
    local tag, after = s:match("^{(%a*)}()", i)
    if tag then
      current = (tag == "" and base) or (palette.c(tag) and tag) or current
      i = after
    else
      local char = s:sub(i, i)
      local q = glyph(char)
      if q and char ~= " " then
        palette.set(current, alpha)
        local dy = wobble and wobble(col + 1) or 0
        love.graphics.draw(atlas, q, x + col * M.cell(), y + math.floor(dy),
          0, M.scale, M.scale)
      end
      col = col + 1
      i = i + 1
    end
  end
  return x + col * M.cell()
end

--- The same, with a hard one-pixel shadow underneath. Text sits on painted
--- backgrounds here, and an unshadowed glyph over a candle flame is a glyph
--- nobody can read.
function M.shadow(s, x, y, slot, alpha, wobble)
  M.print((tostring(s):gsub("{%a*}", "")), x + 1, y + 1, "black", (alpha or 1) * 0.7, wobble)
  return M.print(s, x, y, slot, alpha, wobble)
end

function M.icon(name, x, y, slot, alpha, scale)
  local q = quads["@" .. name]
  if not q then return end
  scale = scale or M.scale
  palette.set(slot or "white", alpha)
  love.graphics.draw(atlas, q, math.floor(x), math.floor(y), 0, scale, scale)
end

--- Centre a string inside a width.
function M.center(s, x, width, y, slot, alpha, wobble)
  return M.print(s, x + math.floor((width - M.width(s)) / 2), y, slot, alpha, wobble)
end

function M.right(s, x, y, slot, alpha)
  local left = x - M.width(s)
  M.print(s, left, y, slot, alpha)
  return left
end

--- Cut a string to `columns`, ellipsising with a single character the way a
--- machine with one font weight had to.
function M.clip(s, columns)
  local plain = M.plain(s)
  if #plain <= columns then return s end
  return plain:sub(1, math.max(0, columns - 1)) .. "~"
end

function M.image() return atlas end

return M
