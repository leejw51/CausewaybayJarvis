-- 8x8 pixel font (Apple II / MSX vibe). Lowercase maps to uppercase.
local Font = {}

local GLYPHS = {
  [" "] = {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},
  ["!"] = {0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00},
  ["\""]= {0x66,0x66,0x24,0x00,0x00,0x00,0x00,0x00},
  ["#"] = {0x24,0x7E,0x24,0x24,0x7E,0x24,0x24,0x00},
  ["$"] = {0x18,0x3E,0x58,0x3C,0x1A,0x7C,0x18,0x00},
  ["%"] = {0x62,0x64,0x08,0x10,0x20,0x4C,0x8C,0x00},
  ["&"] = {0x30,0x48,0x50,0x20,0x54,0x48,0x34,0x00},
  ["'"] = {0x18,0x18,0x10,0x00,0x00,0x00,0x00,0x00},
  ["("] = {0x08,0x10,0x20,0x20,0x20,0x10,0x08,0x00},
  [")"] = {0x20,0x10,0x08,0x08,0x08,0x10,0x20,0x00},
  ["*"] = {0x00,0x24,0x18,0x7E,0x18,0x24,0x00,0x00},
  ["+"] = {0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00},
  [","] = {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30},
  ["-"] = {0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00},
  ["."] = {0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00},
  ["/"] = {0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x00},
  ["0"] = {0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00},
  ["1"] = {0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00},
  ["2"] = {0x3C,0x66,0x06,0x0C,0x18,0x30,0x7E,0x00},
  ["3"] = {0x3C,0x66,0x06,0x1C,0x06,0x66,0x3C,0x00},
  ["4"] = {0x0C,0x1C,0x2C,0x4C,0x7E,0x0C,0x0C,0x00},
  ["5"] = {0x7E,0x60,0x7C,0x06,0x06,0x66,0x3C,0x00},
  ["6"] = {0x1C,0x30,0x60,0x7C,0x66,0x66,0x3C,0x00},
  ["7"] = {0x7E,0x06,0x0C,0x18,0x18,0x18,0x18,0x00},
  ["8"] = {0x3C,0x66,0x66,0x3C,0x66,0x66,0x3C,0x00},
  ["9"] = {0x3C,0x66,0x66,0x3E,0x06,0x0C,0x38,0x00},
  [":"] = {0x00,0x18,0x18,0x00,0x18,0x18,0x00,0x00},
  [";"] = {0x00,0x18,0x18,0x00,0x18,0x18,0x30,0x00},
  ["<"] = {0x08,0x10,0x20,0x40,0x20,0x10,0x08,0x00},
  ["="] = {0x00,0x00,0x7E,0x00,0x7E,0x00,0x00,0x00},
  [">"] = {0x20,0x10,0x08,0x04,0x08,0x10,0x20,0x00},
  ["?"] = {0x3C,0x66,0x06,0x0C,0x18,0x00,0x18,0x00},
  ["@"] = {0x3C,0x4A,0x56,0x5E,0x40,0x3C,0x00,0x00},
  ["A"] = {0x18,0x3C,0x66,0x66,0x7E,0x66,0x66,0x00},
  ["B"] = {0x7C,0x66,0x66,0x7C,0x66,0x66,0x7C,0x00},
  ["C"] = {0x3C,0x66,0x60,0x60,0x60,0x66,0x3C,0x00},
  ["D"] = {0x78,0x6C,0x66,0x66,0x66,0x6C,0x78,0x00},
  ["E"] = {0x7E,0x60,0x60,0x7C,0x60,0x60,0x7E,0x00},
  ["F"] = {0x7E,0x60,0x60,0x7C,0x60,0x60,0x60,0x00},
  ["G"] = {0x3C,0x66,0x60,0x6E,0x66,0x66,0x3C,0x00},
  ["H"] = {0x66,0x66,0x66,0x7E,0x66,0x66,0x66,0x00},
  ["I"] = {0x7E,0x18,0x18,0x18,0x18,0x18,0x7E,0x00},
  ["J"] = {0x1E,0x0C,0x0C,0x0C,0x0C,0x6C,0x38,0x00},
  ["K"] = {0x66,0x6C,0x78,0x70,0x78,0x6C,0x66,0x00},
  ["L"] = {0x60,0x60,0x60,0x60,0x60,0x60,0x7E,0x00},
  ["M"] = {0x63,0x77,0x7F,0x6B,0x63,0x63,0x63,0x00},
  ["N"] = {0x66,0x76,0x7E,0x7E,0x6E,0x66,0x66,0x00},
  ["O"] = {0x3C,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},
  ["P"] = {0x7C,0x66,0x66,0x7C,0x60,0x60,0x60,0x00},
  ["Q"] = {0x3C,0x66,0x66,0x66,0x6A,0x64,0x3A,0x00},
  ["R"] = {0x7C,0x66,0x66,0x7C,0x78,0x6C,0x66,0x00},
  ["S"] = {0x3C,0x66,0x60,0x3C,0x06,0x66,0x3C,0x00},
  ["T"] = {0x7E,0x18,0x18,0x18,0x18,0x18,0x18,0x00},
  ["U"] = {0x66,0x66,0x66,0x66,0x66,0x66,0x3C,0x00},
  ["V"] = {0x66,0x66,0x66,0x66,0x66,0x3C,0x18,0x00},
  ["W"] = {0x63,0x63,0x63,0x6B,0x7F,0x77,0x63,0x00},
  ["X"] = {0x66,0x66,0x3C,0x18,0x3C,0x66,0x66,0x00},
  ["Y"] = {0x66,0x66,0x66,0x3C,0x18,0x18,0x18,0x00},
  ["Z"] = {0x7E,0x06,0x0C,0x18,0x30,0x60,0x7E,0x00},
  ["["] = {0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00},
  ["\\"]= {0x80,0x40,0x20,0x10,0x08,0x04,0x02,0x00},
  ["]"] = {0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00},
  ["^"] = {0x18,0x3C,0x66,0x00,0x00,0x00,0x00,0x00},
  ["_"] = {0x00,0x00,0x00,0x00,0x00,0x00,0x7E,0x00},
  ["`"] = {0x30,0x18,0x00,0x00,0x00,0x00,0x00,0x00},
  ["{"] = {0x0C,0x18,0x18,0x70,0x18,0x18,0x0C,0x00},
  ["|"] = {0x18,0x18,0x18,0x18,0x18,0x18,0x18,0x00},
  ["}"] = {0x30,0x18,0x18,0x0E,0x18,0x18,0x30,0x00},
  ["~"] = {0x00,0x32,0x4C,0x00,0x00,0x00,0x00,0x00},
}

local function glyph(ch)
  local u = ch:upper()
  return GLYPHS[u] or GLYPHS[ch] or GLYPHS["?"]
end

-- ------------------------------------------------------------------ utf-8 ---
--
-- The table above is ASCII and always will be: it is drawn by hand, eight
-- rows of bits to a letter. A name in Korean or Japanese is drawn instead by
-- a font already on the machine, squeezed into the same 8x8 cell, so the grid
-- never moves and every width measured below stays true. Nothing is bundled:
-- the bytes come in through plain `io` and are handed to LOVE as FileData,
-- the way `src/photos.lua` brings in a picture from outside the sandbox.
--
-- Everything here counts *characters*, not bytes. Walking bytes is what made
-- a Korean file name thirty question marks wide.

--- The codepoint at byte `i`, and how many bytes it took. A byte that is not
--- the start of a well-formed sequence is a character of its own, so a name
--- in some older encoding still draws rather than swallowing the line.
local function decode(s, i)
  local b = s:byte(i)
  if not b then return nil, 0 end
  if b < 0x80 then return b, 1 end
  local width = b < 0xC0 and 1 or b < 0xE0 and 2 or b < 0xF0 and 3 or 4
  if width == 1 or i + width - 1 > #s then return b, 1 end
  local cp = b % (2 ^ (7 - width))
  for k = 1, width - 1 do
    local c = s:byte(i + k)
    if not c or c < 0x80 or c > 0xBF then return b, 1 end
    cp = cp * 64 + (c - 0x80)
  end
  return cp, width
end

local function encode(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096),
                       0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + math.floor(cp / 262144),
                     0x80 + math.floor(cp / 4096) % 64,
                     0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local LBASE, VBASE, TBASE = 0x1100, 0x1161, 0x11A7
local SBASE, VCOUNT, TCOUNT = 0xAC00, 21, 28

--- Put decomposed Hangul back together. macOS keeps file names decomposed,
--- so `ls` hands back a syllable as the two or three jamo it is built from:
--- a four-letter word arrives as ten codepoints and draws as loose strokes
--- ten cells wide. Unicode lays the syllables out in one arithmetic block,
--- so this is a sum rather than a table. Pure, for the tests.
function Font.compose(s)
  s = tostring(s or "")
  -- U+1100..U+11FF is E1 84..87 xx: no lead jamo, nothing to put together.
  if not s:find("\225[\132-\135]") then return s end
  local out, i = {}, 1
  while i <= #s do
    local cp, w = decode(s, i)
    if not cp then break end
    i = i + w
    if cp >= LBASE and cp <= LBASE + 18 then
      local vcp, vw = decode(s, i)
      if vcp and vcp >= VBASE and vcp <= VBASE + VCOUNT - 1 then
        i = i + vw
        local index = ((cp - LBASE) * VCOUNT + (vcp - VBASE)) * TCOUNT
        local tcp, tw = decode(s, i)
        if tcp and tcp > TBASE and tcp <= TBASE + TCOUNT - 1 then
          i = i + tw
          index = index + (tcp - TBASE)
        end
        cp = SBASE + index
      end
    end
    out[#out + 1] = encode(cp)
  end
  return table.concat(out)
end

--- Every character of a string, composed, as byte slices.
function Font.chars(s)
  s = Font.compose(s)
  local out, i = {}, 1
  while i <= #s do
    local _, w = decode(s, i)
    if w == 0 then break end
    out[#out + 1] = s:sub(i, i + w - 1)
    i = i + w
  end
  return out
end

--- How many cells a string takes. ASCII costs one `find` and nothing else.
function Font.len(s)
  s = tostring(s or "")
  if not s:find("[\128-\255]") then return #s end
  return #Font.chars(s)
end

--- The first `n` characters, never half of one.
function Font.clip(s, n)
  s = tostring(s or "")
  if not s:find("[\128-\255]") then return s:sub(1, n) end
  local chars = Font.chars(s)
  if #chars <= n then return table.concat(chars) end
  return table.concat(chars, "", 1, math.max(0, n))
end

--- What is left after the first `n`.
function Font.drop(s, n)
  s = tostring(s or "")
  if not s:find("[\128-\255]") then return s:sub(n + 1) end
  local chars = Font.chars(s)
  if #chars <= n then return "" end
  return table.concat(chars, "", n + 1, #chars)
end

--- Raise the ASCII and leave the rest alone. `string.upper` walks bytes, and
--- a byte in the middle of a Korean syllable is not a letter to be raised.
function Font.upper(s)
  return (tostring(s or ""):gsub("[a-z]", string.upper))
end

-- ------------------------------------------------------- the other glyphs ---

-- The first face on this machine that opens wins. Korean first, because that
-- is what a Korean machine names its screenshots; the Japanese and Chinese
-- faces cover the rest of the block. A machine with none of them -- a Linux
-- runner -- draws the question mark it drew before.
local FALLBACK_FILES = {
  "/System/Library/Fonts/Supplemental/AppleGothic.ttf",
  "/System/Library/Fonts/Supplemental/AppleMyungjo.ttf",
  "/System/Library/Fonts/AppleSDGothicNeo.ttc",
  "/System/Library/Fonts/Hiragino Sans GB.ttc",
  "/System/Library/Fonts/Supplemental/NotoSansGothic-Regular.ttf",
  "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
  "/usr/share/fonts/truetype/nanum/NanumGothic.ttf",
  "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
}

local faceData, faceLooked = nil, false
local faces = {}

--- The font file, read once. Nil when this machine has none.
function Font.face()
  if faceLooked then return faceData end
  faceLooked = true
  if not (love and love.filesystem) then return nil end
  for _, path in ipairs(FALLBACK_FILES) do
    local file = io.open(path, "rb")
    if file then
      local bytes = file:read("*a")
      file:close()
      if bytes and #bytes > 0 then
        local ok, data = pcall(love.filesystem.newFileData, bytes, path:match("([^/]+)$"))
        if ok and data then
          faceData = data
          Font.facePath = path
          break
        end
      end
    end
  end
  return faceData
end

--- One face per pixel size, made once. `false` is cached too: a size that
--- failed must not be retried sixty times a second.
function Font.faceAt(px)
  px = math.max(6, math.floor(px))
  if faces[px] ~= nil then return faces[px] or nil end
  local data = Font.face()
  if not data or not (love and love.graphics) then
    faces[px] = false
    return nil
  end
  local ok, face = pcall(love.graphics.newFont, data, px)
  faces[px] = (ok and face) or false
  return faces[px] or nil
end

--- Draw one character with that face, fitted to exactly the 8x8 cell the
--- bitmap glyphs use, so nothing above has to know which half drew it.
--- False when there is no face and the question mark should stand in.
---
--- The fit is to the *ascent*, not the line height: a face asked for at
--- eight pixels reports a ten-pixel line, because the line carries a
--- descender almost no syllable uses, and fitting to that would leave the
--- Korean sitting small and pale beside the letters. Ascent is where the ink
--- stops, so the baseline lands on the bottom of the cell and the glyph
--- comes out at its natural size with nothing resampled.
local function drawFace(ch, x, y, scale)
  local cell = 8 * scale
  local face = Font.faceAt(cell)
  if not face then return false end
  local w = face:getWidth(ch)
  local rise = face:getAscent()
  if rise <= 0 then rise = face:getHeight() end
  if w <= 0 or rise <= 0 then return false end
  local previous = love.graphics.getFont()
  love.graphics.setFont(face)
  love.graphics.print(ch, x, y, 0, cell / w, cell / rise)
  if previous then love.graphics.setFont(previous) end
  return true
end

-- ----------------------------------------------------------------- drawing ---

local function drawBits(rows, px, py, scale)
  for row = 0, 7 do
    local bits = rows[row + 1]
    for col = 0, 7 do
      if math.floor(bits / (2 ^ (7 - col))) % 2 == 1 then
        love.graphics.rectangle("fill", px + col * scale, py + row * scale, scale, scale)
      end
    end
  end
end

function Font.measure(text, scale)
  scale = scale or 1
  return Font.len(text) * 8 * scale, 8 * scale
end

function Font.print(text, x, y, color, scale)
  scale = scale or 1
  if color then love.graphics.setColor(color) end
  text = tostring(text or "")
  local px, py = x, y
  -- ASCII, which is nearly everything drawn, walks the bytes as it always
  -- did: no table is built and no codepoint decoded.
  local plain = not text:find("[\128-\255]")
  local list = not plain and Font.chars(text) or nil
  for i = 1, plain and #text or #list do
    local ch = plain and text:sub(i, i) or list[i]
    if ch == "\n" then
      px = x
      py = py + 8 * scale
    else
      if #ch > 1 then
        if not drawFace(ch, px, py, scale) then drawBits(GLYPHS["?"], px, py, scale) end
      else
        drawBits(glyph(ch), px, py, scale)
      end
      px = px + 8 * scale
    end
  end
end

function Font.printf(text, x, y, w, color, scale)
  scale = scale or 1
  local maxChars = math.max(1, math.floor(w / (8 * scale)))
  local line, cx, cy = "", x, y
  local function put(s)
    Font.print(s, cx, cy, color, scale)
    cy = cy + 9 * scale
  end
  for word in (tostring(text) .. " "):gmatch("([^ ]*) ") do
    if word == "" then
      -- skip extra
    elseif line == "" then
      if Font.len(word) > maxChars then
        local rest = word
        while Font.len(rest) > 0 do
          put(Font.clip(rest, maxChars))
          rest = Font.drop(rest, maxChars)
        end
      else
        line = word
      end
    elseif Font.len(line) + 1 + Font.len(word) <= maxChars then
      line = line .. " " .. word
    else
      put(line)
      line = word
    end
  end
  if line ~= "" then put(line) end
  return cy
end

return Font
