--- A JSON reader, because LuaJIT has none and the library speaks JSON.
--
-- Decoding only: every structured result crosses the boundary as JSON text,
-- and nothing here has to send any back. `null` decodes to `nil` — in this API
-- a null is always an absent field (no reasoning block, an unquantized
-- checkpoint), which is exactly what a missing Lua key means.
--
-- In an array a `nil` cannot mean that, because it would take the positions of
-- everything after it with it. `M.null` stands in there instead: `config.jsonl`
-- holds whatever the user put in it, and `[1, null, 2]` has to stay three long.

local M = {}

--- A JSON `null` that has to keep its place. See the note above.
M.null = setmetatable({}, { __tostring = function() return "null" end })

local escapes = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function fail(text, pos, message)
  local line = 1
  for _ in text:sub(1, pos):gmatch("\n") do line = line + 1 end
  error(string.format("json: %s at line %d (offset %d)", message, line, pos), 0)
end

local function skip_space(text, pos)
  return (text:find("[^ \t\r\n]", pos)) or #text + 1
end

--- UTF-8 for one code point, so `\uXXXX` survives the trip.
local function utf8_encode(code)
  if code < 0x80 then
    return string.char(code)
  elseif code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  elseif code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function parse_string(text, pos)
  local out, i = {}, pos + 1
  while true do
    local stop = text:find('["\\]', i)
    if not stop then fail(text, pos, "unterminated string") end
    out[#out + 1] = text:sub(i, stop - 1)
    local char = text:sub(stop, stop)
    if char == '"' then
      return table.concat(out), stop + 1
    end
    local escape = text:sub(stop + 1, stop + 1)
    if escape == "u" then
      local hex = text:sub(stop + 2, stop + 5)
      local code = tonumber(hex, 16)
      if not code then fail(text, stop, "bad \\u escape") end
      i = stop + 6
      -- A code point above the BMP arrives as a surrogate pair.
      if code >= 0xD800 and code <= 0xDBFF and text:sub(i, i + 1) == "\\u" then
        local low = tonumber(text:sub(i + 2, i + 5), 16)
        if low and low >= 0xDC00 and low <= 0xDFFF then
          code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
          i = i + 6
        end
      end
      out[#out + 1] = utf8_encode(code)
    else
      local literal = escapes[escape]
      if not literal then fail(text, stop, "unknown escape \\" .. escape) end
      out[#out + 1] = literal
      i = stop + 2
    end
  end
end

local parse_value

local function parse_array(text, pos)
  local out, n, i = {}, 0, skip_space(text, pos + 1)
  if text:sub(i, i) == "]" then return out, i + 1 end
  while true do
    local value
    value, i = parse_value(text, i)
    n = n + 1
    -- Counted rather than appended with `#out + 1`: a nil would append
    -- nothing, and every later element would slide down one.
    out[n] = value ~= nil and value or M.null
    i = skip_space(text, i)
    local char = text:sub(i, i)
    if char == "]" then return out, i + 1 end
    if char ~= "," then fail(text, i, "expected , or ] in array") end
    i = skip_space(text, i + 1)
  end
end

local function parse_object(text, pos)
  local out, i = {}, skip_space(text, pos + 1)
  if text:sub(i, i) == "}" then return out, i + 1 end
  while true do
    if text:sub(i, i) ~= '"' then fail(text, i, "expected a key") end
    local key
    key, i = parse_string(text, i)
    i = skip_space(text, i)
    if text:sub(i, i) ~= ":" then fail(text, i, "expected : after a key") end
    local value
    value, i = parse_value(text, skip_space(text, i + 1))
    out[key] = value
    i = skip_space(text, i)
    local char = text:sub(i, i)
    if char == "}" then return out, i + 1 end
    if char ~= "," then fail(text, i, "expected , or } in object") end
    i = skip_space(text, i + 1)
  end
end

parse_value = function(text, pos)
  local char = text:sub(pos, pos)
  if char == '"' then return parse_string(text, pos) end
  if char == "{" then return parse_object(text, pos) end
  if char == "[" then return parse_array(text, pos) end
  if text:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if text:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if text:sub(pos, pos + 3) == "null" then return nil, pos + 4 end

  local literal = text:match("^%-?%d+%.?%d*[eE]?[-+]?%d*", pos)
  local number = literal and tonumber(literal)
  if not number then fail(text, pos, "expected a value") end
  return number, pos + #literal
end

--- Decode JSON text. Raises on malformed input.
function M.decode(text)
  if type(text) ~= "string" then
    error("json: expected a string, got " .. type(text), 0)
  end
  local value, pos = parse_value(text, skip_space(text, 1))
  pos = skip_space(text, pos)
  if pos <= #text then fail(text, pos, "trailing input") end
  return value
end

return M
