-- A file box, from inside LOVE.
--
-- LOVE has no file dialog of its own, so the operating system's is borrowed:
-- `osascript` on macOS (`choose file`), `zenity` elsewhere. The dialog is
-- modal and blocks the process that opens it, which is why it runs on a
-- worker thread — the window keeps drawing, and the chosen paths come back
-- through a channel on a later frame, the same way the backend's answers do.
--
-- `photo` narrows the box to pictures; `file` takes anything. Both allow more
-- than one, because "add these" is what a photo box is for.

local Picker = {
  busy = false,
  pending = nil,     -- { cb = fn, kind = "photo"|"file", t = 0 }
  lastError = nil,
}

local jobs, results, thread
local nextId = 0

--- Which dialog this machine has. Pure over the platform name, so the
--- command can be checked without opening a window.
function Picker.tool(os_name)
  os_name = os_name or (love and love.system and love.system.getOS()) or "OS X"
  if os_name == "OS X" or os_name == "macOS" then return "osascript" end
  return "zenity"
end

--- The shell command that opens the box and prints one POSIX path per line.
--- A cancelled box prints nothing. Pure, so the tests can read it.
function Picker.command(kind, tool)
  tool = tool or Picker.tool()
  local photo = kind == "photo"
  if tool == "osascript" then
    local prompt = photo and "Add photos to this AI agent" or "Add files to this AI agent"
    local of = photo and ' of type {"public.image"}' or ""
    local lines = {
      string.format('set fs to choose file with prompt "%s"%s with multiple selections allowed', prompt, of),
      'set out to ""',
      "repeat with f in fs",
      "set out to out & POSIX path of f & linefeed",
      "end repeat",
      "out",
    }
    local parts = {}
    for _, l in ipairs(lines) do
      parts[#parts + 1] = "-e '" .. l:gsub("'", "'\\''") .. "'"
    end
    return "osascript " .. table.concat(parts, " ") .. " 2>/dev/null"
  end
  local filter = photo and " --file-filter='Images | *.png *.jpg *.jpeg *.gif *.webp *.bmp'" or ""
  return "zenity --file-selection --multiple --separator='\\n'" .. filter .. " 2>/dev/null"
end

--- The dialog's output as a list of paths. Blank lines and trailing
--- whitespace are dropped; nothing else is trusted or changed.
function Picker.parse(out)
  local paths = {}
  for line in tostring(out or ""):gmatch("[^\r\n]+") do
    line = line:gsub("%s+$", "")
    if line:match("%S") then paths[#paths + 1] = line end
  end
  return paths
end

local function ensureThread()
  if thread or not love or not love.thread then return false end
  jobs = love.thread.getChannel("picker.jobs")
  results = love.thread.getChannel("picker.results")
  thread = love.thread.newThread("src/picker_worker.lua")
  thread:start()
  return true
end

--- Open the box. `cb(paths, err)` fires on a later frame, once: `paths` is
--- a (possibly empty — cancelled) list. Only one box at a time.
function Picker.open(kind, cb)
  if Picker.busy then
    if cb then cb(nil, "A FILE BOX IS ALREADY OPEN") end
    return false
  end
  kind = kind == "photo" and "photo" or "file"
  local cmd = Picker.command(kind)
  Picker.busy = true
  nextId = nextId + 1
  Picker.pending = { cb = cb, kind = kind, id = nextId, t = 0 }
  if ensureThread() or thread then
    jobs:push({ id = nextId, cmd = cmd })
    return true
  end
  -- No thread module: block. Still correct, just not smooth.
  local pipe = io.popen(cmd, "r")
  local out = pipe and pipe:read("*a") or ""
  if pipe then pipe:close() end
  Picker.finish(nextId, out)
  return true
end

function Picker.finish(id, out, err)
  local p = Picker.pending
  if not p or p.id ~= id then return end
  Picker.pending = nil
  Picker.busy = false
  Picker.lastError = err
  if p.cb then p.cb(err and nil or Picker.parse(out), err) end
end

--- Deliver whatever the worker has finished. Called every frame.
function Picker.update(dt)
  if Picker.pending then Picker.pending.t = Picker.pending.t + (dt or 0) end
  if not results then return end
  while true do
    local r = results:pop()
    if not r then break end
    if type(r) == "table" then Picker.finish(r.id, r.out, r.err) end
  end
end

function Picker.shutdown()
  if jobs then jobs:push("quit") end
end

return Picker
