--- Terminal presentation: colour, a status line that redraws in place, and the
--- number formatting the Rust front ends use, so the two look alike.

local ffi = require("ffi")
ffi.cdef [[ int isatty(int fd); ]]
-- The wall clock, from the network client: the status line is throttled
-- by it, and this module must not need the engine library to draw.
local now = require("jarvis.client").now

local M = {}

-- Colour only when stdout is a terminal, and never when NO_COLOR is set.
M.enabled = os.getenv("NO_COLOR") == nil and ffi.C.isatty(1) ~= 0

local CODES = { dim = "2", bold = "1", cyan = "36", green = "32", yellow = "33", red = "31" }

local function wrap(code, text)
  if not M.enabled then return text end
  return "\27[" .. code .. "m" .. text .. "\27[0m"
end

for name, code in pairs(CODES) do
  M[name] = function(text) return wrap(code, text) end
end

--- Open a dim run without closing it — for streaming reasoning text.
function M.dim_on() return M.enabled and "\27[2m" or "" end

function M.off() return M.enabled and "\27[0m" or "" end

--- Strip the colour escapes out of a string. They are bytes that take no
--- columns, so anything measuring or trimming a line has to drop them first.
function M.plain(text) return (text:gsub("\27%[[%d;]*m", "")) end

--- Display width in columns rather than bytes: a status line holding a model
--- name has to be erased by as many spaces as it drew, and counting an escape
--- run as eight characters would leave it writing spaces over the line below.
function M.width(text)
  local n = 0
  for _ in M.plain(text):gmatch("[^\128-\191]") do n = n + 1 end
  return n
end

--- Cut a line down to `columns` display columns, escapes and all.
---
--- A status line is redrawn with a leading `\r`, which returns to the start of
--- the *physical* line: one that wrapped leaves the carriage on the wrong row
--- and the redraw marches down the terminal. So nothing is ever drawn wider
--- than the terminal is.
function M.truncate(text, columns)
  columns = columns or M.columns()
  if M.width(text) <= columns then return text end
  local out, n = {}, 0
  local i = 1
  while i <= #text do
    local escape = text:match("^\27%[[%d;]*m", i)
    if escape then
      out[#out + 1] = escape
      i = i + #escape
    else
      local byte = text:byte(i)
      local size = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
      if n + 1 > columns - 1 then break end
      out[#out + 1] = text:sub(i, i + size - 1)
      n = n + 1
      i = i + size
    end
  end
  return table.concat(out) .. "…" .. M.off()
end

--- How wide the terminal is. `$COLUMNS` when the shell exports it, and eighty
--- otherwise — the width every terminal has had since before it had colour.
function M.columns()
  return tonumber(os.getenv("COLUMNS")) or 80
end

function M.human_bytes(bytes)
  local units = { "B", "KiB", "MiB", "GiB", "TiB" }
  local value, unit = tonumber(bytes) or 0, 1
  while value >= 1024 and unit < #units do
    value = value / 1024
    unit = unit + 1
  end
  if unit == 1 then return string.format("%d B", value) end
  return string.format("%.1f %s", value, units[unit])
end

function M.human_count(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return string.format("%d", n)
end

--- `[####----]`, twenty cells wide.
function M.bar(fraction)
  local width = 20
  fraction = math.max(0, math.min(1, fraction or 0))
  local filled = math.floor(fraction * width + 0.5)
  return "[" .. string.rep("#", filled) .. string.rep("-", width - filled) .. "]"
end

--- A one-line status that redraws in place, throttled so a callback firing per
--- token does not spend its time writing to the terminal.
local Status = {}
Status.__index = Status

function M.status(interval)
  return setmetatable({ drawn = 0, last = -1, interval = interval or 0.08 }, Status)
end

function Status:set(text)
  if now() - self.last < self.interval then return end
  self:force(text)
end

function Status:force(text)
  if not M.enabled then return end
  text = M.truncate(text, M.columns())
  local width = M.width(text)
  io.write("\r", text, string.rep(" ", math.max(0, self.drawn - width)))
  io.flush()
  self.drawn = width
  self.last = now()
end

function Status:clear()
  if M.enabled and self.drawn > 0 then
    io.write("\r", string.rep(" ", self.drawn), "\r")
    io.flush()
  end
  self.drawn = 0
end

return M
