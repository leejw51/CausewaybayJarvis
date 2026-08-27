--- Lua bindings for Causewaybay Jarvis.
--
--     local jarvis = require("jarvis")
--     local session = assert(jarvis.open("qwen3.8:27b-mlx"))
--     session:set_system("You are Jarvis.")
--     local reply = assert(session:send("why is the sky blue?", jarvis.params(),
--       function(kind, text) if kind == "token" then io.write(text) end end))
--     print(reply.stats.decode_tps)
--
-- Everything that can fail returns `nil, message` in the Lua way rather than
-- raising, because a chat loop wants to print the problem and carry on. The
-- one exception is a mistake in the binding itself — a wrong argument type, a
-- handle used after `:close()` — which raises.
--
-- Handles are garbage-collected: a session that goes out of scope frees the
-- weights it holds. `:close()` does it now instead of eventually, which for a
-- 15 GiB model is usually what you want.

local ffi = require("ffi")
local lib = require("jarvis.ffi")
local json = require("jarvis.json")

local C = lib.C

local M = {
  ffi = lib,
  json = json,
  library = lib.path,
  abi_version = lib.abi_version,
}

--- The reason the last call failed, or a fallback if the library kept quiet.
local function why(context)
  local message = C.jarvis_last_error()
  if message ~= nil then return context .. ": " .. ffi.string(message) end
  return context
end

--- Take ownership of a string the library allocated.
local function take(pointer)
  if pointer == nil then return nil end
  local text = ffi.string(pointer)
  C.jarvis_string_free(pointer)
  return text
end

local function take_json(pointer)
  local text = take(pointer)
  if not text then return nil end
  return json.decode(text)
end

function M.version() return ffi.string(C.jarvis_version()) end

--- Seconds from a fixed point. Lua's own clock counts CPU time, which is not
--- what "how long did that take" means when the answer is mostly GPU.
function M.now() return C.jarvis_monotonic() end

function M.memory()
  return {
    active = tonumber(C.jarvis_memory_active()),
    peak = tonumber(C.jarvis_memory_peak()),
  }
end

M.interrupt = {
  --- Take over Ctrl-C so a long answer can be stopped without killing the
  --- process. The handler only sets a flag; poll it from an event handler.
  install = function() return C.jarvis_interrupt_install() == 0 end,
  raised = function() return C.jarvis_interrupt_raised() ~= 0 end,
  clear = function() C.jarvis_interrupt_clear() end,
}

-- ------------------------------------------------------------ parameters ---

--- A fresh parameter block, holding the compiled-in defaults.
function M.params()
  local params = ffi.new("JarvisParams")
  if C.jarvis_params_default(params) ~= 0 then error(why("parameters"), 0) end
  return params
end

--- Read `reasoning_effort` out of a parameter block.
---
--- Bounded by the size of the field rather than by a NUL: the library accepts a
--- buffer filled to the brim, and a params block written by C — or by an
--- `ffi.copy` of exactly 16 bytes — has no terminator for `ffi.string` to find.
function M.effort(params)
  local field = params.reasoning_effort
  return (ffi.string(field, ffi.sizeof(field)):match("^[^%z]*"))
end

--- Write it. Anything but low, medium or xhigh is refused by the next turn.
function M.set_effort(params, effort)
  effort = tostring(effort)
  ffi.fill(params.reasoning_effort, ffi.sizeof(params.reasoning_effort), 0)
  ffi.copy(params.reasoning_effort, effort, math.min(#effort, 15))
end

--- The library's own copy, so a caller can pass params around by value.
function M.copy_params(params)
  local out = ffi.new("JarvisParams")
  ffi.copy(out, params, ffi.sizeof("JarvisParams"))
  return out
end

-- ---------------------------------------------------------------- config ---

local Config = {}
Config.__index = Config

--- Load `config.jsonl`, or discover it when `path` is nil.
function M.config(path)
  local handle = C.jarvis_config_open(path)
  if handle == nil then return nil, why("config") end
  return setmetatable({ handle = ffi.gc(handle, C.jarvis_config_free) }, Config)
end

local function alive(object, kind)
  if not object.handle then error("this " .. kind .. " has been closed", 3) end
  return object.handle
end

--- Where it was read from, or nil for the defaults compiled into the library.
function Config:source() return take(C.jarvis_config_source(alive(self, "config"))) end

--- One key, decoded. nil when the key is absent.
function Config:get(key) return take_json(C.jarvis_config_get_json(alive(self, "config"), key)) end

function Config:system_prompt()
  return take(C.jarvis_config_system_prompt(alive(self, "config")))
end

--- `{alias, repo, revision, app = {name, version}}`.
function Config:model() return take_json(C.jarvis_config_model_json(alive(self, "config"))) end

--- The `generation` and `thinking` settings as a parameter block.
function Config:params()
  local params = ffi.new("JarvisParams")
  if C.jarvis_config_params(alive(self, "config"), params) ~= 0 then
    return nil, why("parameters")
  end
  return params
end

function Config:close()
  if self.handle then
    C.jarvis_config_free(ffi.gc(self.handle, nil))
    self.handle = nil
  end
end

-- ---------------------------------------------------------------- models ---

--- The aliases this build knows: `{{alias = …, repo = …}, …}`.
function M.models() return take_json(C.jarvis_models_json()) end

--- Everything about one model, including what the checkpoint says about itself
--- once it is on disk. `revision` and `repo` may be nil; `repo` overrides the
--- alias.
function M.model_info(alias, revision, repo)
  local info = take_json(C.jarvis_model_info_json(alias, revision, repo))
  if not info then return nil, why("model") end
  return info
end

--- true, false, or nil when the model could not even be resolved.
function M.is_local(alias, revision, repo)
  local status = C.jarvis_model_is_local(alias, revision, repo)
  if status < 0 then return nil, why("model") end
  return status == 1
end

function M.has_hf_token() return C.jarvis_has_hf_token() ~= 0 end

local function progress_table(progress)
  local total = tonumber(progress.bytes_total)
  return {
    files_total = tonumber(progress.files_total),
    files_done = tonumber(progress.files_done),
    bytes_total = total,
    bytes_done = tonumber(progress.bytes_done),
    fraction = total > 0 and tonumber(progress.bytes_done) / total or 0,
    current = ffi.string(progress.current),
    finished = progress.finished ~= 0,
  }
end

--- Download a checkpoint, blocking until it is here.
---
--- The download runs on its own thread and is polled from this one: the Hub
--- client reports from several threads at once, and a LuaJIT callback entered
--- from a thread it knows nothing about is undefined behaviour. `on_progress`
--- is therefore called from here, between polls, and is safe.
function M.pull(alias, revision, repo, on_progress)
  local handle = C.jarvis_pull_start(alias, revision, repo)
  if handle == nil then return nil, why("download") end

  local snapshot = ffi.new("JarvisProgress")
  while true do
    local status = C.jarvis_pull_poll(handle, snapshot)
    if status ~= 1 then
      local message = status < 0 and why("downloading " .. tostring(alias)) or nil
      C.jarvis_pull_free(handle)
      if message then return nil, message end
      if on_progress then
        snapshot.finished = 1
        on_progress(progress_table(snapshot))
      end
      return true
    end
    if on_progress then on_progress(progress_table(snapshot)) end
    lib.sleep(0.1)
  end
end

-- --------------------------------------------------------------- session ---

local KIND = { [0] = "prefill", [1] = "reasoning", [2] = "token", [3] = "reasoning_done" }

local Session = {}
Session.__index = Session

--- Open a session on a checkpoint that is already on disk. Call `M.pull` first
--- when `M.is_local` says it is not.
function M.open(alias, revision, repo)
  local handle = C.jarvis_open(alias, revision, repo)
  if handle == nil then return nil, why("opening " .. tostring(alias)) end
  return setmetatable({ handle = ffi.gc(handle, C.jarvis_close) }, Session)
end

function Session:close()
  -- Not from inside an event handler: the turn still running holds the
  -- session, so the library would refuse to free it and this would forget the
  -- handle anyway — leaking fifteen gigabytes of weights until the process
  -- ends. Raised rather than returned, because it is a mistake in the caller.
  if self.busy then
    error("a session cannot be closed from inside its own event handler", 2)
  end
  if self.handle then
    C.jarvis_close(ffi.gc(self.handle, nil))
    self.handle = nil
  end
end

function Session:info() return take_json(C.jarvis_info_json(alive(self, "session"))) end

--- The result of the last turn, or nil before the first one.
function Session:last() return take_json(C.jarvis_last_json(alive(self, "session"))) end

--- The transcript, decoded.
function Session:messages() return json.decode(self:messages_json()) end

--- The transcript as it stands, ready to be written to a file.
function Session:messages_json()
  return take(C.jarvis_messages_json(alive(self, "session")))
end

--- Replace the transcript with one saved earlier.
function Session:load(text)
  if C.jarvis_messages_load(alive(self, "session"), text) ~= 0 then
    return nil, why("loading the transcript")
  end
  return true
end

--- Replace the system prompt. nil removes it. Costs the cache either way.
function Session:set_system(text)
  if C.jarvis_set_system(alive(self, "session"), text) ~= 0 then
    return nil, why("system prompt")
  end
  return true
end

--- Forget the conversation, keeping the system prompt.
function Session:reset()
  if C.jarvis_reset(alive(self, "session")) ~= 0 then return nil, why("reset") end
  return true
end

function Session:cached_tokens() return tonumber(C.jarvis_cached_tokens(alive(self, "session"))) end

function Session:cache_bytes() return tonumber(C.jarvis_cache_bytes(alive(self, "session"))) end

--- How many tokens some text becomes, under this model's tokenizer.
function Session:count_tokens(text)
  local n = tonumber(C.jarvis_count_tokens(alive(self, "session"), text))
  if n < 0 then return nil, why("tokenizing") end
  return n
end

--- Cut `text` down to at most `n` tokens, on a token boundary.
function Session:truncate(text, n)
  local out = take(C.jarvis_truncate(alive(self, "session"), text, n))
  if not out then return nil, why("truncating") end
  return out
end

--- The exact string the model would see, with `text` appended as a user turn.
function Session:render(text, params)
  local prompt = take(C.jarvis_render(alive(self, "session"), text, params or M.params()))
  if not prompt then return nil, why("rendering the prompt") end
  return prompt
end

--- Bridge a Lua handler into the C callback the library expects.
---
--- An error raised inside a callback would have to unwind through Rust and
--- back into Lua, which is not something either side supports. So the handler
--- runs under pcall: a failure stops the turn cleanly and is re-raised here,
--- on this side of the boundary.
local function run(entry, session, argument, params, handler)
  local handle = alive(session, "session")
  local failure
  local callback

  if handler then
    callback = ffi.cast("JarvisEventFn", function(kind, text, len, a, b)
      local ok, stop = pcall(handler, KIND[kind], text ~= nil and ffi.string(text, len) or nil,
        tonumber(a), tonumber(b))
      if not ok then
        failure = stop
        return 1
      end
      return stop and 1 or 0
    end)
  end

  -- A cast callback holds a slot in a small fixed table, so it is freed
  -- however the call goes: an argument LuaJIT cannot convert raises from
  -- `entry` itself, and leaking a slot per mistake would eventually make every
  -- further cast fail with an error about something else entirely.
  session.busy = true
  local ok, status = pcall(entry, handle, argument, params or M.params(), callback, nil)
  session.busy = false
  if callback then callback:free() end
  if not ok then error(status, 0) end
  if failure then error(failure, 0) end
  if status ~= 0 then return nil, why("generating") end
  return session:last()
end

--- Take a turn: append `text`, stream the answer, keep the reply.
---
--- `handler(kind, text, a, b)` is called for every event — `"prefill"` with
--- `a` of `b` tokens read, `"reasoning"` and `"token"` with a chunk of text,
--- `"reasoning_done"` when `</think>` closes. Return true from it to stop
--- generating; the reply is then whatever had arrived, and its `stop_reason`
--- is `"interrupted"`.
---
--- Returns the completion: `{text, reasoning, stop_reason, stats = {…}}`.
function Session:send(text, params, handler)
  return run(C.jarvis_send, self, text, params, handler)
end

--- Run a raw, already-templated prompt without touching the transcript. Shares
--- the conversation's cache, and so invalidates it.
function Session:generate(prompt, params, handler)
  return run(C.jarvis_generate, self, prompt, params, handler)
end

return M
