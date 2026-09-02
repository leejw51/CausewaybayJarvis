--- The network client: how the Lua front ends reach the backend.
--
--     local client = require("jarvis.client")
--     local c = assert(client.connect())          -- finds or starts agentd
--     print(c:call("health").provider.effective)   -- one op, one reply
--     local session = c:session("You are Jarvis.")
--     local reply = assert(session:send("why is the sky blue?", nil,
--       function(kind, text) if kind == "token" then io.write(text) end end))
--
-- No library, no FFI: the model lives in `agentd`, the server every client
-- shares, and this file speaks HTTP to it through `curl` — a plain `POST`
-- for an op, and `curl -N` on a pipe for a turn, which arrives as
-- server-sent events and is handed to the handler piece by piece. Plain
-- LuaJIT has no socket of its own; `curl` is on every Mac, and SSE is the
-- transport made for exactly this — one request, a stream of pieces back.
--
-- Stopping a turn is closing the pipe: `curl` goes, the server sees the
-- socket close, and the generation stops there.
--
-- The server is found by the `agentd.port` file in the space and started
-- when the file leads nowhere, the way the LÖVE client and `rustcli` do it,
-- so all three share one loaded model.

local json = require("jarvis.json")

local M = {}

-- ------------------------------------------------------------- the clock --

local ffi = require("ffi")
ffi.cdef [[
  struct jv_timeval { long tv_sec; int tv_usec; };
  int gettimeofday(struct jv_timeval *tv, void *tz);
]]
local tv = ffi.new("struct jv_timeval[1]")

--- Seconds, from the wall clock: what "how long did that take" means when
--- the answer is spent waiting on a socket. Lua's own `os.clock` counts
--- CPU time, which is nearly zero for a client that loads nothing.
function M.now()
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv[0].tv_sec) + tonumber(tv[0].tv_usec) / 1e6
end

-- ------------------------------------------------------------- the space --

--- `$JARVIS_HOME`, or `~/.causewaybayjarvis`.
function M.space(home)
  if home and home ~= "" then return (home:gsub("/+$", "")) end
  local env = os.getenv("JARVIS_HOME")
  if env and env ~= "" then return (env:gsub("/+$", "")) end
  return (os.getenv("HOME") or ".") .. "/.causewaybayjarvis"
end

local function readPort(root)
  local f = io.open(root .. "/agentd.port", "rb")
  if not f then return nil end
  local n = tonumber((f:read("*l") or ""):match("%d+"))
  f:close()
  return n
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Run `curl` with these arguments and give back its whole output.
local function curl(args)
  local pipe = io.popen("curl " .. args .. " 2>/dev/null", "r")
  if not pipe then return nil, "cannot run curl" end
  local out = pipe:read("*a")
  pipe:close()
  return out
end

--- Is anything answering on that port?
local function alive(port)
  if not port then return false end
  local out = curl(string.format("-s -m 2 http://127.0.0.1:%d/health", port))
  return out ~= nil and out:find('"ok":true', 1, true) ~= nil
end

--- Where the server binary is: `$JARVIS_AGENTD`, then the workspace's
--- release build (this file is `lua/jarvis/client.lua` in the checkout),
--- then `agentd` on PATH.
function M.findAgentd()
  local explicit = os.getenv("JARVIS_AGENTD")
  if explicit and explicit ~= "" then return explicit end
  local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]*$") or "."
  local root = here .. "/../.."
  for _, name in ipairs({ "agentd-mlx", "agentd" }) do
    local path = root .. "/rust/target/release/" .. name
    local f = io.open(path, "rb")
    if f then f:close() return path end
  end
  local pipe = io.popen("command -v agentd 2>/dev/null")
  local found = pipe and pipe:read("*l") or nil
  if pipe then pipe:close() end
  if found and found ~= "" then return found end
  return nil
end

local function sleep(seconds)
  os.execute("sleep " .. tostring(seconds))
end

--- Start `agentd listen` on the space, detached, and wait for its port.
local function spawn(root)
  local bin = M.findAgentd()
  if not bin then
    return nil, "no server is running for " .. root ..
      " and no agentd was found to start one — run `make agentd` (or `make start`), or set JARVIS_AGENTD"
  end
  os.execute(string.format("mkdir -p %s 2>/dev/null", shellQuote(root)))
  os.remove(root .. "/agentd.port")
  os.execute(string.format("(JARVIS_HOME=%s %s listen >> %s 2>&1 &)",
    shellQuote(root), shellQuote(bin), shellQuote(root .. "/agentd.log")))
  local deadline = M.now() + 20
  while M.now() < deadline do
    sleep(0.15)
    local port = readPort(root)
    if alive(port) then return port end
  end
  return nil, "the server did not come up — see " .. root .. "/agentd.log"
end

-- ---------------------------------------------------------------- client --

local Client = {}
Client.__index = Client

--- Connect to the space's server, starting one if there is none. Returns
--- the client, or nil and why.
function M.connect(home)
  local root = M.space(home)
  local port = readPort(root)
  if not alive(port) then
    local err
    port, err = spawn(root)
    if not port then return nil, err end
  end
  return setmetatable({ root = root, port = port, base = "http://127.0.0.1:" .. port }, Client)
end

--- Write a request body to a temporary file, for `curl --data-binary @…`:
--- a prompt on a command line is a prompt in `ps`, and a long one does not
--- fit there anyway.
local function bodyFile(text)
  local path = os.tmpname()
  local f = io.open(path, "wb")
  if not f then return nil end
  f:write(text)
  f:close()
  return path
end

--- One op, one reply. Returns the reply's `data`, or nil and its `error`.
function Client:call(op, body)
  body = body or {}
  local path = bodyFile(json.encode and json.encode(body) or M.encode(body))
  if not path then return nil, "cannot write the request" end
  local out = curl(string.format(
    "-s -m 600 -X POST -H 'Content-Type: application/json' --data-binary @%s %s/v1/%s",
    shellQuote(path), self.base, op))
  os.remove(path)
  if not out or out == "" then return nil, "no answer from the server at " .. self.base end
  local reply = json.decode(out)
  if type(reply) ~= "table" then return nil, "bad reply: " .. out:sub(1, 120) end
  if reply.ok ~= true then return nil, tostring(reply.error or "the server refused") end
  return reply.data
end

--- One streamed op — `chat` or `brain.chat` — as server-sent events, each
--- handed to `handler(kind, text, a, b)`: "prefill" with `a` of `b`
--- tokens read, "reasoning", "token", "tool". Returning true from the
--- handler stops the turn. Returns the reply's `data`, or nil and why.
function Client:stream(op, body, handler)
  local path = bodyFile(M.encode(body or {}))
  if not path then return nil, "cannot write the request" end
  local pipe = io.popen(string.format(
    "curl -sN -m 600 -X POST -H 'Content-Type: application/json' --data-binary @%s %s/v1/%s/stream 2>/dev/null",
    shellQuote(path), self.base, op), "r")
  if not pipe then
    os.remove(path)
    return nil, "cannot run curl"
  end

  local event, data, final, err = nil, nil, nil, nil
  local stopped = false
  for line in pipe:lines() do
    if line:sub(1, 7) == "event: " then
      event = line:sub(8)
    elseif line:sub(1, 6) == "data: " then
      data = line:sub(7)
    elseif line == "" and event then
      local frame = json.decode(data or "") or {}
      if event == "done" then
        final = frame
      elseif event == "error" then
        err = tostring(frame.error or "the server refused")
      elseif handler then
        local stop = handler(event, frame.text, frame.done, frame.total)
        if stop then
          stopped = true
          break
        end
      end
      event, data = nil, nil
    end
  end
  pipe:close()
  os.remove(path)

  if stopped then
    return { interrupted = true }
  end
  if err then return nil, err end
  if not final then return nil, "the stream ended without an answer" end
  if final.ok ~= true then return nil, tostring(final.error or "the server refused") end
  return final.data
end

-- --------------------------------------------------------------- session --
--
-- A conversation, kept here: the server's `brain.chat` is stateless and
-- takes the whole message list each turn, which is what makes reset, save
-- and load plain list operations.

local Session = {}
Session.__index = Session

function Client:session(system)
  local s = setmetatable({ client = self, messages = {}, lastTurn = nil, systemText = nil }, Session)
  if system then s:set_system(system) end
  return s
end

function Session:set_system(text)
  self.systemText = text
  for i = #self.messages, 1, -1 do
    if self.messages[i].role == "system" then table.remove(self.messages, i) end
  end
  table.insert(self.messages, 1, { role = "system", content = text })
  return true
end

function Session:reset()
  self.messages = {}
  self.lastTurn = nil
  if self.systemText then self:set_system(self.systemText) end
  return true
end

function Session:messages_json()
  return M.encode(self.messages)
end

function Session:load(text)
  local list = json.decode(text)
  if type(list) ~= "table" then return nil, "not a message list" end
  self.messages = list
  return true
end

function Session:last()
  return self.lastTurn
end

--- What the server is answering with, for a header.
function Session:info()
  local p = self.client:call("provider") or {}
  local od = p.ondevice or {}
  local model = (p.effective == "ondevice" and od.model)
    or (p.effective == "cloud" and p.cloud and p.cloud.model) or "?"
  return {
    model = tostring(model),
    alias = tostring(model),
    effective = tostring(p.effective or "offline"),
    engine = tostring(od.engine or ""),
    server = self.client.base,
  }
end

--- One turn. `options` is passed to the server as the request's `options`
--- (think, effort, temperature, max_tokens, seed); `handler` gets every
--- piece. Returns a completion — `{ text, stop_reason, model, stats }` —
--- or nil and why.
function Session:send(text, options, handler)
  self.messages[#self.messages + 1] = { role = "user", content = text }
  local started = M.now()
  local chunks = 0
  local data, err = self.client:stream("brain.chat", {
    messages = self.messages,
    tools = {},
    options = options or {},
  }, function(kind, piece, a, b)
    chunks = chunks + 1
    if handler then return handler(kind, piece, a, b) end
    return false
  end)
  if not data then
    table.remove(self.messages)
    return nil, err
  end
  local reply = data.message and data.message.content or ""
  local stop = data.interrupted and "interrupted"
    or (data.done_reason == "length" and "length")
    or (data.done_reason == "interrupted" and "interrupted") or "stop"
  self.messages[#self.messages + 1] = { role = "assistant", content = reply }
  local completion = {
    text = reply,
    stop_reason = stop,
    model = tostring(data.model or "?"),
    stats = {
      chunks = chunks,
      seconds = M.now() - started,
    },
  }
  self.lastTurn = completion
  return completion
end

function Session:close() end

-- ---------------------------------------------------------------- encode --

--- A JSON encoder, since `jarvis.json` only reads. Strings, numbers,
--- booleans, arrays and objects; enough for a request.
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

function M.encode(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return v and "true" or "false" end
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.17g", v)
  end
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      return ESC[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
  end
  if t == "table" then
    local out = {}
    if isArray(v) and (#v > 0 or next(v) == nil) then
      for i = 1, #v do out[i] = M.encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    for k, val in pairs(v) do
      out[#out + 1] = M.encode(tostring(k)) .. ":" .. M.encode(val)
    end
    table.sort(out)
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("cannot encode a " .. t)
end

return M
