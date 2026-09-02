-- The terminal, for a full-screen client.
--
-- `lua/chat.lua` writes a line at a time and lets the shell do the rest;
-- a TUI has to own the screen instead — raw keys, no echo, a cursor it
-- places itself, and a size it can ask for. This is that layer, and
-- nothing above it talks to the terminal directly.
--
--   local term = require("jarvis.term")
--   term.open()                       -- raw mode, alternate screen
--   local w, h = term.size()
--   term.frame(function(out) out(1, 1, "hello") end)
--   local key = term.key(0.05)        -- nil after the timeout
--   term.close()
--
-- Two things are done through the FFI rather than through Lua: reading a
-- key without blocking (`poll` then `read`, because `io.read` would stop
-- the world while a model is generating), and asking the terminal how big
-- it is (`ioctl`). Raw mode itself goes through `stty`, because a
-- `struct termios` is laid out differently on every platform and getting
-- it wrong turns the user's shell into an unusable one.

local ffi = require("ffi")

ffi.cdef [[
  typedef long ssize_t;
  ssize_t read(int fd, void *buf, size_t count);

  /* `poll` rather than `select`: one struct, the same shape on macOS and
     Linux, and no fd_set to declare differently per platform. */
  struct pollfd { int fd; short events; short revents; };
  int poll(struct pollfd *fds, unsigned long nfds, int timeout);

  /* Same four unsigned shorts everywhere; only the ioctl number differs. */
  struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
  int ioctl(int fd, unsigned long request, ...);
]]

local M = { open_count = 0 }

local POLLIN = 1
local STDIN = 0
-- TIOCGWINSZ is an encoded request number, and the encoding differs.
local TIOCGWINSZ = (jit.os == "OSX" or jit.os == "BSD") and 0x40087468 or 0x5413

local buf = ffi.new("char[64]")
local fds = ffi.new("struct pollfd[1]")
local ws = ffi.new("struct winsize[1]")

-- ------------------------------------------------------------ raw mode ----

local saved = nil

--- Take the terminal: raw keys, no echo, alternate screen, cursor hidden.
--- Returns false and a reason when there is no terminal to take, which is
--- the case under a pipe and in CI.
function M.open()
  if M.open_count > 0 then
    M.open_count = M.open_count + 1
    return true
  end
  local pipe = io.popen("stty -g 2>/dev/null")
  saved = pipe and pipe:read("*l") or nil
  if pipe then pipe:close() end
  if not saved or saved == "" then
    return false, "not a terminal"
  end
  -- `-icanon -echo -isig` rather than `raw`: Ctrl-C arrives as the key
  -- "ctrl-c" and the client decides what it means — stop the turn, or
  -- quit when idle — and leaves the terminal the way it found it either
  -- way. A wedged client is still killable from another shell.
  os.execute("stty -icanon -echo -isig min 1 time 0 2>/dev/null")
  io.write("\27[?1049h\27[?25l")   -- alternate screen, hide cursor
  io.flush()
  M.open_count = 1
  return true
end

--- Give it back. Safe to call twice, and safe to call when `open` failed:
--- a client that dies half way through must not leave a shell with no echo.
function M.close()
  if M.open_count == 0 then return end
  M.open_count = M.open_count - 1
  if M.open_count > 0 then return end
  io.write("\27[?25h\27[?1049l")   -- show cursor, leave alternate screen
  io.flush()
  if saved then
    os.execute("stty " .. saved .. " 2>/dev/null")
    saved = nil
  end
end

-- ---------------------------------------------------------------- size ----

--- Columns and rows. Falls back to 80x24, which is what every terminal
--- that will not answer is pretending to be anyway.
function M.size()
  if ffi.C.ioctl(STDIN, TIOCGWINSZ, ws) == 0 and ws[0].ws_col > 0 then
    return ws[0].ws_col, ws[0].ws_row
  end
  return 80, 24
end

-- ---------------------------------------------------------------- keys ----

--- The escape sequences worth naming. Anything else beginning with ESC is
--- reported as "escape" plus whatever followed, which the caller ignores.
local SEQUENCES = {
  ["[A"] = "up", ["[B"] = "down", ["[C"] = "right", ["[D"] = "left",
  ["[H"] = "home", ["[F"] = "end",
  ["[1~"] = "home", ["[4~"] = "end", ["[3~"] = "delete",
  ["[5~"] = "pageup", ["[6~"] = "pagedown",
  ["OA"] = "up", ["OB"] = "down", ["OC"] = "right", ["OD"] = "left",
  ["OH"] = "home", ["OF"] = "end",
}

--- Is there a byte waiting? `timeout` is in seconds; 0 asks and returns.
local function waiting(timeout)
  fds[0].fd = STDIN
  fds[0].events = POLLIN
  fds[0].revents = 0
  local ms = math.floor((timeout or 0) * 1000 + 0.5)
  return ffi.C.poll(fds, 1, ms) > 0
end

M.waiting = waiting

local function readByte()
  local n = ffi.C.read(STDIN, buf, 1)
  if n ~= 1 then return nil end
  return string.char(buf[0])
end

--- One key, or nil if none arrived within `timeout` seconds.
---
--- Returns a name for anything that is not a printable character:
--- "enter", "backspace", "escape", "up", "ctrl-r", and so on. A printable
--- character is returned as itself, so a caller appends it to its input
--- without a table lookup.
function M.key(timeout)
  if not waiting(timeout) then return nil end
  local c = readByte()
  if not c then return nil end
  local b = c:byte()

  if b == 13 or b == 10 then return "enter" end
  if b == 127 or b == 8 then return "backspace" end
  if b == 9 then return "tab" end
  if b == 27 then
    -- An escape *sequence* arrives in one burst; a lone Esc does not. So a
    -- byte that is not already waiting means the user pressed Escape.
    if not waiting(0.02) then return "escape" end
    local seq = ""
    for _ = 1, 6 do
      local next = readByte()
      if not next then break end
      seq = seq .. next
      if SEQUENCES[seq] then return SEQUENCES[seq] end
      -- A CSI sequence ends on a letter or a tilde; stop there rather than
      -- swallowing the keystroke after it.
      if #seq > 1 and next:match("[A-Za-z~]") then break end
    end
    return "escape"
  end
  if b < 32 then
    return "ctrl-" .. string.char(b + 96)
  end
  return c
end

-- -------------------------------------------------------------- drawing ----

local ESC = "\27["

function M.clear()
  io.write(ESC .. "2J")
end

--- Draw a frame. `body(out, w, h)` is handed a writer that places text at
--- a column and row, one-based, and the size to fit it into.
---
--- Everything is written into one buffer and flushed in a single `write`:
--- a screen painted piece by piece tears, and a screen painted while a
--- model streams tears visibly.
function M.frame(body)
  local w, h = M.size()
  local parts = { ESC .. "H" }
  local function out(x, y, text, style)
    parts[#parts + 1] = string.format("%s%d;%dH", ESC, y, x)
    if style then parts[#parts + 1] = style end
    parts[#parts + 1] = text
    if style then parts[#parts + 1] = ESC .. "0m" end
  end
  local function clearLine(y)
    parts[#parts + 1] = string.format("%s%d;1H%s0K", ESC, y, ESC)
  end
  body(out, w, h, clearLine)
  io.write(table.concat(parts))
  io.flush()
end

--- Put the cursor somewhere and show it: what a text field wants after the
--- rest of the frame has been drawn.
function M.cursor(x, y, visible)
  io.write(string.format("%s%d;%dH", ESC, y, x))
  io.write(visible and ESC .. "?25h" or ESC .. "?25l")
  io.flush()
end

-- Colours, as functions rather than constants so a caller can turn them
-- off in one place. NO_COLOR is honoured because a TUI that ignores it is
-- unusable on the terminals that set it.
M.colour = os.getenv("NO_COLOR") == nil

local function style(code)
  return function(text)
    if not M.colour then return text end
    return ESC .. code .. "m" .. text .. ESC .. "0m"
  end
end

M.bold = style("1")
M.dim = style("2")
M.cyan = style("36")
M.magenta = style("35")
M.green = style("32")
M.yellow = style("33")
M.red = style("31")
M.invert = style("7")

--- The raw code, for `frame`'s style argument, where the reset is added.
function M.code(...)
  if not M.colour then return nil end
  return ESC .. table.concat({ ... }, ";") .. "m"
end

--- The printable width of a string: characters, not bytes.
---
--- A model writes UTF-8, and counting its bytes would make one accented
--- word look three columns wider than it is — and, worse, would let `fit`
--- cut a character in half and leave the terminal decoding rubbish for the
--- rest of the line. Continuation bytes (`10xxxxxx`) are the ones not
--- counted.
function M.width(text)
  local plain = tostring(text or ""):gsub("\27%[[%d;?]*[A-Za-z]", "")
  local n = 0
  for i = 1, #plain do
    if plain:byte(i) < 0x80 or plain:byte(i) >= 0xC0 then n = n + 1 end
  end
  return n
end

--- Cut a string to `n` printable columns, on a character boundary.
--- Escape-free input only, which is everything this client puts through it.
function M.fit(text, n)
  text = tostring(text or "")
  if n <= 0 then return "" end
  if M.width(text) <= n then return text end
  -- Walk to the nth character, leaving room for the ellipsis.
  local want = n - 1
  local count, cut = 0, #text
  for i = 1, #text do
    local b = text:byte(i)
    if b < 0x80 or b >= 0xC0 then
      count = count + 1
      if count > want then cut = i - 1 break end
    end
  end
  return text:sub(1, cut) .. "…"
end

return M
