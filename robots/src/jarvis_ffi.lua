-- The backend as a library call, not a socket.
--
-- `libjarvis` carries the whole robot backend — the archive, the roster, both
-- searches, a turn with its tools — behind four C functions. This module is
-- the worker thread's binding to them, and it is deliberately small: only what
-- a client needs to open a space and ask it something.
--
--   local Ffi = require("src.jarvis_ffi")
--   Ffi.start("/path/to/libjarvis.dylib", root, env)
--   local reply, err = Ffi.call('{"op":"agents.list"}')
--
-- What comes back is the same JSON envelope `agentd` would have sent over a
-- WebSocket, from the same dispatch in Rust, so everything above this line
-- reads one protocol whichever way the answer arrived.
--
-- This is what lets the packaged app be one thing. There is no second process
-- to find, to start, to wait twenty seconds for, or to leave running after the
-- window closes: the backend is in this process, and it goes when it goes.
-- The cost is that the model goes with it — a daemon holds fifteen gigabytes
-- across windows and this cannot — which is why a client that finds a daemon
-- already up should still prefer it.

local ffi = require("ffi")
local Json = require("src.json")

-- A copy of the header, and checked against it at load time by
-- `jarvis_abi_version`: these declarations are how this process reads memory
-- the library wrote, so a copy that has drifted is not a stale comment, it is
-- a crash.
ffi.cdef [[
typedef int (*jarvis_event_fn)(int kind, const char *text, size_t len,
                               uint64_t a, uint64_t b, void *user);

uint32_t    jarvis_abi_version(void);
const char *jarvis_last_error(void);
void        jarvis_string_free(char *text);

int   jarvis_agent_open(const char *root, const char *overrides_json);
int   jarvis_agent_is_open(void);
char *jarvis_agent_root(void);
void  jarvis_agent_close(void);
char *jarvis_agent_call(const char *request_json, jarvis_event_fn callback, void *user);
]]

local ABI_VERSION = 2

-- The kinds a turn reports, named as the WebSocket names them, so the screen
-- above does not know which way the chunk came. `reasoning_done` (3) carries
-- nothing a client here draws, and is dropped.
local KIND = { [0] = "prefill", [1] = "reasoning", [2] = "token", [4] = "tool" }

local M = { path = nil, root = nil }

local C = nil
local callback = nil   -- one ffi.cast for the life of the thread, never per call
local onChunk = nil    -- what the call in flight wants told

local function lastError()
  if not C then return "libjarvis is not loaded" end
  local p = C.jarvis_last_error()
  if p == nil then return "the library refused without saying why" end
  return (ffi.string(p):gsub("%s+", " "))
end

--- Take an owned string from the library and free it the way a caller must.
local function owned(ptr)
  if ptr == nil then return nil end
  local text = ffi.string(ptr)
  C.jarvis_string_free(ptr)
  return text
end

--- Load the library and open a space in it. `env` is a table of settings for
--- this backend alone — what the daemon would have been given on its command
--- line. Returns true, or nil and why not.
function M.start(path, root, env)
  if not C then
    local ok, lib = pcall(ffi.load, path)
    if not ok then
      return nil, "cannot load " .. tostring(path) .. ": " .. tostring(lib):gsub("%s+", " ")
    end
    C = lib
    M.path = path
    local abi = tonumber(C.jarvis_abi_version())
    if abi ~= ABI_VERSION then
      C = nil
      return nil, string.format("%s speaks ABI %d, this client speaks %d — run make ffi",
        tostring(path), abi, ABI_VERSION)
    end
    -- One callback, cast once. A cast is a resource the JIT has to keep alive
    -- and there are only so many of them; one per call would leak until the
    -- thread ran out. It reads an upvalue to find the call in flight.
    callback = ffi.cast("jarvis_event_fn", function(kind, text, len, a, b, _user)
      if not onChunk then return 0 end
      local name = KIND[tonumber(kind)]
      if not name then return 0 end
      local body = ""
      if text ~= nil and tonumber(len) > 0 then body = ffi.string(text, tonumber(len)) end
      -- A callback that throws cannot unwind through Rust, so anything this
      -- raises is caught here and the turn is allowed to finish.
      local ok, stop = pcall(onChunk, name, body, tonumber(a), tonumber(b))
      if ok and stop then return 1 end
      return 0
    end)
  end

  if M.root == root and C.jarvis_agent_is_open() ~= 0 then return true end

  -- The space is passed as an argument, so it is not also an override; the
  -- library refuses a key that is not a variable name, and so does this.
  local overrides, any = {}, false
  for key, value in pairs(env or {}) do
    if type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$") and key ~= "JARVIS_HOME" then
      overrides[key] = tostring(value)
      any = true
    end
  end
  overrides = any and Json.encode(overrides) or nil

  if C.jarvis_agent_open(root, overrides) ~= 0 then
    return nil, "cannot open " .. tostring(root) .. ": " .. lastError()
  end
  M.root = root
  return true
end

--- One request. `stream(kind, text, a, b)` is optional and fires on this
--- thread as a turn is written; return true from it to stop the turn.
---
--- Returns the reply as JSON text, or nil and why not. A refusal by the
--- backend is a reply — `{"ok":false,…}` — not an error here, exactly as it is
--- over a socket.
function M.call(request, stream)
  if not C then return nil, "libjarvis is not loaded" end
  onChunk = stream
  local ok, reply = pcall(function()
    return owned(C.jarvis_agent_call(request, stream and callback or nil, nil))
  end)
  onChunk = nil
  if not ok then return nil, tostring(reply):gsub("%s+", " ") end
  if not reply then return nil, lastError() end
  return reply
end

--- Close the space, and let go of whatever the model was holding.
function M.stop()
  if C and M.root then
    pcall(function() C.jarvis_agent_close() end)
    M.root = nil
  end
end

return M
