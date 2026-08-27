--- The folder this project keeps things in: `~/.causewaybayjarvis`.
---
--- Deliberately *not* the LOVE save folder. `love.filesystem` may only write
--- inside its own directory under Application Support, which is where the
--- screenshots go and where nothing else in this project would think to look.
--- An export exists to be read somewhere else, so it goes where the rest of
--- the project's state lives -- and reaching outside the sandbox means plain
--- `io` and a `mkdir`, not `love.filesystem`.

local M = {}

local home = os.getenv("HOME") or "."

M.DIR = home .. "/.causewaybayjarvis"

--- Single-quote a path for the shell, POSIX style: close the quoting, an
--- escaped quote, open it again. A home directory is not supposed to have a
--- quote in it and one day one will.
local function shell_quote(path)
  return "'" .. path:gsub("'", "'\\''") .. "'"
end

--- The home directory written as `~`, the way the boot screen and the settings
--- page write it. The path is fifty characters and most of them are the same
--- on every machine.
function M.tilde(path)
  if #home > 1 and path:sub(1, #home) == home then
    return "~" .. path:sub(#home + 1)
  end
  return path
end

--- Make sure the folder is there. `mkdir -p` because it is idempotent and
--- because `love.filesystem.createDirectory` can only make directories inside
--- the save folder, which is the one place this is not.
function M.ensure()
  local ok = os.execute("mkdir -p " .. shell_quote(M.DIR))
  return ok == true or ok == 0
end

--- Write one file into it. Returns the path it landed at, or nil and why.
---
--- `name` is a bare filename -- the callers build it from a format and a
--- timestamp -- and it is joined here rather than passed in whole so that
--- nothing outside this file has to know where the folder is.
function M.write(name, body)
  if not M.ensure() then return nil, "could not make " .. M.tilde(M.DIR) end
  local path = M.DIR .. "/" .. name
  local file, why = io.open(path, "wb")
  if not file then return nil, tostring(why) end
  local ok, err = file:write(body)
  file:close()
  if not ok then return nil, tostring(err) end
  return path
end

return M
