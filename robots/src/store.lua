-- Everything this build keeps between runs lives in one visible folder:
--
--   ~/.causewaybayjarvis         (override with JARVIS_HOME)
--
-- The same folder the Rust backend opens: `robots.db` is in here, and so is
-- every robot's own space under `agents/<GUID>/`. LOVE's own save directory
-- is buried under Application Support and cannot be pointed anywhere else,
-- so persistence goes through plain io from here. The ollama request files
-- land in tmp/ inside it too, which keeps the API key out of the app-support
-- tree entirely.

local Store = {
  dir = nil,
  made = {},
}

local DEFAULT = ".causewaybayjarvis"

local function home()
  return os.getenv("HOME") or os.getenv("USERPROFILE") or "."
end

function Store.ensure(path)
  if not path or path == "" or Store.made[path] then return end
  os.execute(string.format('mkdir -p "%s" 2>/dev/null', path))
  Store.made[path] = true
end

-- Point the store somewhere else (tests do this); nil restores the default.
function Store.use(dir)
  Store.dir = dir and (dir:gsub("/+$", "")) or nil
  Store.made = {}
  if Store.dir then Store.ensure(Store.dir) end
  return Store.root()
end

function Store.root()
  if not Store.dir then
    local d = os.getenv("JARVIS_HOME")
    if not d or d == "" then d = home() .. "/" .. DEFAULT end
    Store.dir = (d:gsub("/+$", ""))
  end
  Store.ensure(Store.dir)
  return Store.dir
end

-- name may carry one or more subdirectories, e.g. "tmp/req_7.json"
function Store.path(name)
  local root = Store.root()
  local p = root .. "/" .. tostring(name):gsub("^/+", "")
  local dir = p:match("^(.*)/[^/]*$")
  if dir and dir ~= root then Store.ensure(dir) end
  return p
end

function Store.read(name)
  local f = io.open(Store.path(name), "rb")
  if not f then return nil end
  local body = f:read("*a")
  f:close()
  return body
end

function Store.write(name, data)
  local path = Store.path(name)
  local f, err = io.open(path, "wb")
  if not f then return false, err end
  f:write(data or "")
  f:close()
  return true, path
end

-- Append one record to a log file (the jsonl state logs use this).
function Store.append(name, data)
  local path = Store.path(name)
  local f, err = io.open(path, "ab")
  if not f then return false, err end
  f:write(data or "")
  f:close()
  return true, path
end

-- Every non-empty line of a file, in order. Missing file => empty table.
function Store.lines(name)
  local out = {}
  local body = Store.read(name)
  if not body then return out end
  for line in body:gmatch("[^\r\n]+") do
    if line:match("%S") then out[#out + 1] = line end
  end
  return out
end

function Store.exists(name)
  local f = io.open(Store.path(name), "rb")
  if not f then return false end
  f:close()
  return true
end

function Store.remove(name)
  return os.remove(Store.path(name)) and true or false
end

return Store
