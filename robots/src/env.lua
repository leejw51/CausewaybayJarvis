-- Tiny .env reader. Looks in the game source dir, then the real process env.
-- Accepts `KEY=value`, `export KEY=value`, quoted values and # comments.

local Env = {
  vars = {},
  loaded = false,
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isQuoted(s)
  local q = s:sub(1, 1)
  return #s >= 2 and (q == '"' or q == "'") and s:sub(-1) == q
end

-- A quoted value is taken literally, hashes and all. Only an unquoted one
-- can carry a trailing # comment.
local function value(s)
  s = trim(s)
  if isQuoted(s) then return s:sub(2, -2) end
  return trim((s:gsub("%s+#.*$", "")))
end

function Env.load(path)
  path = path or ".env"
  Env.vars = {}
  Env.loaded = true
  local body = love.filesystem.read(path)
  if not body then return Env end
  for line in (body .. "\n"):gmatch("(.-)\n") do
    local s = trim(line)
    if s ~= "" and s:sub(1, 1) ~= "#" then
      s = s:gsub("^export%s+", "")
      local k, v = s:match("^([%w_%.]+)%s*=%s*(.*)$")
      if k then
        Env.vars[k] = value(v)
      end
    end
  end
  return Env
end

function Env.get(key, fallback)
  if not Env.loaded then Env.load() end
  local v = Env.vars[key]
  if v == nil or v == "" then v = os.getenv(key) end
  if v == nil or v == "" then return fallback end
  return v
end

return Env
