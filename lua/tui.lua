#!/usr/bin/env luajit
-- Full-screen chat, in Lua, on the server.
--
--   luajit lua/tui.lua                     the server's model
--   make luatui                            the same, with the server built
--
-- This is `rusttui` with the same panes and the same keys, talking to
-- `agentd` — the one process that holds the model — over HTTP and
-- server-sent events (see `jarvis/client.lua`): a header saying what is
-- answering, a transcript that wraps and scrolls, an input box, and a
-- status line. It loads no weights and needs no library: LuaJIT and `curl`.
--
-- Streaming is the whole design. `session:send` blocks for the length of a
-- turn and reports every piece through a callback, so the callback is
-- where the screen is redrawn *and* where the keyboard is read: that is
-- what makes Escape stop a running answer rather than being noticed after
-- it. See `lua/jarvis/term.lua` for why the keyboard is polled rather than
-- read.

-- The same two patterns `lua/chat.lua` uses: `jarvis` is a directory with
-- an `init.lua`, which the second one is for.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/?/init.lua;" .. package.path

local client = require("jarvis.client")
local term = require("jarvis.term")

local M = {}

-- ---------------------------------------------------------------- state ----

--- The transcript is kept twice, for the same reason `rusttui` keeps it
--- twice: the model sees a conversation, the screen sees blocks, and they
--- disagree about reasoning — which is one part of an assistant turn to
--- the template and its own foldable block on screen.
local function newApp(options)
  return {
    blocks = {},          -- { kind = user|reasoning|answer|notice, text }
    input = "",
    cursor = 0,           -- bytes before the caret
    scroll = nil,         -- first visible wrapped row; nil pins to the bottom
    busy = false,
    status = "",
    stop = false,         -- Escape, seen while generating
    quit = false,
    showThinking = options and options.showThinking or false,
    stats = nil,
    startedAt = nil,      -- when the turn in flight began
    tokens = 0,           -- how many chunks have arrived in it
    prefill = nil,        -- { done, total } while the prompt is being read
    history = {},
    historyPos = nil,
  }
end

M.newApp = newApp

local function push(app, kind, text)
  app.blocks[#app.blocks + 1] = { kind = kind, text = text or "" }
end

M.push = push

--- Append to the last block of this kind, or start one. What streaming
--- does: a token is not a new paragraph.
local function append(app, kind, text)
  local last = app.blocks[#app.blocks]
  if last and last.kind == kind then
    last.text = last.text .. text
  else
    push(app, kind, text)
  end
end

M.append = append

-- ------------------------------------------------------------- wrapping ----

--- Break `text` to `width` columns, keeping blank lines and breaking a word
--- that cannot fit rather than letting it run off the edge.
function M.wrap(text, width)
  local out = {}
  width = math.max(1, width)
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      out[#out + 1] = ""
    else
      local current = ""
      for word in line:gmatch("%S+") do
        while #word > width do
          if current ~= "" then out[#out + 1] = current; current = "" end
          out[#out + 1] = word:sub(1, width)
          word = word:sub(width + 1)
        end
        if current == "" then
          current = word
        elseif #current + 1 + #word <= width then
          current = current .. " " .. word
        else
          out[#out + 1] = current
          current = word
        end
      end
      if current ~= "" then out[#out + 1] = current end
    end
  end
  return out
end

-- The chrome is ASCII on purpose. Everything here is measured to lay out a
-- line, and a prefix that is two columns but four bytes makes every width
-- in this file a lie. The model's own text is UTF-8 and is measured
-- properly — see `term.width` — but the frame around it does not need to
-- be.
local MARK = {
  user =      { prefix = "> ", colour = "36" },
  answer =    { prefix = "",   colour = nil  },
  reasoning = { prefix = ". ", colour = "2"  },
  notice =    { prefix = "! ", colour = "33" },
}

--- Every visible row of the transcript, wrapped: `{ text, kind }`.
--- Separate from drawing so the scroll arithmetic can be tested with no
--- terminal at all.
function M.rows(app, width)
  local rows = {}
  for _, block in ipairs(app.blocks) do
    if block.kind ~= "reasoning" or app.showThinking then
      local mark = MARK[block.kind] or MARK.answer
      local indent = string.rep(" ", #mark.prefix)
      local wrapped = M.wrap(block.text, width - #mark.prefix)
      for i, line in ipairs(wrapped) do
        rows[#rows + 1] = {
          text = (i == 1 and mark.prefix or indent) .. line,
          kind = block.kind,
        }
      end
      rows[#rows + 1] = { text = "", kind = block.kind }
    end
  end
  return rows
end

--- The first row to draw, given how many fit. Pinned to the bottom unless
--- the user has scrolled, and clamped so a shrinking transcript cannot
--- leave the view past the end of it.
function M.top(app, total, visible)
  local bottom = math.max(0, total - visible)
  if not app.scroll then return bottom end
  return math.max(0, math.min(app.scroll, bottom))
end

-- ------------------------------------------------------------- drawing ----

local function human(n)
  n = tonumber(n) or 0
  if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(math.floor(n))
end

M.human = human

--- The right-hand end of the header: throughput and context, once a turn
--- has produced some.
function M.statsLine(stats)
  if not stats then return "" end
  if stats.chunks then
    return string.format("%d pieces  |  %.1fs ", tonumber(stats.chunks) or 0,
      tonumber(stats.seconds) or 0)
  end
  local tps = tonumber(stats.decode_tps or stats.decodeTps) or 0
  local ctx = tonumber(stats.prompt_tokens or stats.promptTokens) or 0
  return string.format("%.1f tok/s  |  %d ctx ", tps, ctx)
end

-- A spinner, in ASCII for the same reason the rest of the chrome is: it is
-- measured, and every terminal has these four.
local SPIN = { "|", "/", "-", "\\" }

--- The frame for a moment in time. Eight a second: fast enough to read as
--- motion, slow enough not to strobe.
function M.spinner(t)
  return SPIN[(math.floor((tonumber(t) or 0) * 8) % #SPIN) + 1]
end

--- What the client is waiting for, in words, with the clock running.
---
--- A turn against a 27-billion-parameter model spends seconds reading the
--- prompt before it writes anything, and a screen that says nothing during
--- those seconds is indistinguishable from one that has hung. So the wait
--- is narrated: the phase, how far through it is, and how long it has been.
function M.waiting(app, now)
  local spin = M.spinner(now)
  local seconds = app.startedAt and (now - app.startedAt) or 0
  local what
  if app.prefill and app.prefill.total > 0 and app.tokens == 0 then
    what = string.format("reading the prompt  %d/%d",
      app.prefill.done, app.prefill.total)
  elseif app.tokens > 0 then
    local rate = seconds > 0 and (app.tokens / seconds) or 0
    what = string.format("writing  %d tokens  %.1f/s", app.tokens, rate)
  elseif app.status ~= "" then
    what = app.status
  else
    what = "thinking"
  end
  return string.format(" %s  %s  |  %.1fs  |  esc or ctrl-c to stop",
    spin, what, seconds)
end

local HELP = " enter send  |  ctrl-r reset  |  ctrl-t thinking  |  pgup/pgdn scroll  |  ctrl-c quit"

function M.footer(app, now)
  if app.busy then return M.waiting(app, now or client.now()) end
  if app.status ~= "" then return " " .. app.status end
  return HELP
end

local function draw(app, info)
  term.frame(function(out, w, h, clearLine)
    for y = 1, h do clearLine(y) end

    -- Header: what is answering, and what the last turn cost.
    local left = " " .. tostring(info.model or "?") .. " "
    local middle = string.format("  %s  |  %s  ",
      tostring(info.effective or ""), tostring(info.server or ""))
    local right = M.statsLine(app.stats)
    out(1, 1, term.fit(left, w), term.code("1", "30", "46"))
    out(math.min(w, #left + 1), 1, term.fit(middle, math.max(0, w - #left)), term.code("2"))
    if #right > 0 and w > #right then
      out(w - #right + 1, 1, right, term.code("2"))
    end

    -- Body: the transcript, wrapped, scrolled.
    local bodyTop, bodyRows = 2, h - 5
    local rows = M.rows(app, w - 1)
    local top = M.top(app, #rows, bodyRows)
    for i = 1, bodyRows do
      local row = rows[top + i]
      if row then
        local mark = MARK[row.kind] or MARK.answer
        out(1, bodyTop + i - 1, term.fit(row.text, w - 1),
          mark.colour and term.code(mark.colour) or nil)
      end
    end
    if top < math.max(0, #rows - bodyRows) then
      out(w - 8, bodyTop, " more v ", term.code("7"))
    end

    -- Input box.
    local boxY = h - 2
    local now = client.now()
    local label = app.busy
      and (" working " .. M.spinner(now) .. " ")
      or " message "
    out(1, boxY - 1, term.fit(label .. string.rep("-", math.max(0, w - #label - 1)), w),
      term.code("2"))
    out(1, boxY, term.fit("> " .. app.input, w), term.code(app.busy and "2" or "0"))

    -- Footer.
    out(1, h, term.fit(M.footer(app, now), w), term.code("2"))
  end)

  -- The caret, last, so it lands on top of everything drawn.
  local _, h = term.size()
  if app.busy then
    term.cursor(1, h, false)
  else
    term.cursor(3 + app.cursor, h - 2, true)
  end
end

-- ------------------------------------------------------------- editing ----

function M.insert(app, text)
  app.input = app.input:sub(1, app.cursor) .. text .. app.input:sub(app.cursor + 1)
  app.cursor = app.cursor + #text
end

function M.backspace(app)
  if app.cursor == 0 then return end
  app.input = app.input:sub(1, app.cursor - 1) .. app.input:sub(app.cursor + 1)
  app.cursor = app.cursor - 1
end

function M.delete(app)
  if app.cursor >= #app.input then return end
  app.input = app.input:sub(1, app.cursor) .. app.input:sub(app.cursor + 2)
end

--- Walk the history. `step` is -1 for older, 1 for newer; leaving the end
--- of it restores an empty line rather than sticking on the newest entry.
function M.history(app, step)
  if #app.history == 0 then return end
  local pos = app.historyPos
  if step < 0 then
    pos = pos and math.max(1, pos - 1) or #app.history
  elseif pos then
    pos = pos + 1
    if pos > #app.history then pos = nil end
  else
    return
  end
  app.historyPos = pos
  app.input = pos and app.history[pos] or ""
  app.cursor = #app.input
end

-- ---------------------------------------------------------------- turns ----

--- One turn, streamed onto the screen.
---
--- The callback is doing three jobs at once, which is what makes this a
--- TUI rather than a printer: it folds the chunk into the transcript,
--- repaints, and reads the keyboard so Escape is felt between tokens
--- rather than after the answer.
local function turn(app, session, text, params)
  push(app, "user", text)
  app.busy, app.stop, app.status = true, false, ""
  app.startedAt, app.tokens, app.prefill = client.now(), 0, nil
  app.scroll = nil

  local painted = 0
  local function repaint(info)
    -- Sixty frames a second is plenty, and a repaint per token on a fast
    -- decode is just tearing.
    local now = client.now()
    if now - painted < 0.016 then return end
    painted = now
    draw(app, info)
  end

  local info = session:info()
  -- The first frame of the wait, before the engine has reported anything:
  -- pressing enter must change the screen immediately, or it reads as a
  -- keystroke that was dropped.
  draw(app, info)
  local completion, err = session:send(text, params, function(kind, chunk, done, total)
    if kind == "prefill" then
      app.prefill = { done = tonumber(done) or 0, total = tonumber(total) or 0 }
      app.status = "reading the prompt"
    elseif kind == "reasoning" then
      app.status = "thinking"
      if app.showThinking then append(app, "reasoning", chunk or "") end
    elseif kind == "reasoning_done" then
      app.status = "writing"
    elseif kind == "token" then
      app.status = "writing"
      app.tokens = app.tokens + 1
      append(app, "answer", chunk or "")
    end
    repaint(info)

    -- The keyboard, between tokens. Escape and Ctrl-C stop; anything else
    -- is dropped rather than queued, because typing into a box you cannot
    -- see is worse than losing the keystroke. Stopping closes the stream,
    -- and the server stops generating when it sees the socket go.
    local key = term.key(0)
    if key == "escape" or key == "ctrl-c" then app.stop = true end
    return app.stop
  end)

  app.busy = false
  app.status = ""
  app.prefill = nil
  if err then
    push(app, "notice", tostring(err))
  elseif completion then
    app.stats = completion.stats
    if app.stop or completion.stop_reason == "interrupted" then push(app, "notice", "stopped") end
    -- An answer that came back empty is worth saying so: a blank block
    -- reads as a bug in the client rather than as a model that stopped.
    local last = app.blocks[#app.blocks]
    if not last or last.kind ~= "answer" or last.text:gsub("%s", "") == "" then
      push(app, "notice", "the model said nothing")
    end
  end
  return completion
end

-- --------------------------------------------------------------- driver ----

local COMMANDS = {}

--- Slash commands, the same ones the REPL has, so muscle memory carries.
function M.command(app, line, session)
  local name, rest = line:match("^/(%S+)%s*(.*)$")
  if not name then return false end
  local fn = COMMANDS[name:lower()]
  if not fn then
    push(app, "notice", "no command /" .. name .. " — try /help")
    return true
  end
  fn(app, rest, session)
  return true
end

COMMANDS.help = function(app)
  push(app, "notice",
    "/help  /reset  /thinking  /system <text>  /stats  /exit")
end

COMMANDS.exit = function(app) app.quit = true end
COMMANDS.quit = COMMANDS.exit

COMMANDS.reset = function(app, _, session)
  if session then session:reset() end
  app.blocks = {}
  app.stats = nil
  push(app, "notice", "conversation reset")
end

COMMANDS.thinking = function(app)
  app.showThinking = not app.showThinking
  push(app, "notice", "thinking " .. (app.showThinking and "shown" or "hidden"))
end

COMMANDS.system = function(app, rest, session)
  if rest == "" then
    push(app, "notice", "usage: /system <prompt>")
    return
  end
  if session then session:set_system(rest) end
  push(app, "notice", "system prompt set")
end

COMMANDS.stats = function(app)
  if not app.stats then
    push(app, "notice", "no turn yet")
    return
  end
  local s = app.stats
  push(app, "notice", string.format("%d pieces in %.1fs",
    tonumber(s.chunks) or 0, tonumber(s.seconds) or 0))
end

M.commands = COMMANDS

--- Handle one key. Pure enough to test: it touches `app` and, for the
--- keys that need one, the session.
function M.handle(app, key, session, params)
  if key == "ctrl-c" then app.quit = true return end
  if key == "ctrl-d" and app.input == "" then app.quit = true return end
  if key == "ctrl-r" then COMMANDS.reset(app, nil, session) return end
  if key == "ctrl-t" then COMMANDS.thinking(app) return end
  if key == "ctrl-u" then app.input, app.cursor = "", 0 return end
  if key == "ctrl-k" then app.input = app.input:sub(1, app.cursor) return end
  if key == "ctrl-a" or key == "home" then app.cursor = 0 return end
  if key == "ctrl-e" or key == "end" then app.cursor = #app.input return end
  if key == "backspace" then M.backspace(app) return end
  if key == "delete" then M.delete(app) return end
  if key == "left" then app.cursor = math.max(0, app.cursor - 1) return end
  if key == "right" then app.cursor = math.min(#app.input, app.cursor + 1) return end
  if key == "up" then M.history(app, -1) return end
  if key == "down" then M.history(app, 1) return end
  if key == "escape" then app.scroll = nil return end
  if key == "pageup" or key == "pagedown" then
    local _, h = term.size()
    local page = math.max(1, h - 6)
    local rows = #M.rows(app, 78)
    local base = app.scroll or math.max(0, rows - page)
    app.scroll = math.max(0, base + (key == "pageup" and -page or page))
    return
  end
  if key == "enter" then
    local line = app.input:gsub("^%s+", ""):gsub("%s+$", "")
    app.input, app.cursor, app.historyPos = "", 0, nil
    if line == "" then return end
    app.history[#app.history + 1] = line
    if M.command(app, line, session) then return end
    return line, params
  end
  if key and #key == 1 then M.insert(app, key) end
end

local function usage()
  io.write([[
luajit lua/tui.lua — full-screen chat on the server

  -s, --system TEXT     a system prompt
      --think           show the model's reasoning
      --max-tokens N    cap the answer
      --home DIR        the space, when it is not ~/.causewaybayjarvis
  -h, --help            this

Keys: enter send | esc stop or unscroll | ctrl-r reset | ctrl-t thinking
      pgup/pgdn scroll | ctrl-c stop a turn, or quit when idle
]])
end

function M.main(argv)
  local options = { showThinking = false }
  local system, maxTokens, home
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "-h" or a == "--help" then usage() return 0
    elseif a == "-s" or a == "--system" then i = i + 1; system = argv[i]
    elseif a == "--home" then i = i + 1; home = argv[i]
    elseif a == "--think" then options.showThinking = true
    elseif a == "--max-tokens" then i = i + 1; maxTokens = tonumber(argv[i])
    else
      io.stderr:write("unknown option `" .. tostring(a) .. "`\n")
      usage()
      return 2
    end
    i = i + 1
  end

  -- Reaching the server may mean starting it, which may mean loading a
  -- checkpoint; it is the one wait this client cannot animate. So it is
  -- announced instead, and timed, on the ordinary terminal before the
  -- full-screen one is taken — a blank window for several seconds is the
  -- thing that reads as a hang.
  io.write("reaching the server …\n")
  io.flush()
  local began = client.now()

  local c, why = client.connect(home)
  if not c then
    io.stderr:write("cannot reach the server: " .. tostring(why) .. "\n")
    return 1
  end
  local session = c:session(system)

  local params = { think = options.showThinking }
  if maxTokens then params.max_tokens = maxTokens end

  local opened, why = term.open()
  if not opened then
    io.stderr:write("this needs a terminal (" .. tostring(why) .. ")\n")
    session:close()
    return 1
  end

  local app = newApp(options)
  push(app, "notice", string.format("ready in %.1fs - /help for commands",
    client.now() - began))

  -- Everything from here is inside a pcall: a crash that skipped
  -- `term.close` would leave the user's shell with no echo and no cursor,
  -- which is a far worse bug than whatever caused it.
  local fine, err = pcall(function()
    local info = session:info()
    while not app.quit do
      draw(app, info)
      local key = term.key(0.05)
      -- Ctrl-C with nothing running is a key here (the terminal is opened
      -- with signals off), and `M.handle` reads it as leave.
      if key then
        local line = M.handle(app, key, session, params)
        if line then turn(app, session, line, params) end
      end
    end
  end)

  term.close()
  session:close()
  if not fine then
    io.stderr:write("tui: " .. tostring(err) .. "\n")
    return 1
  end
  return 0
end

-- Required by the tests, run as a program otherwise.
if pcall(debug.getlocal, 4, 1) then return M end
os.exit(M.main(arg or {}))
