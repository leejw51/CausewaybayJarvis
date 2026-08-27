-- The model, on its own thread.
--
-- `jarvis_send` blocks for as long as an answer takes, and the token callback
-- fires from inside it, so nothing about the C ABI can live on a thread that
-- also has sixty frames a second to draw. It lives here instead, and talks to
-- the game through three channels:
--
--   jarvis.cmd    main → here    {op = "open"|"send"|"reset"|"system"|"quit"}
--   jarvis.evt    here → main    {ev = "ready"|"token"|"done"|"error"|…}
--   jarvis.stop   main → here    anything at all means "stop this turn"
--
-- The stop channel is polled from inside the token callback, which is the same
-- trick `lua/chat.lua` plays with SIGINT: a callback that has to return to Rust
-- cannot do anything more complicated than set a flag and get out of the way.
--
-- When the weights are missing -- or when JARVIS_DEMO is set -- everything below
-- runs against a canned generator instead, at a plausible number of tokens per
-- second. The client is then a toy, and says so, but every effect in it works.

require("love.thread")
require("love.timer")
require("love.system")

local lua_dir, model_alias, want_demo, want_download = ...

-- The Lua client lives outside the game directory, so it is reached by
-- absolute path. Both mechanisms are installed: the search path, and a loader
-- that reads the checkout with `loadfile` — whichever of the two a given LÖVE
-- build leaves working, the bindings are found.
package.path = lua_dir .. "/?.lua;" .. lua_dir .. "/?/init.lua;" .. package.path

package.loaders[#package.loaders + 1] = function(name)
  local base = lua_dir .. "/" .. name:gsub("%.", "/")
  for _, candidate in ipairs({ base .. ".lua", base .. "/init.lua" }) do
    local chunk = loadfile(candidate)
    if chunk then return chunk end
  end
  return "\n\tno file '" .. base .. ".lua'"
end

local cmd = love.thread.getChannel("jarvis.cmd")
local evt = love.thread.getChannel("jarvis.evt")
local stop = love.thread.getChannel("jarvis.stop")

local function emit(event) evt:push(event) end

local function drain_stop()
  while stop:pop() ~= nil do end
end

local function stop_requested()
  if stop:peek() ~= nil then
    drain_stop()
    return true
  end
  return false
end

-- ------------------------------------------------------------- demo mode ---

--- Enough of a model to exercise every effect: a think block, an answer, a
--- token rate, a stop reason and some statistics that are lies.
local ANSWERS = {
  {
    words = { "prague", "klementinum", "castle", "vltava", "bridge", "library", "hall", "where" },
    think = "The user is asking about the setting. The plates behind this window are the Klementinum library hall and Hradcany across the river; I should answer about the place rather than about the picture.",
    text = "The Klementinum is a Jesuit college the size of a small town, wedged into the Old Town beside the bridge. Its Baroque library hall has not been reshelved since 1722 -- the books stand where they were put, under a ceiling of allegorical frescoes and a row of brass astronomical globes.\n\nUp its astronomical tower, noon was declared for the whole city by a man with a telescope and a flag. Prague kept that time until the railways insisted on something duller.",
  },
  {
    words = { "harness", "agent", "module", "armour", "armor", "suit", "socket", "plate" },
    think = "They are asking about the ring of sockets. I should be honest: the modules are declared but not wired.",
    text = "The ring around me is the harness. Each socket is a module -- memory, tools, a retriever, a planner, a critic, a sandbox, an eye, a voice -- and each one is registered with the hooks a turn fires: on_turn_start, on_token, on_turn_end.\n\nNone of them are wired to anything yet. What you are watching is the shape of the thing: bolt one on and the plate flies in, seats, and lights up, and the hook it registered is called at exactly the point where the real work would go.",
  },
  {
    words = { "who", "you", "jarvis", "yourself", "model", "name" },
    think = "Introduce myself without overclaiming. In demo mode I am not the model at all.",
    text = "I am the front end. The model itself is Qwen3.8-27B in four-bit, ported to Rust and run on Apple MLX -- but not right now: the weights are not on this machine, so what is answering you is a canned script with a good sense of timing.\n\nRun `make model`, then start me again, and the same window will be driving twenty-seven billion parameters on your GPU instead.",
  },
  {
    words = {},   -- the one that always matches
    think = "No canned answer matches. Say something in character, briefly, and do not pretend to know.",
    text = "In demo mode I have nothing to think with -- these are recorded words at a plausible speed, so that the animation, the particles and the sound can be judged without fifteen gigabytes on disk.\n\nAsk me about Prague, or about the harness, and I have something rehearsed. Otherwise: `make model`, and then ask me properly.",
  },
}

--- Pick a reply by keyword. Plain `find`, not a pattern: Lua has no
--- alternation, and the version of this that used `|` matched nothing at all
--- and fell through to the apology every time.
local function canned(prompt)
  local lower = (prompt or ""):lower()
  for _, answer in ipairs(ANSWERS) do
    if #answer.words == 0 then return answer end
    for _, word in ipairs(answer.words) do
      if lower:find(word, 1, true) then return answer end
    end
  end
  return ANSWERS[#ANSWERS]
end

--- Stream a string as if it were being decoded, in chunks the size a
--- tokenizer would produce, at `tps` tokens a second.
local function stream(kind, body, tps, budget)
  local tokens = 0
  for chunk in body:gmatch("%s*[^%s]+") do
    if stop_requested() then return tokens, true end
    if budget and tokens >= budget then return tokens, false, true end
    emit({ ev = kind, text = chunk })
    tokens = tokens + 1
    love.timer.sleep(1 / tps)
  end
  return tokens, false
end

local function demo_turn(prompt, params)
  local answer = canned(prompt)
  local started = love.timer.getTime()

  local prompt_tokens = math.max(8, math.floor(#prompt / 3.6) + 24)
  for i = 1, 12 do
    emit({ ev = "prefill", done = math.floor(prompt_tokens * i / 12), total = prompt_tokens })
    love.timer.sleep(0.02)
  end
  local prefill_seconds = love.timer.getTime() - started

  local interrupted, capped = false, false
  local reasoning_tokens = 0
  if params.enable_thinking then
    reasoning_tokens, interrupted = stream("reasoning", answer.think, 26)
    emit({ ev = "reasoning_done" })
  end

  local decode_started = love.timer.getTime()
  local generated = 0
  if not interrupted then
    generated, interrupted, capped = stream("token", answer.text, 17.5, params.max_tokens)
  end
  local decode_seconds = math.max(love.timer.getTime() - decode_started, 1e-6)

  emit({
    ev = "done",
    text = answer.text,
    reasoning = params.enable_thinking and answer.think or nil,
    stop_reason = interrupted and "interrupted" or capped and "max_tokens" or "end_of_turn",
    stats = {
      prompt_tokens = prompt_tokens,
      cached_prompt_tokens = math.floor(prompt_tokens * 0.6),
      prefill_tokens = math.floor(prompt_tokens * 0.4),
      generated_tokens = generated,
      reasoning_tokens = reasoning_tokens,
      prefill_seconds = prefill_seconds,
      decode_seconds = decode_seconds,
      prefill_tps = math.floor(prompt_tokens * 0.4) / math.max(prefill_seconds, 1e-6),
      decode_tps = generated / decode_seconds,
      peak_memory = 0,
    },
    demo = true,
  })
end

-- ------------------------------------------------------------- the model ---

local jarvis, session, params_of

local function open_model(alias)
  local ok, lib = pcall(require, "jarvis")
  if not ok then
    -- Say where it looked: the usual cause is a checkout laid out differently
    -- from the one this file assumes, and the path is the whole diagnosis.
    return nil, "no bindings under " .. tostring(lua_dir) .. " -- " ..
      tostring(lib):gsub("\n.*", "")
  end
  jarvis = lib

  -- Fetch the weights if they are not here. `jarvis.pull` runs the download on
  -- its own thread inside the library and reports from this one between polls,
  -- so the progress arriving here is safe to forward -- and when the weights
  -- are already on disk none of this happens at all and the boot goes straight
  -- through, which is why the bar can be honest about being instant.
  if jarvis.is_local(alias) == false then
    -- Where the bytes are going, worked out the way `rustcore::hub` works it
    -- out: HF_HOME, else the standard cache under the home directory. Fifteen
    -- gigabytes should say where they are landing before they land.
    local info = jarvis.model_info(alias) or {}
    local repo = tostring(info.repo or alias)
    local root = os.getenv("HF_HOME")
      or ((os.getenv("HOME") or ".") .. "/.cache/huggingface")
    emit({
      ev = "download_start",
      model = tostring(alias),
      repo = repo,
      dest = root .. "/hub/models--" .. repo:gsub("/", "--"),
    })
    local pulled, why = jarvis.pull(alias, nil, nil, function(p)
      emit({
        ev = "download",
        fraction = p.fraction,
        done = p.bytes_done,
        total = p.bytes_total,
        files_done = p.files_done,
        files_total = p.files_total,
        file = p.current,
        finished = p.finished,
      })
    end)
    if not pulled then return nil, "download: " .. tostring(why) end
    emit({ ev = "download_done" })
  end

  emit({ ev = "status", text = "MOUNTING WEIGHTS" })
  do
    local info = jarvis.model_info(alias) or {}
    local repo = tostring(info.repo or alias)
    local root = os.getenv("HF_HOME")
      or ((os.getenv("HOME") or ".") .. "/.cache/huggingface")
    emit({ ev = "where", repo = repo,
           path = root .. "/hub/models--" .. repo:gsub("/", "--") })
  end
  local opened, why = jarvis.open(alias)
  if not opened then return nil, why end
  return opened
end

--- Turn the plain table the game sends into the C parameter block.
function params_of(settings)
  local params = jarvis.params()
  settings = settings or {}
  if settings.temperature then params.temperature = settings.temperature end
  if settings.max_tokens then params.max_tokens = settings.max_tokens end
  if settings.top_p then params.top_p = settings.top_p end
  if settings.seed then
    params.seed = settings.seed
    params.has_seed = 1
  end
  params.enable_thinking = settings.enable_thinking and 1 or 0
  if settings.effort then jarvis.set_effort(params, settings.effort) end
  return params
end

local function real_turn(prompt, settings)
  local params = params_of(settings)
  local reply, why = session:send(prompt, params, function(kind, chunk, a, b)
    if kind == "prefill" then
      emit({ ev = "prefill", done = tonumber(a), total = tonumber(b) })
    elseif kind == "reasoning" then
      emit({ ev = "reasoning", text = chunk })
    elseif kind == "reasoning_done" then
      emit({ ev = "reasoning_done" })
    elseif kind == "token" then
      emit({ ev = "token", text = chunk })
    end
    return stop_requested()
  end)

  if not reply then
    emit({ ev = "error", text = why or "the turn failed" })
    return
  end

  emit({
    ev = "done",
    text = reply.text,
    reasoning = reply.reasoning,
    stop_reason = reply.stop_reason,
    stats = reply.stats,
    cached = session:cached_tokens(),
    cache_bytes = session:cache_bytes(),
    memory = jarvis.memory(),
  })
end

-- ----------------------------------------------------------------- the loop

--- The recorded model can play a download too, for building the screen that
--- shows one against. `--download` asks for it; without it demo mode starts
--- the way a machine with the weights already on disk does, which is at once.
local function demo_download()
  local total = 15.1 * 1024 * 1024 * 1024
  local files = { "config.json", "tokenizer.json", "model-00001-of-00004.safetensors",
                  "model-00002-of-00004.safetensors", "model-00003-of-00004.safetensors",
                  "model-00004-of-00004.safetensors" }
  emit({
    ev = "download_start",
    model = tostring(model_alias),
    repo = "mlx-community/Qwen3.8-27B-4bit",
    dest = (os.getenv("HF_HOME") or ((os.getenv("HOME") or ".") .. "/.cache/huggingface"))
      .. "/hub/models--mlx-community--Qwen3.8-27B-4bit",
  })
  for step = 0, 240 do
    local fraction = step / 240
    emit({
      ev = "download",
      fraction = fraction,
      done = total * fraction,
      total = total,
      files_done = math.min(#files, math.floor(fraction * #files) + 1),
      files_total = #files,
      file = files[math.min(#files, math.floor(fraction * #files) + 1)],
      finished = step == 240,
    })
    love.timer.sleep(0.05)
  end
  emit({ ev = "download_done" })
end

local demo = want_demo and true or false

if not demo then
  local opened, why = open_model(model_alias)
  if opened then
    session = opened
    local info = session:info()
    emit({ ev = "ready", demo = false, info = info, library = jarvis.library,
           version = jarvis.version() })
  else
    demo = true
    emit({ ev = "fallback", text = why })
  end
end

if demo then
  -- Even the recorded model says where the real one would live, so the
  -- settings page has something true to show.
  emit({ ev = "where", repo = "mlx-community/Qwen3.8-27B-4bit",
         path = (os.getenv("HF_HOME") or ((os.getenv("HOME") or ".") .. "/.cache/huggingface"))
           .. "/hub/models--mlx-community--Qwen3.8-27B-4bit" })
  if want_download then demo_download() end
  emit({ ev = "status", text = "MOUNTING WEIGHTS" })
  love.timer.sleep(0.6)
  emit({ ev = "ready", demo = true, info = {
    alias = model_alias, model = "demo", architecture = "recorded",
    quantization = "none", parameters = 0, context_length = 0,
    weight_bytes = 0, vocabulary = 0, cache_bytes = 0, cached_tokens = 0, messages = 0,
  } })
end

local running = true
while running do
  local message = cmd:demand()
  local op = message.op

  if op == "quit" then
    running = false
  elseif op == "send" then
    drain_stop()
    emit({ ev = "turn_start" })
    if demo then
      demo_turn(message.text, message.params or {})
    else
      local ok, err = pcall(real_turn, message.text, message.params)
      if not ok then emit({ ev = "error", text = tostring(err) }) end
    end
  elseif op == "reset" then
    if session then session:reset() end
    emit({ ev = "reset" })
  elseif op == "system" then
    if session then session:set_system(message.text) end
    emit({ ev = "system", text = message.text })
  elseif op == "weights" then
    -- How much room the checkpoint is taking. `du` rather than walking the
    -- tree in Lua: the cache is a few files but they are fifteen gigabytes of
    -- them, and the shell already knows how to add up.
    local path = tostring(message.path or "")
    local bytes = 0
    local pipe = path ~= "" and io.popen("du -sk '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
    if pipe then
      local out = pipe:read("*a") or ""
      pipe:close()
      bytes = (tonumber(out:match("^(%d+)")) or 0) * 1024
    end
    emit({ ev = "weights_size", path = path, bytes = bytes })

  elseif op == "clear" then
    -- Delete the checkpoint. Guarded twice: the path has to be the one this
    -- worker computed for *this* model, and it has to look like a Hugging Face
    -- cache entry. `rm -rf` on a path that came in over a channel is not
    -- something to be casual about.
    local target = tostring(message.path or "")
    local ok = target:find("/hub/models%-%-") ~= nil and #target > 20
      and target:find("%.%.") == nil
    if not ok then
      emit({ ev = "cleared", ok = false, text = "refused: " .. target })
    else
      local removed = os.execute("rm -rf '" .. target:gsub("'", "'\\''") .. "'")
      emit({ ev = "cleared", ok = removed == true or removed == 0, path = target })
    end

  elseif op == "info" then
    if session then
      emit({ ev = "info", info = session:info(), memory = jarvis.memory() })
    end
  end
end

if session then session:close() end
emit({ ev = "closed" })
