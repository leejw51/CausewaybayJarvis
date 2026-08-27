#!/usr/bin/env luajit
--- Tests for the Lua bindings and the C ABI underneath them.
---
---     luajit lua/test.lua          everything that needs no weights
---     JARVIS_TEST_MODEL=1 …        also the checks that load the checkpoint
---
--- Run from `make test`. The model-backed cases skip loudly rather than
--- silently, so a green run never reads as coverage it did not provide.

local here = (debug.getinfo(1, "S").source:sub(2)):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local jarvis = require("jarvis")
local json = require("jarvis.json")
local ui = require("jarvis.ui")

-- ---------------------------------------------------------------- harness --

local cases, failed, skipped = {}, 0, 0

local function test(name, fn) cases[#cases + 1] = { name = name, fn = fn } end

local function skip(why) error({ skip = why }, 0) end

local function eq(actual, expected, what)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      what or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function truthy(value, what)
  if not value then error((what or "value") .. ": expected something truthy", 2) end
  return value
end

local function contains(haystack, needle)
  if not tostring(haystack):find(needle, 1, true) then
    error(string.format("expected `%s` to contain `%s`", tostring(haystack), needle), 2)
  end
end

--- Run something that talks to the user, without its output in the report.
--- Two results, because that is what everything under test returns: a value
--- and a message. Collecting them into a table instead would lose a `nil` in
--- the first slot, which is exactly the case worth testing.
local function quietly(fn, ...)
  local was = print
  _G.print = function() end
  local ok, first, second = pcall(fn, ...)
  _G.print = was
  if not ok then error(first, 0) end
  return first, second
end

--- Assert that `fn` raises, and that the message mentions `needle`.
local function raises(fn, needle)
  local ok, e = pcall(fn)
  if ok then error("expected this to fail, but it did not", 2) end
  if needle then contains(e, needle) end
  return e
end

-- ------------------------------------------------------------------- abi ---

test("the library and the bindings agree on the ABI", function()
  eq(jarvis.abi_version, 1, "abi version")
  truthy(jarvis.version():match("^%d+%.%d+%.%d+$"), "version")
  truthy(jarvis.library, "library path")
end)

test("a struct written here is the size the library reads", function()
  local ffi = require("ffi")
  -- The cdef is a hand copy of the header; this is what catches it drifting.
  eq(ffi.sizeof("JarvisParams"), 64, "JarvisParams")
  eq(ffi.sizeof("JarvisProgress"), 168, "JarvisProgress")
end)

-- ------------------------------------------------------------------ json ---

test("json decodes the shapes this API returns", function()
  local value = json.decode('{"a":[1,2.5,-3e2],"b":{"c":true,"d":false},"e":null}')
  eq(value.a[1], 1, "integer")
  eq(value.a[2], 2.5, "float")
  eq(value.a[3], -300, "exponent")
  eq(value.b.c, true, "true")
  eq(value.b.d, false, "false")
  -- A null is always an absent field here, which is what a missing key means.
  eq(value.e, nil, "null")
end)

test("json unescapes strings, including outside the BMP", function()
  eq(json.decode([["a\"b\\c\/d\n\t"]]), 'a"b\\c/d\n\t', "escapes")
  eq(json.decode([["é"]]), "é", "two-byte code point")
  eq(json.decode([["你好"]]), "你好", "three-byte code points")
  -- A surrogate pair is one character, not two broken halves.
  eq(json.decode([["😀"]]), "😀", "surrogate pair")
end)

test("json refuses malformed input rather than guessing", function()
  raises(function() return json.decode('{"a":1') end, "json")
  raises(function() return json.decode('[1,]') end, "json")
  raises(function() return json.decode('{"a":1} trailing') end, "trailing")
  raises(function() return json.decode("nope") end, "expected a value")
  raises(function() return json.decode(nil) end, "expected a string")
end)

test("json keeps the place of a null inside an array", function()
  -- In an object a null is an absent field, which a missing key says exactly.
  -- In an array it cannot be nil, or everything after it slides down one.
  local value = json.decode('[1,null,2]')
  eq(#value, 3, "length")
  eq(value[1], 1)
  eq(value[2], json.null, "the null itself")
  eq(value[3], 2, "the element after it kept its index")
  eq(json.decode('[null]')[1], json.null, "a lone null")
  eq(json.decode('{"a":null}').a, nil, "but a null field is still absent")
end)

test("json survives an empty container and nesting", function()
  eq(#json.decode("[]"), 0, "empty array")
  eq(next(json.decode("{}")), nil, "empty object")
  eq(json.decode('{"a":{"b":[{"c":7}]}}').a.b[1].c, 7, "nested")
end)

-- -------------------------------------------------------------------- ui ---

test("numbers are formatted the way the Rust front ends format them", function()
  eq(ui.human_bytes(0), "0 B")
  eq(ui.human_bytes(1536), "1.5 KiB")
  eq(ui.human_bytes(16 * 1024 * 1024 * 1024), "16.0 GiB")
  eq(ui.human_count(999), "999")
  eq(ui.human_count(27e9), "27.0B")
  eq(ui.bar(0), "[--------------------]")
  eq(ui.bar(1), "[####################]")
  eq(ui.bar(0.5), "[##########----------]")
  eq(ui.bar(-5), ui.bar(0), "the bar saturates")
  eq(ui.bar(5), ui.bar(1), "at both ends")
end)

test("a status line is erased by as many spaces as it drew", function()
  -- Width is counted in columns, not bytes: the status line carries model
  -- names and a `…`, and a byte count would leave debris on the terminal.
  eq(ui.width("abc"), 3)
  eq(ui.width("…"), 1)
  eq(ui.width("  … reading 10/20 tokens"), 24)

  -- Colour is bytes that occupy no columns. Counting them would have the
  -- status line erase itself with more spaces than it drew, wrap, and then
  -- redraw over the wrong physical row.
  local was = ui.enabled
  ui.enabled = true
  eq(ui.width(ui.dim("abc")), 3, "a colour run is not four extra characters")
  eq(ui.width(ui.bold("…") .. ui.dim("ab")), 3, "several runs")
  ui.enabled = was
end)

test("a status line is never drawn wider than the terminal", function()
  local was = ui.enabled
  ui.enabled = true
  -- A download line ends in a Hugging Face file name, which the library
  -- gives back at up to 127 bytes.
  local line = "  [###-----] 30%  " .. string.rep("x", 200)
  local cut = ui.truncate(line, 80)
  eq(ui.width(cut), 80, "cut to the width, ellipsis and all")
  contains(cut, "[###-----]")

  eq(ui.truncate("short", 80), "short", "a line that fits is left alone")
  -- The escapes are carried across rather than counted or dropped.
  contains(ui.truncate(ui.bold(string.rep("y", 200)), 20), "\27[1m")
  eq(ui.width(ui.truncate(ui.bold(string.rep("y", 200)), 20)), 20)
  ui.enabled = was
end)

test("colour is off when it should be", function()
  local was = ui.enabled
  ui.enabled = false
  eq(ui.dim("hi"), "hi", "no escapes without a terminal")
  eq(ui.dim_on(), "")
  ui.enabled = true
  contains(ui.bold("hi"), "\27[1m")
  ui.enabled = was
end)

-- -------------------------------------------------------------- parameters --

test("parameters start at the shipped defaults", function()
  local params = jarvis.params()
  eq(params.max_tokens, 2048, "max_tokens")
  eq(params.top_k, 20, "top_k")
  eq(params.has_seed, 0, "has_seed")
  eq(jarvis.effort(params), "low", "effort")
  eq(params.preserve_thinking, 1, "preserve_thinking keeps the cache reusable")
end)

test("the effort field is written and read back through a fixed buffer", function()
  local params = jarvis.params()
  jarvis.set_effort(params, "xhigh")
  eq(jarvis.effort(params), "xhigh")
  jarvis.set_effort(params, "low")
  eq(jarvis.effort(params), "low", "the longer value is overwritten, not left behind")
  -- 16 bytes with room for the terminator: anything longer is truncated.
  jarvis.set_effort(params, string.rep("x", 40))
  eq(#jarvis.effort(params), 15, "truncated")

  -- The library accepts a buffer filled to the brim, so reading one must not
  -- go looking for a terminator past the end of the struct. This is the last
  -- field, so what lies beyond it is not ours.
  local ffi = require("ffi")
  ffi.copy(params.reasoning_effort, string.rep("z", 16), 16)
  eq(jarvis.effort(params), string.rep("z", 16), "read stops at the field")
end)

test("copying parameters copies rather than aliases", function()
  local params = jarvis.params()
  local copy = jarvis.copy_params(params)
  copy.max_tokens = 7
  eq(params.max_tokens, 2048, "the original is untouched")
  eq(copy.max_tokens, 7, "the copy took the change")
end)

-- ---------------------------------------------------------------- config ---

test("the discovered config carries this repository's model", function()
  local config = truthy(jarvis.config(), "config")
  local model = config:model()
  truthy(model.alias, "alias")
  eq(model.app.name, "Causewaybay Jarvis", "app name")
  truthy(config:get("generation").max_tokens > 0, "max_tokens")
  eq(config:get("nonesuch"), nil, "an absent key is nil")
  config:close()
end)

test("a config file becomes generation parameters", function()
  local path = os.tmpname()
  local file = assert(io.open(path, "w"))
  file:write('{"key":"generation","value":{"max_tokens":16,"temperature":0,"seed":7}}\n')
  file:write('{"key":"thinking","value":{"enabled":false,"effort":"xhigh","show":false}}\n')
  file:close()

  local config = truthy(jarvis.config(path), "config")
  eq(config:source(), path, "source")
  local params = truthy(config:params(), "params")
  eq(params.max_tokens, 16)
  eq(params.temperature, 0)
  eq(params.has_seed, 1)
  eq(tonumber(params.seed), 7)
  eq(params.enable_thinking, 0)
  eq(jarvis.effort(params), "xhigh")
  -- Keys the file leaves out still get their defaults, not zeroes.
  eq(params.top_k, 20, "top_k")
  eq(config:get("thinking").show, false, "show")
  config:close()
  os.remove(path)
end)

test("a config that is not there is an error, not a silent default", function()
  local config, e = jarvis.config("/nonexistent/config.jsonl")
  eq(config, nil)
  contains(e, "/nonexistent/config.jsonl")
end)

test("a closed handle is refused rather than used again", function()
  local config = truthy(jarvis.config(), "config")
  config:close()
  raises(function() return config:model() end, "closed")
  config:close() -- closing twice is a no-op, not a double free
end)

-- ---------------------------------------------------------------- models ---

test("the alias table is listable", function()
  local models = jarvis.models()
  truthy(#models > 0, "aliases")
  local found
  for _, model in ipairs(models) do
    if model.alias == "qwen3.8:27b-mlx" then found = model end
  end
  eq(truthy(found, "the default alias").repo, "mlx-community/Qwen3.8-27B-4bit")
end)

test("a model resolves without being downloaded", function()
  local info = truthy(jarvis.model_info("qwen3.8:27b-mlx"), "info")
  eq(info.repo, "mlx-community/Qwen3.8-27B-4bit")
  eq(info.revision, "main", "the default revision")
  eq(type(info["local"]), "boolean", "local")

  -- An explicit repository overrides whatever the alias points at.
  local other = truthy(jarvis.model_info("qwen3.8:27b-mlx", "abc123", "someone/else"))
  eq(other.repo, "someone/else")
  eq(other.revision, "abc123")
  eq(other["local"], false, "a repository nobody has is not local")
end)

test("an unknown model names the alternatives", function()
  local info, e = jarvis.model_info("llama-42")
  eq(info, nil)
  contains(e, "llama-42")
  contains(e, "qwen3.8:27b-mlx")

  local present, e2 = jarvis.is_local("llama-42")
  eq(present, nil, "unresolvable is neither true nor false")
  contains(e2, "llama-42")
end)

test("a bare org/name is accepted as its own alias", function()
  local info = truthy(jarvis.model_info("mlx-community/Qwen3.8-27B-8bit"))
  eq(info.repo, "mlx-community/Qwen3.8-27B-8bit")
  eq(type(jarvis.is_local("mlx-community/Qwen3.8-27B-8bit")), "boolean")
end)

-- --------------------------------------------------------------- session ---

test("opening weights that are not on disk says which and why", function()
  local session, e = jarvis.open("mlx-community/definitely-not-a-real-checkpoint")
  eq(session, nil)
  contains(e, "not in the local cache")
end)

test("the interrupt flag round-trips", function()
  jarvis.interrupt.clear()
  eq(jarvis.interrupt.raised(), false)
  -- Installing the handler is idempotent from this side: the second attempt
  -- reports failure rather than replacing a handler somebody else owns.
  truthy(jarvis.interrupt.install(), "install")
  eq(jarvis.interrupt.install(), false, "a second install is refused")
  eq(jarvis.interrupt.raised(), false, "installing does not raise it")
end)

test("memory counters are readable before anything is loaded", function()
  local memory = jarvis.memory()
  eq(type(memory.active), "number")
  eq(type(memory.peak), "number")
end)

-- --------------------------------------------------------- the client ---

local chat = require("chat")

--- The message `die` raised, for a command line that should not parse.
local function rejected(argv)
  local ok, e = pcall(chat.parse, argv)
  if ok then error("expected these arguments to be refused", 2) end
  return type(e) == "table" and e.usage or tostring(e)
end

test("the command line parses into options and a command", function()
  local opts, rest = chat.parse({ "-m", "qwen3.8:27b-mlx-8bit", "--temp", "0.2",
    "--max-tokens", "64", "--seed", "7", "--effort", "xhigh", "--no-think",
    "--hide-thinking", "run", "why", "is", "the", "sky", "blue?" })
  eq(opts.model, "qwen3.8:27b-mlx-8bit")
  eq(opts.temperature, 0.2)
  eq(opts.max_tokens, 64)
  eq(opts.seed, 7)
  eq(opts.effort, "xhigh")
  eq(opts.think, false, "--no-think")
  eq(opts.hide_thinking, true)
  eq(table.concat(rest, " "), "run why is the sky blue?")
end)

test("a count of tokens has to be a whole number of at least one", function()
  -- These reach a uint32_t: -1 would arrive as four billion and generate
  -- until the context ran out, and 0 would generate nothing and then report
  -- that it had hit the limit.
  contains(rejected({ "--max-tokens", "-1" }), "at least 1")
  contains(rejected({ "--max-tokens", "0" }), "at least 1")
  contains(rejected({ "--max-tokens", "1.5" }), "whole number")
  contains(rejected({ "--max-tokens", "lots" }), "wants a number")
  contains(rejected({ "--tokens", "0" }), "at least 1")
  contains(rejected({ "--prompt", "-8" }), "at least 1")
  eq(chat.parse({ "--max-tokens", "1" }).max_tokens, 1, "one is allowed")
end)

test("`--` ends the options, so a prompt may start with a dash", function()
  local opts, rest = chat.parse({ "run", "--", "--not-an-option", "-t" })
  eq(opts.temperature, nil, "nothing after -- is read as an option")
  eq(table.concat(rest, " "), "run --not-an-option -t")
end)

test("a command line that cannot be honoured is refused, not guessed at", function()
  contains(rejected({ "--nonesuch" }), "unknown option")
  contains(rejected({ "--temp" }), "needs a value")
  contains(rejected({ "--temp", "warm" }), "wants a number")
end)

test("settings come from the config and are then overridden", function()
  local config = truthy(jarvis.config(), "config")
  local st = chat.settings(config, {})
  eq(st.params.max_tokens, config:get("generation").max_tokens, "from config")
  truthy(st.system, "the config's system prompt")

  local opts = chat.parse({ "-s", "You are a test.", "--temp", "0", "--max-tokens", "8",
    "--seed", "3", "--think", "--effort", "medium", "--hide-thinking" })
  st = chat.settings(config, opts)
  eq(st.system, "You are a test.", "--system wins")
  eq(st.params.temperature, 0)
  eq(st.params.max_tokens, 8)
  eq(st.params.has_seed, 1)
  eq(tonumber(st.params.seed), 3)
  eq(st.params.enable_thinking, 1, "--think")
  eq(jarvis.effort(st.params), "medium")
  eq(st.show_thinking, false, "--hide-thinking")
  config:close()
end)

test("an effort the model does not know is refused before the first turn", function()
  local config = truthy(jarvis.config(), "config")
  local ok, e = pcall(chat.settings, config, { effort = "turbo" })
  eq(ok, false, "refused")
  contains(type(e) == "table" and e.usage or tostring(e), "turbo")
  config:close()
end)

test("--model overrides the repository the config pinned", function()
  local config = truthy(jarvis.config(), "config")
  local alias, _, repo = chat.target(config, {})
  eq(alias, config:model().alias, "the config's alias")
  eq(repo, config:model().repo, "and its repository")

  -- A pinned repo belongs to the alias it was pinned for; asking for another
  -- model has to drop it, or the override would silently load the old weights.
  local other, _, no_repo = chat.target(config, { model = "qwen3.8:27b-mlx-8bit" })
  eq(other, "qwen3.8:27b-mlx-8bit")
  eq(no_repo, nil, "the pinned repository is dropped")
  config:close()
end)

test("statistics read the way the Rust front ends print them", function()
  local was = ui.enabled
  ui.enabled = false
  local line = chat.format_stats({
    stop_reason = "length",
    stats = { prompt_tokens = 100, cached_prompt_tokens = 80, prefill_tokens = 20,
      generated_tokens = 10, reasoning_tokens = 4, prefill_tps = 100, decode_tps = 10,
      peak_memory = 1536 },
  })
  ui.enabled = was
  contains(line, "100 prompt · 10 generated · 10.0 tok/s")
  contains(line, "prefill 100 tok/s")
  contains(line, "80 cached")
  contains(line, "4 thinking")
  contains(line, "1.5 KiB")
  contains(line, "hit max_tokens")
end)

test("slash commands change the settings they name", function()
  local config = truthy(jarvis.config(), "config")
  local st = chat.settings(config, {})
  config:close()
  -- Every branch reached here touches only the settings, so a session that
  -- answers nothing is enough to drive them.
  local session = { last = function() return nil end }

  eq(quietly(chat.slash, "think off", session, st), false, "handled")
  eq(st.params.enable_thinking, 0)
  quietly(chat.slash, "think on", session, st)
  eq(st.params.enable_thinking, 1)

  quietly(chat.slash, "temp 0.25", session, st)
  eq(st.params.temperature, 0.25)
  quietly(chat.slash, "max 32", session, st)
  eq(st.params.max_tokens, 32)
  quietly(chat.slash, "effort xhigh", session, st)
  eq(jarvis.effort(st.params), "xhigh")

  local show = st.show_thinking
  quietly(chat.slash, "show", session, st)
  eq(st.show_thinking, not show, "/show toggles")

  eq(quietly(chat.slash, "exit", session, st), true, "/exit quits")
end)

test("a slash command that cannot be honoured says why", function()
  local config = truthy(jarvis.config(), "config")
  local st = chat.settings(config, {})
  config:close()
  local session = { last = function() return nil end }

  local ok, e = quietly(chat.slash, "nonesuch", session, st)
  eq(ok, nil)
  contains(e, "unknown command `/nonesuch`")

  eq(select(2, quietly(chat.slash, "temp warm", session, st)), "temperature must be a number")
  contains(select(2, quietly(chat.slash, "effort turbo", session, st)), "low, medium or xhigh")
  contains(select(2, quietly(chat.slash, "system", session, st)), "give the system prompt")
  contains(select(2, quietly(chat.slash, "save", session, st)), "give a path")
  -- The settings survived every rejection unchanged.
  eq(st.params.temperature, jarvis.config():params().temperature, "temperature")
end)

test("the client runs under whatever name it is given", function()
  -- It has a shebang, so copying it onto a PATH as `jarvis-chat` is a normal
  -- thing to do — and it has to keep working, while `require`-ing it here
  -- still has to yield the pieces above rather than a chat session.
  local original = io.open(here .. "/chat.lua", "r")
  if not original then skip("chat.lua is not beside this file") end
  local body = original:read("*a")
  original:close()

  -- Next to `jarvis/`, since that is where it looks for its own modules.
  local renamed = here .. "/jarvis-chat-under-test"
  local copy = truthy(io.open(renamed, "w"), "writing the copy")
  copy:write(body)
  copy:close()

  local pipe = io.popen(string.format("%q %q --version 2>&1", arg[-1] or "luajit", renamed))
  local out = pipe:read("*a")
  pipe:close()
  os.remove(renamed)

  contains(out, jarvis.version())
end)

-- ---------------------------------------------------- with the checkpoint --

--- The checkpoint is 15 GiB and takes seconds to load, so every test below
--- shares one session and starts by clearing it rather than opening its own.
local shared

local function open_model()
  if os.getenv("JARVIS_TEST_MODEL") ~= "1" then
    skip("set JARVIS_TEST_MODEL=1 to run this")
  end
  if shared == false then skip("the weights are not downloaded") end

  if not shared then
    local config = truthy(jarvis.config(), "config")
    local model = config:model()
    config:close()
    if not jarvis.is_local(model.alias, model.revision, model.repo) then
      shared = false
      skip("the weights are not downloaded")
    end
    io.write("      loading ", model.alias, "…\n")
    shared = truthy(jarvis.open(model.alias, model.revision, model.repo))
  end

  shared:reset()
  shared:set_system(nil)
  return shared
end

test("a turn streams, answers, and is remembered", function()
  local session = open_model()
  session:set_system("You are a test fixture. Answer with a single word.")

  local params = jarvis.params()
  params.max_tokens = 48
  params.temperature = 0
  params.enable_thinking = 0

  local seen, streamed = {}, {}
  local completion = truthy(session:send("Reply with exactly: pong", params,
    function(kind, text)
      seen[kind] = (seen[kind] or 0) + 1
      if kind == "token" then streamed[#streamed + 1] = text end
    end), "completion")

  truthy(seen.prefill and seen.prefill > 0, "prefill events")
  truthy(seen.token and seen.token > 0, "token events")
  -- The streamed chunks are the answer, in order and with nothing dropped.
  eq(table.concat(streamed):gsub("^%s+", ""):gsub("%s+$", ""), completion.text)
  contains(completion.text:lower(), "pong")
  truthy(completion.stats.generated_tokens > 0, "generated tokens")
  truthy(completion.stats.decode_tps > 0, "decode rate")

  local messages = session:messages()
  eq(#messages, 3, "system, user, assistant")
  eq(messages[3].role, "assistant")
  eq(messages[3].content, completion.text)
end)

test("a second turn reuses the cache the first one filled", function()
  local session = open_model()
  local params = jarvis.params()
  params.max_tokens = 24
  params.temperature = 0
  params.enable_thinking = 0

  truthy(session:send("Say: one", params))
  local cached = session:cached_tokens()
  truthy(cached > 0, "the first turn left a cache")

  local second = truthy(session:send("Say: two", params))
  -- The prompt is a strict extension of the last one, so most of it was
  -- already in the cache and was not read again.
  truthy(second.stats.cached_prompt_tokens > 0, "cached prompt tokens")
  truthy(second.stats.prefill_tokens < second.stats.prompt_tokens, "prefill was shorter")

  session:reset()
  eq(session:cached_tokens(), 0, "reset drops the cache")
  eq(#session:messages(), 0, "and the transcript")
end)

test("a handler that returns true stops the answer early", function()
  local session = open_model()
  local params = jarvis.params()
  params.max_tokens = 256
  params.temperature = 0
  params.enable_thinking = 0

  local tokens = 0
  local completion = truthy(session:send("Count slowly from one to fifty.", params,
    function(kind)
      if kind == "token" then
        tokens = tokens + 1
        return tokens >= 3
      end
    end))
  eq(completion.stop_reason, "interrupted")
  truthy(completion.stats.generated_tokens < 256, "it stopped before the cap")
end)

test("an error inside a handler surfaces in Lua, not through C", function()
  local session = open_model()
  local params = jarvis.params()
  params.max_tokens = 32
  params.enable_thinking = 0
  -- The failure has to cross back over the boundary intact: the turn stops,
  -- and the message is the one the handler raised.
  raises(function()
    session:send("hello", params, function(kind)
      if kind == "token" then error("the handler gave up", 0) end
    end)
  end, "the handler gave up")
end)

test("the tokenizer and the template are reachable", function()
  local session = open_model()
  truthy(session:count_tokens("hello world") > 0, "token count")

  -- Truncation lands on a token boundary, which is the only place a prompt of
  -- an exact length can end.
  local long = string.rep("The quick brown fox jumps over the lazy dog. ", 20)
  eq(session:count_tokens(assert(session:truncate(long, 12))), 12, "truncated")
  eq(session:truncate("hi", 500), "hi", "asking for more tokens than there are")
  local prompt = truthy(session:render("hello", jarvis.params()), "prompt")
  contains(prompt, "<|im_start|>user")
  contains(prompt, "hello")
  contains(prompt, "<|im_start|>assistant")

  local info = session:info()
  truthy(info.parameters > 1e9, "parameters")
  truthy(info.context_length > 0, "context length")
  contains(info.quantization, "bit")
end)

test("a mistyped argument raises without leaking a callback slot", function()
  local session = open_model()
  local params = jarvis.params()
  params.max_tokens = 1

  -- LuaJIT holds callbacks in a small fixed table — a couple of thousand
  -- slots. `send` casts one per turn and frees it afterwards, including when
  -- the call itself raises, which a number where a string belongs makes it do.
  -- Leaking one per mistake would fill the table and then fail every later
  -- cast, complaining about something entirely unrelated. So: more mistakes
  -- than the table has room for.
  for _ = 1, 4096 do
    raises(function() return session:send(42, params, function() end) end)
  end
  -- Still able to take a turn, which needs a slot of its own.
  truthy(session:send("Say: hello", params, function() end), "a turn after all that")
end)

test("the session cannot be re-entered from its own handler", function()
  local session = open_model()
  local params = jarvis.params()
  params.max_tokens = 4
  params.enable_thinking = 0

  -- The turn holds the session for its whole duration, so a handler calling
  -- back in would alias it. The library refuses instead of obliging: here a
  -- `/reset` fired from a handler, which would otherwise clear the transcript
  -- out from under the answer being generated into it.
  local reentered
  truthy(session:send("Say: hi", params, function(kind)
    if kind == "token" and reentered == nil then
      reentered = select(2, session:reset())
    end
  end), "the turn itself still succeeds")
  contains(reentered, "re-entered")
  truthy(#session:messages() > 0, "and the transcript survived")

  -- And closing it from in there would leak the weights, so that is refused
  -- on this side of the boundary, where it can say so properly.
  local closed
  truthy(session:send("Say: hi", params, function(kind)
    if kind == "token" and closed == nil then
      closed = select(2, pcall(function() return session:close() end))
    end
  end))
  contains(closed, "cannot be closed from inside")
  truthy(session:cached_tokens(), "the session is still open afterwards")
end)

test("a transcript survives a save and a load", function()
  local session = open_model()
  local params = jarvis.params()
  params.max_tokens = 16
  params.temperature = 0
  params.enable_thinking = 0
  truthy(session:send("Say: hello", params))

  local saved = session:messages_json()
  session:reset()
  eq(#session:messages(), 0)
  truthy(session:load(saved), "load")
  local messages = session:messages()
  eq(#messages, 2, "user and assistant")
  eq(messages[1].role, "user")
end)

-- ------------------------------------------------------------------- run ---

io.write(string.format("running %d tests against %s\n", #cases, jarvis.library))
for _, case in ipairs(cases) do
  local ok, e = pcall(case.fn)
  if ok then
    io.write("ok    ", case.name, "\n")
  elseif type(e) == "table" and e.skip then
    skipped = skipped + 1
    io.write("skip  ", case.name, "  (", e.skip, ")\n")
  else
    failed = failed + 1
    io.write("FAIL  ", case.name, "\n        ", tostring(e), "\n")
  end
end

if shared then shared:close() end

io.write(string.format("\n%d passed, %d failed, %d skipped\n",
  #cases - failed - skipped, failed, skipped))
if skipped > 0 and failed == 0 then
  io.write("note: skipped tests were NOT run — `make lua-test-model` covers them.\n")
end
os.exit(failed == 0 and 0 or 1)
