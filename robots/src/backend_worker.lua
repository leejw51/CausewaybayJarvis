-- Worker thread: where the backend is actually spoken to.
--
-- Two ways in, and this thread picks one per space and keeps it.
--
--   a daemon    `agentd` in its own process, one WebSocket to it for the life
--               of the window, found by the `agentd.port` file in the space.
--               The model lives over there across windows: close this one and
--               reopen it and the brain is still warm, and a fault in the
--               engine takes the server down rather than the screen.
--   the library `libjarvis`, carrying the same backend, called in this
--               process — no port file, no twenty-second wait for a server to
--               come up, nothing left running afterwards. This is what the
--               packaged app uses, and why it is one thing to install: the
--               app *is* the backend. The model is loaded into this process
--               and dies with it.
--
-- A daemon already holding the space wins, because two backends on one
-- database is not something to arrange by accident and because its model is
-- already warm. Failing that the library is used when there is one, and only
-- then is a daemon started.
--
-- One request goes out as one frame carrying an `id`; the frames that come
-- back with that id are pushed onto the results channel as they arrive —
-- `token`, `tool`, `prefill` while a turn is being written, then the whole
-- reply, once. `Backend.update` on the main thread delivers them on later
-- frames. Requests are answered in the order they were made.

require("love.thread")
local WS = require("src.wsclient")
local socket = require("socket")
local Json = require("src.json")
local Ffi = require("src.jarvis_ffi")

local jobs = love.thread.getChannel("agent.jobs")
local results = love.thread.getChannel("agent.results")

local ws = nil
local spawned = false     -- did *we* start the server this session?
local lastRoot = nil
-- "socket" or "ffi", decided once for a space and then left alone: a daemon
-- that appears later must not take a session's second half.
local mode = nil
local modeRoot = nil

local function quote(path)
  return "'" .. tostring(path):gsub("'", "'\\''") .. "'"
end

-- Environment on the command line rather than exported, so two spaces can be
-- open at once. Keys are checked, not quoted: a variable name is letters,
-- digits and underscores, and anything else is not one.
local function envPrefix(job)
  local env = { "JARVIS_HOME=" .. quote(job.root) }
  for key, value in pairs(job.env or {}) do
    if type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$")
      and key ~= "JARVIS_HOME" then
      env[#env + 1] = key .. "=" .. quote(value)
    end
  end
  table.sort(env)
  return table.concat(env, " ") .. " "
end

local function readPort(root)
  local f = io.open(root .. "/agentd.port", "rb")
  if not f then return nil end
  local n = tonumber((f:read("*l") or ""):match("%d+"))
  f:close()
  return n
end

local function tryConnect(port)
  if not port then return nil end
  local conn = WS.connect("127.0.0.1", port, "/ws", 2)
  return conn
end

local function sleep(seconds)
  socket.sleep(seconds)
end

local function spawnServer(job)
  os.execute(string.format("mkdir -p %s 2>/dev/null", quote(job.root)))
  -- The stale port file has to go first, or the poll below can connect to a
  -- corpse's number that some other process now owns.
  os.remove(job.root .. "/agentd.port")
  local cmd = string.format("(%s%s listen >> %s 2>&1 &)",
    envPrefix(job), quote(job.bin), quote(job.root .. "/agentd.log"))
  os.execute(cmd)
  spawned = true
end

--- A live WebSocket, or nil and why not.
local function ensure(job)
  if ws and ws.open and lastRoot == job.root then return ws end
  if ws then
    ws:close()
    ws = nil
  end
  lastRoot = job.root

  ws = tryConnect(readPort(job.root))
  if ws then return ws end

  if not job.bin then
    return nil, "no agentd to start — run make agentd, or make start"
  end
  spawnServer(job)
  local deadline = os.time() + 20
  while os.time() <= deadline do
    sleep(0.15)
    ws = tryConnect(readPort(job.root))
    if ws then return ws end
  end
  return nil, "could not start agentd — see " .. job.root .. "/agentd.log"
end

--- The request with the job's id in it, so its frames can be told apart.
local function stamped(job)
  local body = tostring(job.body or "{}")
  if body:match("^%s*{%s*}%s*$") then
    return string.format('{"id":%d}', job.id)
  end
  return (body:gsub("^%s*{", string.format('{"id":%d,', job.id), 1))
end

--- One request over the socket: the frames of its answer as they come,
--- then the reply. A dead connection gets one reconnect; a timeout closes
--- the socket rather than risking a late frame being read as part of the
--- *next* request's answer.
local function overSocket(job)
  for attempt = 1, 2 do
    local conn, err = ensure(job)
    if not conn then return nil, err end
    local sent = conn:send(stamped(job))
    if sent then
      while true do
        local text, rerr = conn:receive(job.timeout or 600)
        if not text then
          conn:close()
          ws = nil
          if rerr == "timeout" then
            return nil, "agentd timed out"
          end
          break -- closed: fall through and reconnect once
        end
        local frame = Json.decode(text)
        if type(frame) == "table" and frame.id == job.id then
          if frame.chunk then
            -- Prefill is forwarded with the others, and it is the one that
            -- matters most on a slow machine: a turn against the on-device
            -- model spends seconds reading the prompt before it writes a
            -- single token, and a screen with nothing on it for those
            -- seconds is indistinguishable from one that has stopped.
            if job.stream then
              if frame.chunk == "prefill" then
                results:push({ id = job.id, chunk = "prefill", text = "",
                               a = frame.done, b = frame.total })
              else
                results:push({ id = job.id, chunk = frame.chunk, text = frame.text or "" })
              end
            end
          else
            return text
          end
        end
        -- A frame for another id is a straggler from a request that timed
        -- out; nobody is waiting for it.
      end
    else
      conn:close()
      ws = nil
    end
    if attempt == 2 then return nil, "lost the connection to agentd" end
  end
end

--- One request through the library. The same contract `overSocket` has: the
--- reply as text, or nil and why not, with the pieces of a turn pushed as
--- they arrive.
local function overFfi(job)
  local stream = nil
  if job.stream then
    stream = function(kind, text, a, b)
      if kind == "prefill" then
        results:push({ id = job.id, chunk = "prefill", text = "", a = a, b = b })
      else
        results:push({ id = job.id, chunk = kind, text = text })
      end
      return false -- nothing here cancels a turn; `stop` is its own op
    end
  end
  return Ffi.call(job.body or "{}", stream)
end

--- Which way in, decided once per space.
local function choose(job)
  if mode and modeRoot == job.root then return mode end
  modeRoot = job.root

  -- A daemon already answering for this space is the one to use, whoever
  -- started it: it is holding the model this window would otherwise load
  -- again, in a process that outlives the window.
  local live = tryConnect(readPort(job.root))
  if live then
    ws = live
    lastRoot = job.root
    mode = "socket"
    results:push({ mode = mode })
    return mode
  end

  if job.lib then
    local ok, why = Ffi.start(job.lib, job.root, job.env)
    if ok then
      mode = "ffi"
      results:push({ mode = mode })
      return mode
    end
    -- Not fatal on its own: a checkout may still have a binary to start.
    io.stderr:write("backend: " .. tostring(why) .. "\n")
  end

  mode = "socket"
  -- Told either way, and told the truth: the screen says how it is being
  -- answered, and a guess made on the main thread is not that.
  results:push({ mode = mode })
  return mode
end

while true do
  local job = jobs:demand()
  if type(job) ~= "table" then
    -- Quitting. A server we started is ours to stop: in an mlx build it is
    -- holding the model, and an orphan with fifteen gigabytes resident is
    -- not a background process, it is a squatter. One somebody else
    -- started (`make start`) is left running for the next window.
    Ffi.stop()
    if spawned and lastRoot then
      local conn = ws and ws.open and ws or tryConnect(readPort(lastRoot))
      if conn then
        conn:send('{"id":0,"op":"daemon.stop"}')
        conn:receive(3)
        conn:close()
      end
      ws = nil
    end
    if ws then ws:close() end
    break
  end

  local raw, err
  if choose(job) == "ffi" then
    raw, err = overFfi(job)
  else
    raw, err = overSocket(job)
  end
  results:push({ id = job.id, raw = raw or "", stderr = err })
end
