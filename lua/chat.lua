#!/usr/bin/env luajit
--- `jarvis-chat` — the Lua front end for Causewaybay Jarvis.
---
--- A conversation goes to the server: `chat` and `run` reach `agentd` — the
--- one process that holds the model — over HTTP, and read the answer back
--- as server-sent events (see `jarvis/client.lua`). This program loads no
--- weights for a turn, and needs no library: LuaJIT and `curl`. Run it with
--- `luajit lua/chat.lua`, or `make lua-chat`.
---
---     lua/chat.lua                       the chat REPL (the default)
---     lua/chat.lua run "why is the sky blue?"
---     echo "summarise this" | lua/chat.lua run
---     lua/chat.lua pull | info | models | bench    (these drive the engine here, on libjarvis)

local SOURCE = debug.getinfo(1, "S").source:sub(2)
local here = SOURCE:match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local client = require("jarvis.client")
local json = require("jarvis.json")
local ui = require("jarvis.ui")

--- The C ABI, for the model-management commands only — `pull`, `info`,
--- `models`, `bench` — and only when one of them runs, so a chat needs no
--- library built.
local function engine()
  local ok, jarvis = pcall(require, "jarvis")
  if not ok then die("this command drives the engine here and needs libjarvis: run `make ffi` (" .. tostring(jarvis) .. ")") end
  return jarvis
end

local EFFORTS = { low = true, medium = true, xhigh = true }

local USAGE = [[
Causewaybay Jarvis — an on-device AI agent on Apple MLX

usage: chat.lua [options] [command]

commands:
  chat                  interactive chat (the default)
  run [prompt…]         answer one prompt and exit; reads stdin when given none
  pull                  download the model without starting a chat
  info                  what is configured and what is on disk
  models                the model aliases this build knows
  bench                 measure prefill and decode throughput

options:
  -m, --model ALIAS     model alias or Hugging Face repo
      --config PATH     path to config.jsonl
  -s, --system TEXT     system prompt, overriding config.jsonl
      --think           let the model reason in a <think> block first
      --no-think        answer immediately, with no reasoning block
      --effort LEVEL    reasoning effort: low, medium or xhigh
  -t, --temp N          sampling temperature (0 is greedy)
      --max-tokens N    cap on generated tokens
      --seed N          seed the sampler for a reproducible answer
      --hide-thinking   do not show the reasoning stream
      --prompt N        bench only: synthetic prompt length, in tokens
      --tokens N        bench only: tokens to generate
  -h, --help            this message
]]

--- Give up on the command line. Raised rather than exited so that `main` owns
--- the one place this program writes an error and stops — which also lets the
--- tests drive argument parsing without taking the process down with them.
local function die(message)
  error({ usage = message }, 0)
end

-- ------------------------------------------------------------- arguments ---

local function parse(argv)
  local opts, rest, i = {}, {}, 1
  local function value(name)
    i = i + 1
    return argv[i] or die("`" .. name .. "` needs a value")
  end
  local function number(name)
    local text = value(name)
    return tonumber(text) or die("`" .. name .. "` wants a number, got `" .. text .. "`")
  end
  --- A count of tokens. Whole and at least one: these end up in a `uint32_t`,
  --- where a negative turns into four billion and a zero into a turn that
  --- generates nothing and then reports that it ran out of room.
  local function count(name)
    local n = number(name)
    if n < 1 or n ~= math.floor(n) then
      die("`" .. name .. "` wants a whole number of at least 1, got `" .. tostring(n) .. "`")
    end
    return n
  end

  while i <= #argv do
    local arg = argv[i]
    if arg == "--" then
      for j = i + 1, #argv do rest[#rest + 1] = argv[j] end
      break
    elseif arg == "-m" or arg == "--model" then opts.model = value(arg)
    elseif arg == "--config" then opts.config = value(arg)
    elseif arg == "-s" or arg == "--system" then opts.system = value(arg)
    elseif arg == "--think" then opts.think = true
    elseif arg == "--no-think" then opts.think = false
    elseif arg == "--effort" then opts.effort = value(arg)
    elseif arg == "-t" or arg == "--temp" or arg == "--temperature" then
      opts.temperature = number(arg)
    elseif arg == "--max-tokens" or arg == "--max" then opts.max_tokens = count(arg)
    elseif arg == "--seed" then opts.seed = number(arg)
    elseif arg == "--hide-thinking" then opts.hide_thinking = true
    elseif arg == "--prompt" then opts.prompt_tokens = count(arg)
    elseif arg == "--tokens" then opts.tokens = count(arg)
    elseif arg == "-h" or arg == "--help" then io.write(USAGE) os.exit(0)
    elseif arg == "--version" then print(engine().version()) os.exit(0)
    elseif arg:match("^%-.") then die("unknown option `" .. arg .. "` — try --help")
    else rest[#rest + 1] = arg end
    i = i + 1
  end
  return opts, rest
end

-- ---------------------------------------------------------------- config ---

--- `config.jsonl`, read here: one JSON object per line, `{"key": …,
--- "value": …}`. The same shape the Rust side reads, with the same three
--- questions asked of it — the model, the generation defaults, the system
--- prompt — so the two front ends start from the same place. Found beside
--- the workspace (this file is `lua/chat.lua` in the checkout) unless a path
--- is given.
local Config = {}
Config.__index = Config

local function loadConfig(path)
  path = path or (here .. "/../config.jsonl")
  local f = io.open(path, "rb")
  if not f then return nil, "cannot read config.jsonl at " .. path end
  local values = {}
  for line in f:lines() do
    if line:match("%S") then
      local rec = json.decode(line)
      if type(rec) == "table" and rec.key then values[rec.key] = rec.value end
    end
  end
  f:close()
  return setmetatable({ path = path, values = values }, Config)
end

function Config:get(key) return self.values[key] end
function Config:source() return self.path end
function Config:model() return self.values.model or {} end
function Config:system_prompt() return self.values.system_prompt end
function Config:close() end

--- Everything a turn needs, from config.jsonl and then the command line.
--- `params` is a plain table — the request's `options` — rather than the
--- engine's struct: the sampler is the server's now.
local function settings(config, opts)
  local gen = (config and config:get("generation")) or {}
  local thinking = (config and config:get("thinking")) or {}
  local params = {
    temperature = gen.temperature or 0.7,
    max_tokens = gen.max_tokens or 2048,
    seed = gen.seed,
    has_seed = gen.seed ~= nil and 1 or 0,
    enable_thinking = thinking.enabled ~= false and 1 or 0,
    effort = thinking.effort or "low",
  }

  if opts.temperature then params.temperature = opts.temperature end
  if opts.max_tokens then params.max_tokens = opts.max_tokens end
  if opts.seed then
    params.seed = opts.seed
    params.has_seed = 1
  end
  if opts.think ~= nil then params.enable_thinking = opts.think and 1 or 0 end
  if opts.effort then params.effort = opts.effort end

  -- Refuse here rather than after a round trip to the server.
  if not EFFORTS[params.effort] then
    die("unexpected reasoning effort `" .. tostring(params.effort) .. "` (want low, medium or xhigh)")
  end

  return {
    params = params,
    system = opts.system or (config and config:system_prompt()),
    show_thinking = thinking.show ~= false and not opts.hide_thinking,
  }
end

--- The request's `options`, from the settings.
local function options(st)
  local p = st.params
  return {
    think = p.enable_thinking ~= 0,
    effort = p.effort,
    temperature = p.temperature,
    max_tokens = p.max_tokens,
    seed = p.has_seed ~= 0 and p.seed or nil,
  }
end

--- The alias, revision and repository to run, from config plus `--model`.
local function target(config, opts)
  local model = config and config:model() or {}
  if opts.model then
    -- An explicit --model overrides the pinned repository too.
    return opts.model, model.revision, nil
  end
  return model.alias or "qwen3.8:27b-mlx", model.revision, model.repo
end

-- --------------------------------------------------------------- loading ---

--- Download the checkpoint unless it is already in the Hugging Face cache.
local function ensure(alias, revision, repo)
  local jarvis = engine()
  local present, e = jarvis.is_local(alias, revision, repo)
  if present == nil then die(e) end
  if present then return end

  local info = jarvis.model_info(alias, revision, repo)
  local size = info and info.approx_gib > 0 and ui.dim(string.format("(~%.0f GiB)", info.approx_gib)) or ""
  print(ui.yellow("pulling") .. " " .. ui.bold(info and info.repo or alias) .. " " .. size)
  if not jarvis.has_hf_token() then
    print(ui.dim("  no HF_TOKEN found — public repositories still work, gated ones do not"))
  end

  local status = ui.status()
  local ok, e2 = jarvis.pull(alias, revision, repo, function(p)
    status:set(string.format("  %s %6.1f%%  %s / %s  %s", ui.bar(p.fraction), p.fraction * 100,
      ui.human_bytes(p.bytes_done), ui.human_bytes(p.bytes_total), p.current))
  end)
  status:clear()
  if not ok then die(e2) end
end

--- Resolve, download if needed, and load onto the GPU — for `bench`, which
--- drives the engine in this process.
local function openEngine(alias, revision, repo)
  local jarvis = engine()
  ensure(alias, revision, repo)
  local status = ui.status()
  status:force("  loading " .. ui.bold(alias) .. "…")
  local started = jarvis.now()
  local session, e = jarvis.open(alias, revision, repo)
  status:clear()
  if not session then die(e) end

  local info = session:info()
  print(string.format("%s %s · %s params · %s · loaded in %.1fs", ui.green("●"),
    ui.bold(info.model), ui.human_count(info.parameters), info.quantization,
    jarvis.now() - started))
  return session
end

--- Connect to the server — starting it when none is running — and open a
--- conversation on it. What `chat` and `run` do instead of loading weights.
local function open(system)
  local status = ui.status()
  status:force("  " .. ui.dim("…") .. " reaching the server")
  local started = client.now()
  local c, e = client.connect()
  status:clear()
  if not c then die(e) end
  local session = c:session(system)
  local info = session:info()
  print(string.format("%s %s · %s%s · %s · %.1fs", ui.green("●"),
    ui.bold(info.model), info.effective,
    info.engine ~= "" and (" (" .. info.engine .. ")") or "",
    ui.dim(info.server), client.now() - started))
  return session
end

-- ------------------------------------------------------------- streaming ---

--- Run one turn, streaming it to stdout the way `rustcli` does: reasoning dim
--- and above the answer, one blank line between them however the model spaced
--- its own output.
local function stream(turn, session, argument, st)
  local status = ui.status()
  local thinking_open, wrote_answer, trailing = false, false, 0

  local function close_thinking()
    if thinking_open then
      io.write(ui.off(), string.rep("\n", math.max(0, 2 - trailing)))
      thinking_open = false
    end
  end

  local completion, e = turn(session, argument, options(st), function(kind, text, done, total)
    if kind == "prefill" then
      status:set(string.format("  %s reading %d/%d tokens", ui.dim("…"), done, total))
    elseif kind == "reasoning" then
      if not st.show_thinking then
        status:set("  " .. ui.dim("thinking…"))
        return
      end
      if not thinking_open then
        status:clear()
        io.write(ui.dim("thinking"), "\n", ui.dim_on())
        thinking_open = true
      end
      io.write(text)
      io.flush()
      trailing = #(text:match("\n*$") or "")
    elseif kind == "reasoning_done" then
      status:clear()
      close_thinking()
    elseif kind == "token" then
      status:clear()
      close_thinking()
      io.write(text)
      io.flush()
      wrote_answer = true
    elseif kind == "tool" then
      status:set("  " .. ui.dim(tostring(text or "")))
    end
  end)

  status:clear()
  if thinking_open then io.write(ui.off()) end
  if wrote_answer or thinking_open then io.write("\n") end
  io.flush()
  return completion, e
end

local function format_stats(completion)
  local s = completion.stats or {}
  local parts = { string.format("%d chunks · %.1fs · %s",
    tonumber(s.chunks) or 0, tonumber(s.seconds) or 0, tostring(completion.model or "?")) }
  if completion.stop_reason == "length" then
    parts[#parts + 1] = "hit max_tokens"
  elseif completion.stop_reason == "interrupted" then
    parts[#parts + 1] = "interrupted"
  end
  return ui.dim("  " .. table.concat(parts, " · "))
end

-- ---------------------------------------------------------------- commands --

local commands = {}

function commands.models()
  local jarvis = engine()
  print(ui.bold("aliases"))
  for _, model in ipairs(jarvis.models()) do
    print(string.format("  %-24s %s", ui.cyan(model.alias), ui.dim(model.repo)))
  end
  print("\nAny Hugging Face `org/name` holding an MLX Qwen3.5 checkpoint also works.")
end

function commands.info(context)
  local jarvis = engine()
  local config = context.config
  local app = config and config:get("app") or {}
  print(ui.bold(app.name or "Causewaybay Jarvis") .. " " .. ui.dim(app.version or ""))
  print(string.format("%-18s %s", "config", (config and config:source()) or "<built in>"))
  print(string.format("%-18s %s", "library", jarvis.library))

  local info, e = jarvis.model_info(context.alias, context.revision, context.repo)
  if not info then die(e) end
  print(string.format("%-18s %s", "alias", info.alias))
  print(string.format("%-18s %s", "repository", info.repo))
  print(string.format("%-18s %s", "revision", info.revision))

  -- `local` is a keyword, so the key has to be reached the long way.
  if not info["local"] then
    print(string.format("%-18s %s", "snapshot", ui.yellow("not downloaded — run `chat.lua pull`")))
    return
  end
  print(string.format("%-18s %s", "snapshot", info.snapshot))
  print(string.format("%-18s %s", "shards", info.shards))
  print(string.format("%-18s %s", "on disk", ui.human_bytes(info.weight_bytes)))

  local m = info.model
  if not m then return end
  print(string.format("%-18s %s", "architecture", m.architectures[1] or "?"))
  print(string.format("%-18s %s", "parameters", ui.human_count(m.parameters)))
  print(string.format("%-18s %d (%d full attention, %d gated DeltaNet)",
    "layers", m.layers, m.full_attention, m.delta_net))
  print(string.format("%-18s %d", "hidden size", m.hidden_size))
  print(string.format("%-18s %d heads / %d kv, head dim %d",
    "attention", m.attention_heads, m.kv_heads, m.head_dim))
  print(string.format("%-18s %d", "context", m.context))
  print(string.format("%-18s %d", "vocabulary", m.vocabulary))
  if m.quantization then
    print(string.format("%-18s %d-bit affine, group %d",
      "quantization", m.quantization.bits, m.quantization.group_size))
  else
    print(string.format("%-18s none", "quantization"))
  end
end

function commands.pull(context)
  local jarvis = engine()
  ensure(context.alias, context.revision, context.repo)
  local info = jarvis.model_info(context.alias, context.revision, context.repo)
  print(string.format("%s %s (%s of weights)", ui.green("ready:"), info.snapshot,
    ui.human_bytes(info.weight_bytes)))
end

function commands.run(context)
  local text = #context.rest > 0 and table.concat(context.rest, " ") or io.read("*a")
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then die("nothing to answer — pass a prompt or pipe one in") end

  local st = context.settings
  local session = open(st.system)

  local completion, e = stream(session.send, session, text, st)
  if not completion then die(e) end
  if completion.stop_reason == "length" then
    io.stderr:write(ui.dim("(stopped at max_tokens)"), "\n")
  end
  session:close()
end

function commands.bench(context)
  local jarvis = engine()
  local session = openEngine(context.alias, context.revision, context.repo)
  local want = context.opts.prompt_tokens or 512
  local tokens = context.opts.tokens or 64

  -- A repetitive filler prompt: only its length matters. Grow it past the
  -- target, then cut it back on a token boundary — a prompt that stops at the
  -- end of a sentence invites the model to answer with nothing but a stop
  -- token, and a benchmark that decodes nothing measures nothing.
  local sentence = "The quick brown fox jumps over the lazy dog. "
  local prompt = sentence
  while assert(session:count_tokens(prompt)) < want + 8 do
    prompt = prompt .. sentence
  end
  prompt = assert(session:truncate(prompt, want))

  local params = jarvis.params()
  params.max_tokens = tokens
  params.temperature = 0

  local status = ui.status()
  local completion, e = session:generate(prompt, params, function(kind, _, done, total)
    if kind == "prefill" then
      status:set(string.format("  prefill %d/%d", done, total))
    else
      status:set("  decoding…")
    end
  end)
  status:clear()
  if not completion then die(e) end

  local s = completion.stats
  print(ui.bold("throughput"))
  print(string.format("  prefill  %7.1f tok/s  (%d tokens in %.2fs)",
    s.prefill_tps, s.prompt_tokens, s.prefill_seconds))
  print(string.format("  decode   %7.1f tok/s  (%d tokens in %.2fs)",
    s.decode_tps, s.generated_tokens, s.decode_seconds))
  print(string.format("  peak     %7s", ui.human_bytes(s.peak_memory)))
  print(string.format("  cache    %7s  for %d tokens",
    ui.human_bytes(session:cache_bytes()), session:cached_tokens()))
  print(string.format("  active   %7s", ui.human_bytes(jarvis.memory().active)))
  session:close()
end

-- -------------------------------------------------------------------- repl --

local HELP = [[
  /help              this list
  /reset             forget the conversation
  /think on|off      reasoning block on or off
  /effort low|medium|xhigh
  /temp <t>          sampling temperature (0 = greedy)
  /max <n>           cap on generated tokens
  /system <text>     replace the system prompt
  /show              show or hide the reasoning stream
  /stats             statistics for the last turn
  /save <path>       write the transcript as JSON
  /load <path>       read one back
  /model             what is loaded
  /exit              quit (Ctrl-D also works)]]

local function on_off(value) return value and "on" or "off" end

--- Handle a `/command`. Returns true to quit, or nil plus a message on error.
local function slash(input, session, st)
  local name, rest = input:match("^(%S+)%s*(.*)$")
  rest = (rest or ""):gsub("%s+$", "")
  local params = st.params

  if name == "help" or name == "?" then
    print(HELP)
  elseif name == "exit" or name == "quit" or name == "q" then
    return true
  elseif name == "reset" then
    assert(session:reset())
    print(ui.dim("  conversation cleared"))
  elseif name == "think" then
    if rest ~= "on" and rest ~= "off" and rest ~= "" then
      return nil, "expected on or off, got `" .. rest .. "`"
    end
    params.enable_thinking = (rest == "off") and 0 or 1
    print(ui.dim("  thinking " .. on_off(params.enable_thinking ~= 0)))
  elseif name == "show" then
    st.show_thinking = not st.show_thinking
    print(ui.dim("  reasoning stream " .. on_off(st.show_thinking)))
  elseif name == "effort" then
    if not EFFORTS[rest] then return nil, "want low, medium or xhigh" end
    params.effort = rest
    print(ui.dim("  reasoning effort " .. rest))
  elseif name == "temp" or name == "temperature" then
    local value = tonumber(rest)
    if not value then return nil, "temperature must be a number" end
    params.temperature = value
    print(ui.dim("  temperature " .. value))
  elseif name == "max" or name == "max_tokens" then
    local value = tonumber(rest)
    if not value or value < 1 then return nil, "max tokens must be a whole number" end
    params.max_tokens = math.floor(value)
    print(ui.dim("  max tokens " .. math.floor(value)))
  elseif name == "system" then
    if rest == "" then return nil, "give the system prompt after /system" end
    local ok, e = session:set_system(rest)
    if not ok then return nil, e end
    st.system = rest
    print(ui.dim("  system prompt replaced"))
  elseif name == "stats" then
    local last = session:last()
    print(last and format_stats(last) or ui.dim("  nothing generated yet"))
  elseif name == "save" then
    if rest == "" then return nil, "give a path after /save" end
    local file, e = io.open(rest, "w")
    if not file then return nil, e end
    file:write(session:messages_json(), "\n")
    file:close()
    print(ui.dim(string.format("  %d messages written to %s", #session:messages(), rest)))
  elseif name == "load" then
    if rest == "" then return nil, "give a path after /load" end
    local file, e = io.open(rest, "r")
    if not file then return nil, e end
    local text = file:read("*a")
    file:close()
    local ok, e2 = session:load(text)
    if not ok then return nil, e2 end
    print(ui.dim(string.format("  %d messages read from %s", #session:messages(), rest)))
  elseif name == "model" then
    local info = session:info()
    print(string.format("  %-14s %s", "model", info.model))
    print(string.format("  %-14s %s", "brain", info.effective .. (info.engine ~= "" and (" (" .. info.engine .. ")") or "")))
    print(string.format("  %-14s %s", "server", info.server))
  else
    return nil, "unknown command `/" .. tostring(name) .. "` — try /help"
  end
  return false
end

function commands.chat(context)
  local st = context.settings
  local session = open(st.system)

  print(ui.bold("Causewaybay Jarvis") .. "  " ..
    ui.dim("/help for commands, Ctrl-D to quit") .. " " .. ui.dim("[lua]"))

  while true do
    io.write(ui.enabled and "\27[36myou ›\27[0m " or "you > ")
    io.flush()
    local line = io.read("*l")

    if line == nil then
      break
    else
      line = line:gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= "" then
        local command = line:match("^/(.*)$")
        if command then
          local quit, e = slash(command, session, st)
          if quit then break end
          if e then print(ui.red("error:") .. " " .. e) end
        else
          local completion, e = stream(session.send, session, line, st)
          if not completion then
            print(ui.red("error:") .. " " .. e)
          else
            if completion.stop_reason == "interrupted" then
              print(ui.dim("  (interrupted)"))
            end
            print("")
          end
        end
      end
    end
  end

  print(ui.dim("bye"))
  session:close()
end

-- ------------------------------------------------------------------- main --

local function main(argv)
  local opts, rest = parse(argv)
  local name = rest[1]
  if name and commands[name] then
    table.remove(rest, 1)
  elseif name then
    die("unknown command `" .. name .. "` — try --help")
  else
    name = "chat"
  end

  local config, e = loadConfig(opts.config)
  if not config then die(e) end

  local alias, revision, repo = target(config, opts)
  commands[name]({
    opts = opts,
    rest = rest,
    config = config,
    alias = alias,
    revision = revision,
    repo = repo,
    settings = settings(config, opts),
  })
end

-- Running the file is the normal case; `require`-ing it is what the tests do,
-- and they want the pieces above rather than a chat session.
local M = {
  usage = USAGE,
  parse = parse,
  settings = settings,
  options = options,
  target = target,
  config = loadConfig,
  format_stats = format_stats,
  slash = slash,
  commands = commands,
}

-- Run, or `require`d? Told apart by whether this file is the one the
-- interpreter was pointed at, rather than by what it is called: it carries a
-- shebang, so copying it onto a PATH under some other name is a normal thing
-- to do, and `package.loaded` is no help — `require` only fills that in once
-- this chunk has returned.
if arg and arg[0] == SOURCE then
  local ok, e = pcall(main, arg)
  if not ok then
    io.stderr:write(ui.red("error:"), " ",
      type(e) == "table" and e.usage or tostring(e), "\n")
    os.exit(1)
  end
end

return M
