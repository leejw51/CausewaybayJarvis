--- The colours.
---
--- Three sets, and the client is built for the first one:
---
---   **snes**   — a Super Famicom palette. Every colour is on the five-bit
---                per channel grid the hardware could address (BGR555), and
---                there are enough of them to shade a sprite properly: three
---                or four tones per material rather than one flat fill.
---                Backgrounds are posterised and dithered rather than crushed,
---                which is what a painted 16-bit background actually was.
---   **msx**    — the 8-bit version: sixteen colours on the V9938's eight-level
---                ladder, and every plate quantised to exactly those sixteen.
---   **apple2** — the other half of 1983, flatter and colder.
---
--- Everything asks for a colour by *role*, so switching re-skins the whole
--- game, backgrounds included. The sixteen base roles exist in every set; the
--- extra shading roles are real colours in `snes` and aliases of the base
--- sixteen in the 8-bit sets, so a sprite written against the full list still
--- draws (with less shading) when the palette drops to sixteen.

local M = {}

-- The sixteen the quantiser is handed, in order, when a set works that way.
M.slots = {
  "black", "navy", "blue", "cyan", "green", "lime", "olive", "yellow",
  "gold", "orange", "red", "maroon", "magenta", "gray", "silver", "white",
}

-- The rest: shading tones, and the materials a knight is made of.
M.extras = {
  "ink", "shadow", "deep", "steel", "moon", "bone", "flesh",
  "ember", "flame", "rust", "violet", "teal", "leaf", "wine",
}

local function rgb(hex)
  return {
    tonumber(hex:sub(1, 2), 16) / 255,
    tonumber(hex:sub(3, 4), 16) / 255,
    tonumber(hex:sub(5, 6), 16) / 255,
  }
end

M.sets = {
  -- Every value is a multiple of 8, which is to say it exists in BGR555 and a
  -- Super Famicom could hold it. Cool cast throughout: the whole game is set
  -- at night in Bohemia and the light comes from torches.
  snes = {
    label = "SNES",
    quantize = "levels",
    levels = 13,          -- per channel, before the 5-bit snap
    spread = 0.09,
    colors = {
      black = "080810", navy = "182848", blue = "3868B8", cyan = "58C8E8",
      green = "187850", lime = "58C070", olive = "786038", yellow = "F8E080",
      gold = "E0A038", orange = "E87038", red = "C83840", maroon = "701828",
      magenta = "A858A0", gray = "485068", silver = "A8B0C8", white = "F8F8F8",
    },
    extra = {
      ink = "101018",     -- outlines
      shadow = "202038",  -- the dark side of everything
      deep = "101828",    -- night air
      steel = "6878A0",   -- mail and blade
      moon = "C8D8F8",    -- the highlight on steel
      bone = "D8D0B8",    -- padded linen, parchment
      flesh = "E0A880",
      ember = "F8A048",   -- torchlight
      flame = "F8D058",
      rust = "904828",    -- leather, iron that has seen weather
      violet = "6848A0",
      teal = "287888",
      leaf = "406030",
      wine = "581828",    -- the cloak
    },
  },

  -- MSX2, on the V9938's eight-level ladder.
  msx = {
    label = "MSX2",
    quantize = "palette",
    levels = 0,
    spread = 0.16,
    colors = {
      black = "000000", navy = "24246D", blue = "4949B6", cyan = "6DDBFF",
      green = "006D49", lime = "49DB6D", olive = "6D4924", yellow = "FFDB6D",
      gold = "DB9224", orange = "FF6D24", red = "DB2424", maroon = "6D0024",
      magenta = "B649B6", gray = "494949", silver = "B6B6B6", white = "FFFFFF",
    },
    alias = {
      ink = "black", shadow = "navy", deep = "black", steel = "blue",
      moon = "silver", bone = "silver", flesh = "orange", ember = "orange",
      flame = "yellow", rust = "maroon", violet = "magenta", teal = "cyan",
      leaf = "green", wine = "maroon",
    },
  },

  -- Apple II composite. `maroon` is mixed: the hardware set has no dark red,
  -- and a sixteen-slot palette with a hole in it dithers badly.
  apple2 = {
    label = "APPLE II",
    quantize = "palette",
    levels = 0,
    spread = 0.18,
    colors = {
      black = "000000", navy = "000099", blue = "2222FF", cyan = "44FF99",
      green = "007722", lime = "11DD00", olive = "885500", yellow = "FFFF00",
      gold = "FF6600", orange = "FF9988", red = "DD0033", maroon = "660022",
      magenta = "DD22DD", gray = "555555", silver = "AAAAAA", white = "FFFFFF",
    },
    alias = {
      ink = "black", shadow = "navy", deep = "black", steel = "blue",
      moon = "silver", bone = "silver", flesh = "orange", ember = "gold",
      flame = "yellow", rust = "olive", violet = "magenta", teal = "cyan",
      leaf = "green", wine = "maroon",
    },
  },
}

M.order = { "snes", "msx", "apple2" }

local active, cache, flat

--- Switch palettes. Anything holding a colour table from before must ask
--- again, so callers fetch colours at draw time rather than caching them.
function M.use(name)
  local set = M.sets[name] or M.sets.snes
  M.name = M.sets[name] and name or "snes"
  M.label = set.label
  M.quantize = set.quantize
  M.levels = set.levels
  M.spread = set.spread
  active = set

  cache, flat = {}, {}
  for i, slot in ipairs(M.slots) do
    local c = rgb(set.colors[slot])
    cache[slot], cache[i] = c, c
    flat[(i - 1) * 3 + 1], flat[(i - 1) * 3 + 2], flat[(i - 1) * 3 + 3] = c[1], c[2], c[3]
  end
  for _, slot in ipairs(M.extras) do
    if set.extra and set.extra[slot] then
      cache[slot] = rgb(set.extra[slot])
    else
      cache[slot] = cache[(set.alias and set.alias[slot]) or "white"]
    end
  end
  return M.name
end

function M.next()
  for i, name in ipairs(M.order) do
    if name == M.name then return M.use(M.order[i % #M.order + 1]) end
  end
  return M.use(M.order[1])
end

--- One colour, by role name or by index. Never mutate what comes back.
function M.c(slot) return cache[slot] or cache.white end

--- Hand it to love.graphics, optionally faded.
function M.set(slot, alpha)
  local c = M.c(slot)
  love.graphics.setColor(c[1], c[2], c[3], alpha or 1)
end

function M.flat() return flat end

--- Step through a list of roles on a timer — the palette animation every
--- machine of this era used in place of alpha.
function M.cycle(slots, time, speed)
  local i = math.floor(time * (speed or 6)) % #slots + 1
  return slots[i]
end

--- Pick out of a ramp by fraction. Sprites are shaded by walking these.
function M.ramp(ramp, fraction)
  local i = math.floor(fraction * #ramp) + 1
  return ramp[math.max(1, math.min(#ramp, i))]
end

M.use("snes")

return M
