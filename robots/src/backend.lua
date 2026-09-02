-- The bridge to `agentd`, the Rust robot backend.
--
-- Everything that is a *fact* about a robot — its GUID, its persona, its
-- photos, its notes, every word it has been told, both search indexes — lives
-- over there, in `~/.causewaybayjarvis/robots.db`. This module is the only
-- thing on this side that knows how to ask.
--
--   Backend.call({ op = "page", agent = id }, function(data, err) ... end)
--
-- The call returns immediately. The worker thread keeps one WebSocket to
-- one long-lived `agentd listen` server — started on demand, found by the
-- `agentd.port` file in the space — and `Backend.update` delivers the answer
-- on a later frame. The server is long-lived because it holds the on-device
-- model: fifteen gigabytes that must be loaded once, not once per window.
-- This client loads nothing, and that is the point: close the window,
-- reopen it, and the brain is still warm.

local Json = require("src.json")

local Backend = {
  ready = false,        -- is there a binary to run?
  reason = "not started",
  bin = nil,
  -- Which space to open. nil inherits $JARVIS_HOME from this process, which
  -- is what a normal run wants; the tests pin it to a scratch directory so
  -- they never touch the operator's own archive.
  home = nil,
  -- Extra environment for the daemon, set on the command line rather than
  -- exported. The tests use it to pin the space and to blank the API key, so
  -- a machine that happens to have one still runs the offline path.
  env = nil,
  inflight = 0,
  calls = 0,
  lastError = nil,
  -- Filled in by health(), which is asked for once at boot.
  health = nil,
}

-- Seconds each op is given before the bridge gives up on it. A turn against
-- the on-device model pays the model load on its first call, so `chat` gets
-- room that `stats` never needs.
local TIMEOUTS = { chat = 600, ["brain.chat"] = 600, reindex = 600, ["item.add"] = 120, prepare = 600 }
local TIMEOUT_DEFAULT = 60

local function timeoutFor(op)
  return TIMEOUTS[tostring(op)] or TIMEOUT_DEFAULT
end

local thread, jobs, results
local pending = {}
local nextId = 0

-- Where the binary is. The release build first, because that is what `make
-- robots` produces; then the debug one, so a working tree mid-change still
-- runs; then whatever is on PATH.
local function candidates()
  local out = {}
  -- LOVE is started on the `robots/` directory, so the workspace is its parent.
  local source = love.filesystem.getSource() or "."
  local root = source:match("^(.*)/[^/]*$") or ".."
  -- A packaged app: the server sits beside the LÖVE binary in
  -- Contents/MacOS, and the fused game is Contents/Resources/game.love —
  -- so from either the source or its base directory it is two or three
  -- steps up and over.
  if love.filesystem.isFused and love.filesystem.isFused() then
    local base = love.filesystem.getSourceBaseDirectory() or root
    for _, dir in ipairs({ base, root, source }) do
      out[#out + 1] = dir .. "/../MacOS/agentd"
      out[#out + 1] = dir .. "/MacOS/agentd"
      out[#out + 1] = dir .. "/Contents/MacOS/agentd"
      out[#out + 1] = dir .. "/../../MacOS/agentd"
    end
  end
  for _, base in ipairs({ root, source .. "/..", "." }) do
    -- The engine-carrying build first: `make gui` copies it to its own name
    -- so a lean rebuild cannot strip the engine out from under a session.
    out[#out + 1] = base .. "/rust/target/release/agentd-mlx"
    out[#out + 1] = base .. "/rust/target/release/agentd"
    out[#out + 1] = base .. "/rust/target/debug/agentd"
  end
  out[#out + 1] = "agentd"
  return out
end

local function executable(path)
  if path == "agentd" then
    -- On PATH or not; `command -v` is the only portable way to ask.
    local pipe = io.popen("command -v agentd 2>/dev/null")
    if not pipe then return nil end
    local found = pipe:read("*l")
    pipe:close()
    return found and found ~= "" and found or nil
  end
  local f = io.open(path, "rb")
  if not f then return nil end
  f:close()
  return path
end

function Backend.find()
  -- An explicit override is the answer, right or wrong. Falling through to the
  -- built binary when `JARVIS_AGENTD` points at nothing would mean a run
  -- pointed at one daemon quietly using another, which is worse than a clear
  -- failure -- and it is exactly what makes the no-backend path untestable.
  local override = os.getenv("JARVIS_AGENTD")
  if override and override ~= "" then
    return executable(override)
  end
  for _, path in ipairs(candidates()) do
    local found = executable(path)
    if found then return found end
  end
  return nil
end

function Backend.init()
  -- A server already up (`make start`) is enough; so is a binary to start
  -- one with. Only a checkout with neither is actually offline.
  Backend.bin = Backend.find()
  Backend.inProcess = false
  if not Backend.bin and not Backend.serverUp() then
    Backend.ready = false
    Backend.reason = "BACKEND NOT BUILT -- RUN MAKE AGENTD"
    return false
  end
  if not love.thread then
    Backend.ready = false
    Backend.reason = "THREAD MODULE OFF"
    return false
  end

  jobs = love.thread.getChannel("agent.jobs")
  results = love.thread.getChannel("agent.results")
  thread = love.thread.newThread("src/backend_worker.lua")
  thread:start()

  Backend.ready = true
  Backend.reason = "BACKEND READY"
  return true
end

--- Is a server already listening for this space? Reads the port file the
--- way the worker does; it is a hint, and the worker verifies it.
function Backend.serverUp()
  local f = io.open(Backend.root() .. "/agentd.port", "rb")
  if not f then return false end
  local port = tonumber((f:read("*l") or ""):match("%d+"))
  f:close()
  return port ~= nil
end

function Backend.shutdown()
  if jobs then jobs:push("quit") end
end

--- The space the daemon opens: the pinned one, or wherever the environment
--- says, or the default. Computed per call because the tests re-point it.
function Backend.root()
  if Backend.home and Backend.home ~= "" then return Backend.home end
  local env = os.getenv("JARVIS_HOME")
  if env and env ~= "" then return (env:gsub("/+$", "")) end
  return (os.getenv("HOME") or ".") .. "/.causewaybayjarvis"
end

-- One request. `cb(data, err)` fires on a later frame, always exactly once.
--
-- `opts.onChunk(kind, text, a, b)` is optional: it fires on every frame
-- that carried a piece of the answer — "token" as the model writes, "tool"
-- when the turn ran one, "prefill" while the prompt is still being read,
-- with `a` of `b` tokens done — so a screen can show the answer being
-- written and, before that, that it is coming. `cb` lands exactly once
-- either way, so nothing has to be written twice.
function Backend.call(request, cb, opts)
  if not Backend.ready then
    if cb then cb(nil, Backend.reason) end
    return false, Backend.reason
  end
  nextId = nextId + 1
  local id = nextId

  local timeout = timeoutFor(request.op)
  pending[id] = { cb = cb, t = 0, op = request.op, timeout = timeout,
                  onChunk = opts and opts.onChunk or nil }
  Backend.inflight = Backend.inflight + 1
  Backend.calls = Backend.calls + 1
  local env = {}
  for k, v in pairs(Backend.env or {}) do env[k] = v end
  jobs:push({
    id = id,
    bin = Backend.bin,
    root = Backend.root(),
    env = env,
    op = request.op,
    -- Only a caller that is listening gets a stream: the server streams
    -- every turn, and a turn nobody is watching should not have its chunks
    -- marshalled across a channel one token at a time.
    stream = (opts and opts.onChunk) ~= nil,
    body = Json.encode(request),
    timeout = timeout,
  })
  return true
end

local function finish(id, data, err)
  local p = pending[id]
  if not p then return end
  pending[id] = nil
  Backend.inflight = math.max(0, Backend.inflight - 1)
  if err then Backend.lastError = err end
  if p.cb then p.cb(data, err) end
end

-- `serve` answers one line per request. Take the last non-blank one: a
-- daemon that printed a warning first should not lose its answer to it.
local function parse(raw)
  if not raw or raw:gsub("%s", "") == "" then
    return nil, "AGENTD SAID NOTHING"
  end
  local last
  for line in raw:gmatch("[^\r\n]+") do
    if line:match("%S") then last = line end
  end
  local obj = Json.decode(last or "")
  if type(obj) ~= "table" then
    return nil, "BAD REPLY: " .. tostring(last):gsub("%s+", " "):sub(1, 90)
  end
  if obj.ok ~= true then
    return nil, tostring(obj.error or "REFUSED"):gsub("%s+", " "):sub(1, 140):upper()
  end
  return obj.data
end

function Backend.update(dt)
  if not Backend.ready then return end

  while true do
    local r = results and results:pop()
    if not r then break end
    if type(r) == "table" and pending[r.id] then
      if r.chunk then
        -- A piece of an answer still being written. Not the reply: the
        -- request stays in flight until the whole turn lands.
        local p = pending[r.id]
        if p.onChunk then p.onChunk(r.chunk, r.text or "", r.a, r.b) end
      else
        local data, err = parse(r.raw)
        if err and r.stderr and r.stderr:match("%S") then
          err = tostring(r.stderr):gsub("%s+", " "):sub(1, 140):upper()
        end
        finish(r.id, data, err)
      end
    end
  end

  -- The worker's own blocking receive is the real timeout; this is the
  -- failsafe behind it, a little wider so the two never race.
  for id, p in pairs(pending) do
    p.t = p.t + dt
    if p.t > (p.timeout or TIMEOUT_DEFAULT) + 30 then
      finish(id, nil, "AGENTD TIMED OUT ON " .. tostring(p.op):upper())
    end
  end
end

function Backend.busy()
  return Backend.inflight > 0
end

-- Ask once at boot: is there a model, and where do the prompts go?
function Backend.askHealth(cb)
  return Backend.call({ op = "health" }, function(data, err)
    if data then
      Backend.health = data
      Backend.provider = data.provider
    end
    if cb then cb(data, err) end
  end)
end

-- -------------------------------------------------------------- prepare ----
--
-- The on-device brain is loaded on the first turn unless someone asks
-- earlier. The client asks at boot, the moment `health` says this machine
-- answers, so the wait is spent behind the boot screen — which says what
-- is loading — rather than behind the first question.

Backend.prepared = nil     -- the `prepare` reply, once it has come
Backend.preparing = false  -- is one in flight?

function Backend.askPrepare(cb)
  Backend.preparing = true
  Backend.prepared = nil
  return Backend.call({ op = "prepare" }, function(data, err)
    Backend.preparing = false
    Backend.prepared = data or { loaded = false, failed = true, why = err }
    if cb then cb(data, err) end
  end)
end

--- Health first; then, when this machine is what answers, the load.
function Backend.warmUp(cb)
  return Backend.askHealth(function(data, err)
    if Backend.wantsPrepare(data) then
      Backend.askPrepare()
    end
    if cb then cb(data, err) end
  end)
end

--- Pure: does this health reply call for a load? Only when the effective
--- brain is on this machine — the cloud has nothing to load, and a session
--- with no brain has nothing to wait for.
function Backend.wantsPrepare(health)
  local p = health and health.provider or nil
  return p ~= nil and p.effective == "ondevice"
end

--- Where the load stands, for the boot screen:
---   none     nothing to wait for — no backend, or a brain not on this machine
---   unknown  health has not answered yet, so nobody knows
---   pending  the load is running
---   ready    loaded
---   failed   the backend refused, or the bridge gave up
function Backend.prepareStatus()
  if not Backend.ready then return "none" end
  if not Backend.health then return "unknown" end
  if Backend.preparing then return "pending" end
  if Backend.prepared then
    if Backend.prepared.failed then return "failed" end
    return Backend.prepared.loaded and "ready" or "none"
  end
  return "none"
end

--- One line for the HUD under the assembling suit.
function Backend.prepareLine()
  local status = Backend.prepareStatus()
  if status == "unknown" then return "LINKING TO THE BACKEND" end
  if status == "pending" then
    local od = Backend.provider and Backend.provider.ondevice or nil
    local model = tostring(od and od.model or "THE MODEL"):upper()
    if od and od.engine == "ollama" then return "WAKING OLLAMA  " .. model end
    return "LOADING " .. model .. " ONTO THE GPU"
  end
  if status == "ready" then
    local r = Backend.prepared or {}
    if r.already then return "BRAIN ALREADY RESIDENT" end
    return string.format("BRAIN LOADED IN %.1fS", tonumber(r.seconds) or 0)
  end
  if status == "failed" then
    return "BRAIN REFUSED  " .. tostring(Backend.prepared and Backend.prepared.why or ""):upper():sub(1, 40)
  end
  return "NOTHING TO LOAD"
end

-- ------------------------------------------------------------- provider ----
--
-- Which brain answers: this machine's MLX engine, ollama.com, or `auto` —
-- on-device when this Mac can, cloud when it cannot. The choice lives in the
-- backend's settings table, so it survives restarts and is shared with the
-- CLI; this side only mirrors it for drawing.

Backend.provider = nil

function Backend.askProvider(cb)
  return Backend.call({ op = "provider" }, function(data, err)
    if data then Backend.provider = data end
    if cb then cb(data, err) end
  end)
end

--- Flip to the next provider on the ring: auto -> ondevice -> cloud -> auto.
function Backend.cycleProvider(cb)
  local current = Backend.provider and Backend.provider.current or "auto"
  local next = Backend.nextProvider(current)
  return Backend.call({ op = "provider.set", provider = next }, function(data, err)
    if data then Backend.provider = data end
    if cb then cb(data, err) end
  end)
end

--- Pure, so the ring is testable: mirrors Provider::next on the Rust side.
function Backend.nextProvider(current)
  local ring = { auto = "ondevice", ondevice = "cloud", cloud = "auto" }
  return ring[tostring(current)] or "auto"
end

--- Ask for one provider outright — what the setup screen's buttons do.
function Backend.setProvider(name, cb)
  return Backend.call({ op = "provider.set", provider = name }, function(data, err)
    if data then Backend.provider = data end
    if cb then cb(data, err) end
  end)
end

-- ---------------------------------------------------------------- setup ----
--
-- The AI setup: which on-device engine (MLX, or a local ollama daemon),
-- where that daemon is and which tag it answers with, and the cloud host,
-- model and key. Every value lives in the backend's space beside the
-- provider choice, and comes back with where it came from — the process
-- environment, the space, `.env`, or the default — so the screen can say
-- why a change in one place did not take.

Backend.config = nil

function Backend.askConfig(cb)
  return Backend.call({ op = "config" }, function(data, err)
    if data then
      Backend.config = data
      if data.provider then Backend.provider = data.provider end
    end
    if cb then cb(data, err) end
  end)
end

--- Write a table of `key = value` into the space. A blank value clears that
--- key's override. The daemon rewires itself before it answers, so the
--- reply already reflects the new setup.
function Backend.setConfig(values, cb)
  return Backend.call({ op = "config.set", values = values }, function(data, err)
    if data then
      Backend.config = data
      if data.provider then Backend.provider = data.provider end
    end
    if cb then cb(data, err) end
  end)
end

--- The on-device line for a report or a chip: the model, and which engine
--- is running it when that is the daemon rather than MLX.
function Backend.ondeviceLabel(p)
  p = p or Backend.provider
  local od = p and p.ondevice or nil
  if not od then return "?" end
  local model = tostring(od.model or "?"):upper()
  if od.engine == "ollama" then return model .. " VIA OLLAMA" end
  return model
end

local WORD = { ondevice = "ON-DEVICE", cloud = "CLOUD" }
local SHORT = { ondevice = "ON-DEV", cloud = "CLOUD" }

--- The label for a chip: what is actually answering, in a whole word, and
--- in brackets how that came about when it was not asked for outright —
--- `(AUTO)` when auto picked it, `(CLOUD REFUSED)` when a wish could not
--- be met. The outcome first, because that is what the operator needs to
--- know before typing.
function Backend.providerLabel()
  local p = Backend.provider
  if not p then return "AI ..." end
  local got = WORD[p.effective] or "OFFLINE"
  local wish = tostring(p.current or "auto")
  if wish == "auto" then return "AI " .. got .. " (AUTO)" end
  if WORD[wish] and WORD[wish] ~= got then return "AI " .. got .. " (" .. WORD[wish] .. " REFUSED)" end
  return "AI " .. got
end

--- The same, for a rail with no room: ON-DEV | CLOUD | OFFLINE.
---
--- It carries the wish as well as the outcome, and it has to. The ring is
--- auto -> on-device -> cloud, and the first of those steps does not change
--- *what answers* — auto already picked on-device. A label showing only the
--- outcome therefore does not move when the button is pressed, and a button
--- that does not move when pressed reads as a broken button.
function Backend.providerShort()
  local p = Backend.provider
  if not p then return "AI ..." end
  local got = SHORT[p.effective] or "OFFLINE"
  local wish = tostring(p.current or "auto")
  if wish == "auto" then return "AI " .. got .. " (AUTO)" end
  if SHORT[wish] and SHORT[wish] ~= got then
    return "AI " .. got .. " (NO " .. SHORT[wish] .. ")"
  end
  return "AI " .. got
end

--- The colour key the label deserves: good when local, info when cloud, warn
--- when nothing can answer.
function Backend.providerTone()
  local eff = Backend.provider and Backend.provider.effective or nil
  if eff == "ondevice" then return "good" end
  if eff == "cloud" then return "info" end
  return "warn"
end

-- Boot-report lines, in the same shape src/ollama.lua returns.
function Backend.report()
  local out = {}
  if not Backend.ready then
    out[#out + 1] = { text = "ARCHIVE OFFLINE  " .. Backend.reason, tone = "warn" }
    return out
  end
  local h = Backend.health
  if not h then
    out[#out + 1] = { text = "ARCHIVE  OPENING...", tone = "info" }
    return out
  end
  out[#out + 1] = { text = "ARCHIVE  " .. tostring(h.root or "?"):upper(), tone = "good" }
  out[#out + 1] = { text = "BACKEND  AGENTD OVER WEBSOCKET", tone = "good" }
  local p = h.provider
  if p then
    local eff = tostring(p.effective or "offline"):upper()
    if p.effective == "ondevice" then
      out[#out + 1] = { text = "AGENT BRAIN  ON-DEVICE  " .. Backend.ondeviceLabel(p), tone = "good" }
    elseif p.effective == "cloud" then
      local model = p.cloud and p.cloud.model or nil
      out[#out + 1] = { text = "AGENT BRAIN  CLOUD  " .. tostring(model or ""):upper(), tone = "info" }
    else
      out[#out + 1] = { text = "AGENT BRAIN  OFFLINE  " ..
        tostring(p.why or ""):upper():sub(1, 44), tone = "warn" }
    end
  end
  -- The cloud client's own lines — host, model, and the caution that prompts
  -- leave the machine — only when the cloud is what answers. Printing the
  -- caution under an on-device brain would be the lie this report exists
  -- to avoid.
  if p and p.effective == "cloud" then
    for _, line in ipairs(h.report or {}) do
      out[#out + 1] = { text = tostring(line.text), tone = tostring(line.tone or "info") }
    end
  end
  if h.embed_fallback then
    out[#out + 1] = { text = "EMBED FELL BACK TO LOCAL VECTORS", tone = "warn" }
  end
  -- The load the boot screen waited through, so the report says the first
  -- answer will not pay for it — or why it will.
  local r = Backend.prepared
  if r and r.loaded then
    local how = r.already and "ALREADY RESIDENT" or string.format("LOADED IN %.1fS", tonumber(r.seconds) or 0)
    out[#out + 1] = { text = "AGENT BRAIN  " .. tostring(r.engine or ""):upper() .. "  " .. how, tone = "good" }
  elseif r and r.failed then
    out[#out + 1] = { text = "AGENT BRAIN  LOAD FAILED  " .. tostring(r.why or ""):upper():sub(1, 34), tone = "warn" }
  end
  return out
end

-- Reached by tests/, so reply handling can be checked without a subprocess.
Backend._test = {
  parse = parse,
  candidates = candidates,
  timeoutFor = timeoutFor,
}

return Backend
