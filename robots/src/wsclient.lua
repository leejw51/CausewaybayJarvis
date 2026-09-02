-- A WebSocket client on luasocket, in plain Lua.
--
-- LÖVE ships luasocket and nothing above it, so this is the client side of
-- RFC 6455 in the two hundred lines it actually takes: the HTTP upgrade,
-- masked text frames out, frames of any length in, ping answered with pong,
-- close answered with close. No TLS — the server is on this machine — and
-- no extensions, because the server offers none.
--
--   local WS = require("src.wsclient")
--   local ws, err = WS.connect("127.0.0.1", port, "/ws")
--   ws:send('{"id":1,"op":"health"}')
--   local text = ws:receive(30)      -- the next text frame, or nil, why
--   ws:close()
--
-- Usable from a LÖVE worker thread and from plain LuaJIT alike: it needs
-- `socket` and nothing from `love`.

local socket = require("socket")

local WS = {}
WS.__index = WS

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Base64, for the handshake key. Small enough to keep here rather than
--- reach for `love.data`, which a plain LuaJIT process does not have.
function WS.base64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local q = {}
    for j = 4, 1, -1 do
      q[j] = B64:sub(n % 64 + 1, n % 64 + 1)
      n = math.floor(n / 64)
    end
    if not b then q[3] = "=" end
    if not c then q[4] = "=" end
    out[#out + 1] = table.concat(q)
  end
  return table.concat(out)
end

-- `bit.bxor` under LuaJIT; a slow fallback for a plain Lua 5.1.
local bit_xor
local hasBit, bit = pcall(require, "bit")
if hasBit and bit and bit.bxor then
  bit_xor = bit.bxor
else
  bit_xor = function(a, b)
    local r, p = 0, 1
    while a > 0 or b > 0 do
      local x, y = a % 2, b % 2
      if x ~= y then r = r + p end
      a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
  end
end

local function randomBytes(n)
  local t = {}
  for i = 1, n do t[i] = string.char(math.random(0, 255)) end
  return table.concat(t)
end

--- Open a WebSocket on `host:port` at `path`. Returns the socket, or nil and
--- why. `timeout` bounds the connect and the handshake, in seconds.
function WS.connect(host, port, path, timeout)
  local tcp = socket.tcp()
  tcp:settimeout(timeout or 5)
  local ok, err = tcp:connect(host, port)
  if not ok then
    tcp:close()
    return nil, "connect " .. host .. ":" .. tostring(port) .. ": " .. tostring(err)
  end
  tcp:setoption("tcp-nodelay", true)

  local key = WS.base64(randomBytes(16))
  local request = table.concat({
    "GET " .. (path or "/ws") .. " HTTP/1.1",
    "Host: " .. host .. ":" .. tostring(port),
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "", "",
  }, "\r\n")
  local sent, serr = tcp:send(request)
  if not sent then
    tcp:close()
    return nil, "handshake send: " .. tostring(serr)
  end

  local status, rerr = tcp:receive("*l")
  if not status then
    tcp:close()
    return nil, "handshake: " .. tostring(rerr)
  end
  if not status:match("^HTTP/1%.1 101") then
    tcp:close()
    return nil, "handshake refused: " .. status
  end
  -- The headers, up to the blank line. The accept key is not checked: the
  -- only server this ever talks to is the one that just said 101.
  while true do
    local line, herr = tcp:receive("*l")
    if not line then
      tcp:close()
      return nil, "handshake headers: " .. tostring(herr)
    end
    if line == "" then break end
  end

  return setmetatable({ tcp = tcp, open = true }, WS)
end

--- One frame out. `opcode` 1 is text (the default), 8 close, 9 ping, 10
--- pong. A client masks every frame; the server refuses one that is not.
function WS:sendFrame(payload, opcode)
  if not self.open then return nil, "closed" end
  opcode = opcode or 1
  local len = #payload
  local head = { string.char(0x80 + opcode) }
  if len < 126 then
    head[#head + 1] = string.char(0x80 + len)
  elseif len < 65536 then
    head[#head + 1] = string.char(0x80 + 126, math.floor(len / 256), len % 256)
  else
    local bytes = {}
    local n = len
    for i = 8, 1, -1 do
      bytes[i] = string.char(n % 256)
      n = math.floor(n / 256)
    end
    head[#head + 1] = string.char(0x80 + 127) .. table.concat(bytes)
  end
  local mask = randomBytes(4)
  local m = { mask:byte(1, 4) }
  local masked = {}
  -- Masked in chunks: a string.char call per byte on a long turn would be
  -- the slowest thing in the client.
  for i = 1, len, 4096 do
    local piece = payload:sub(i, i + 4095)
    local bytes = { piece:byte(1, -1) }
    for j = 1, #bytes do
      local k = ((i + j - 2) % 4) + 1
      bytes[j] = bit_xor(bytes[j], m[k])
    end
    masked[#masked + 1] = string.char(unpack(bytes))
  end
  local frame = table.concat(head) .. mask .. table.concat(masked)
  local ok, err = self.tcp:send(frame)
  if not ok then
    self.open = false
    return nil, err
  end
  return true
end

--- A text frame out.
function WS:send(text)
  return self:sendFrame(text, 1)
end

local function readExact(tcp, n)
  if n == 0 then return "" end
  local data, err, partial = tcp:receive(n)
  if not data then return nil, err, partial end
  return data
end

--- The next text frame, as a string, or nil and why. `timeout` is in
--- seconds and bounds the whole wait, so a caller can put a turn's budget
--- on it. Pings are answered here; a close is answered and reported as
--- "closed". Continuation frames are joined.
function WS:receive(timeout)
  if not self.open then return nil, "closed" end
  self.tcp:settimeout(timeout or 30)
  local message = nil
  while true do
    local head, err = readExact(self.tcp, 2)
    if not head then
      if err ~= "timeout" then self.open = false end
      return nil, err
    end
    local b1, b2 = head:byte(1, 2)
    local fin = b1 >= 128
    local opcode = b1 % 16
    local masked = b2 >= 128
    local len = b2 % 128
    if len == 126 then
      local ext = readExact(self.tcp, 2)
      if not ext then self.open = false return nil, "closed" end
      local hi, lo = ext:byte(1, 2)
      len = hi * 256 + lo
    elseif len == 127 then
      local ext = readExact(self.tcp, 8)
      if not ext then self.open = false return nil, "closed" end
      len = 0
      for i = 1, 8 do len = len * 256 + ext:byte(i) end
    end
    local mask
    if masked then
      mask = readExact(self.tcp, 4)
      if not mask then self.open = false return nil, "closed" end
    end
    local payload, perr = readExact(self.tcp, len)
    if not payload then
      self.open = false
      return nil, perr or "closed"
    end
    if mask then
      local m = { mask:byte(1, 4) }
      local bytes = { payload:byte(1, -1) }
      for j = 1, #bytes do bytes[j] = bit_xor(bytes[j], m[((j - 1) % 4) + 1]) end
      payload = string.char(unpack(bytes))
    end

    if opcode == 8 then
      -- Close: answer in kind, then report it.
      self:sendFrame(payload:sub(1, 2), 8)
      self.open = false
      self.tcp:close()
      return nil, "closed"
    elseif opcode == 9 then
      self:sendFrame(payload, 10)
    elseif opcode == 10 then
      -- a pong: nothing to do
    elseif opcode == 1 or opcode == 2 or opcode == 0 then
      message = (message or "") .. payload
      if fin then return message end
    end
  end
end

--- Say goodbye and drop the socket.
function WS:close()
  if self.open then
    self:sendFrame(string.char(0x03, 0xE8), 8)  -- 1000: normal
    self.open = false
  end
  self.tcp:close()
end

return WS
