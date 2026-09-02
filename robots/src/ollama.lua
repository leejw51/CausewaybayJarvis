-- ollama.com / local-daemon chat API. Config lives in .env:
--   OLLAMA_API_KEY, OLLAMA_MODEL, OLLAMA_HOST, OLLAMA_THINK
--
-- LOVE 11.5 ships no https module, so every request is handed to a worker
-- thread that shells out to curl. Nothing blocks the render loop: ask()
-- returns immediately and update() delivers the reply on a later frame.

local Env = require("src.env")
local Json = require("src.json")
local Store = require("src.store")
local Backend = require("src.backend")

local DEFAULT_HOST = "https://ollama.com"
local DEFAULT_MODEL = "gpt-oss:20b"
local DEFAULT_THINK = "low"
local TIMEOUT = 45
local PROBE_TIMEOUT = 20
local TMPDIR = "tmp"
-- Reasoning models spend part of this budget on hidden thinking before a
-- single visible word appears; too small a cap returns done_reason=length
-- and an empty message, so keep real headroom above the ~30 words we want.
local NUM_PREDICT = 400
local RETRY_PREDICT = 700

local Ollama = {
  enabled = false,
  host = DEFAULT_HOST,
  model = DEFAULT_MODEL,
  think = DEFAULT_THINK,
  cloud = true,        -- do prompts leave this machine?
  where = "CLOUD AI",  -- one-word provenance for the boot report
  reason = "not initialized",
  info = nil,          -- specs from /api/show + /api/tags, once probed
  probe = "idle",      -- idle | pending | done
  inflight = 0,
  calls = 0,
  lastError = nil,
}

local thread, jobs, results
local pending = {}
local nextId = 0
local probeLeft = 0
local key

local function cfgEscape(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

-- OLLAMA_THINK accepts a reasoning level ("low"/"medium"/"high") or an
-- off switch. gpt-oss ignores think=false and reasons anyway, so "low" is
-- the useful default: it keeps the hidden preamble short.
local function parseThink(v)
  v = tostring(v or ""):lower():gsub("%s", "")
  if v == "low" or v == "medium" or v == "high" then return v end
  if v == "" or v == "true" or v == "on" then return DEFAULT_THINK end
  return false
end

-- A host on this machine runs the weights here; anything else is a relay.
-- A local daemon can still proxy ollama.com, and those tags carry -cloud.
local function classify(host, model)
  local h = host:lower()
  local onBox = h:find("localhost", 1, true) or h:find("127.0.0.1", 1, true)
    or h:find("0.0.0.0", 1, true) or h:find("[::1]", 1, true)
  if not onBox then return true, "CLOUD AI" end
  if model:lower():find("%-cloud$") then return true, "CLOUD RELAY" end
  return false, "ON-DEVICE"
end

function Ollama.init()
  Env.load()
  key = Env.get("OLLAMA_API_KEY")
  Ollama.host = (Env.get("OLLAMA_HOST", DEFAULT_HOST)):gsub("/+$", "")
  Ollama.model = Env.get("OLLAMA_MODEL", DEFAULT_MODEL)
  Ollama.think = parseThink(Env.get("OLLAMA_THINK", DEFAULT_THINK))
  Ollama.cloud, Ollama.where = classify(Ollama.host, Ollama.model)
  Ollama.info = nil
  Ollama.probe = "idle"

  if not key and Ollama.cloud then
    Ollama.enabled = false
    Ollama.reason = "NO OLLAMA_API_KEY IN .ENV"
    return false
  end

  if not love.thread then
    Ollama.enabled = false
    Ollama.reason = "THREAD MODULE OFF"
    return false
  end

  jobs = love.thread.getChannel("ollama.jobs")
  results = love.thread.getChannel("ollama.results")
  thread = love.thread.newThread("src/ollama_worker.lua")
  thread:start()

  Ollama.enabled = true
  Ollama.reason = "LINK READY"
  Ollama.askSpecs()
  return true
end

function Ollama.shutdown()
  if jobs then jobs:push("quit") end
end

-- One curl job: writes the JSON body (if any) and a curl config carrying
-- the key, so the token never appears in a process command line.
local function submit(path, payload, entry)
  nextId = nextId + 1
  local id = nextId
  local bodyPath

  local cfg = {
    string.format('url = "%s%s"', cfgEscape(Ollama.host), path),
    'header = "Content-Type: application/json"',
    string.format("max-time = %d", entry.timeout or TIMEOUT),
    "silent",
    "show-error",
  }
  if key then
    table.insert(cfg, 2, string.format('header = "Authorization: Bearer %s"', cfgEscape(key)))
  end

  if payload then
    local ok, where = Store.write(string.format("%s/req_%d.json", TMPDIR, id), Json.encode(payload))
    if not ok then return nil, "CANNOT WRITE REQUEST" end
    bodyPath = where
    cfg[#cfg + 1] = string.format('data = "@%s"', cfgEscape(bodyPath))
  end

  local okCfg, cfgPath = Store.write(string.format("%s/req_%d.cfg", TMPDIR, id),
    table.concat(cfg, "\n") .. "\n")
  if not okCfg then
    if bodyPath then os.remove(bodyPath) end
    return nil, "CANNOT WRITE CONFIG"
  end

  entry.t = 0
  pending[id] = entry
  if entry.kind == "chat" then
    Ollama.inflight = Ollama.inflight + 1
    Ollama.calls = Ollama.calls + 1
  end
  jobs:push({ id = id, cfg = cfgPath, body = bodyPath })
  return id
end

-- messages: array of { role = "system"|"user"|"assistant"|"tool", content = "..." }
-- opts.tools: tool schema the model may call.
-- cb(text, err, msg) is called on a later frame, always exactly once. msg is
-- the raw assistant message, which carries tool_calls when the model wants
-- to act before it answers.
-- ---------------------------------------------------------- the backend --
--
-- When `agentd` is up, every turn from here goes through it: the console
-- and the autopilot then obey the same brain choice as the robots — F9,
-- the AI tab, `agentd provider` — instead of dialling a link of their own
-- from .env. The curl path below is what a checkout with no backend built
-- falls back to, and nothing else.

--- Is there a backend brain to send a turn to?
function Ollama.viaBackend()
  local p = Backend.ready and Backend.provider or nil
  return p ~= nil and p.effective ~= nil and p.effective ~= "offline"
end

--- Can anything answer a turn, by either road?
function Ollama.available()
  return Ollama.viaBackend() or Ollama.enabled
end

--- One picture for the header and the boot panel: which road, where the
--- prompt goes, and which model. Pure over the two states, for the tests.
function Ollama.status()
  if Ollama.viaBackend() then
    local p = Backend.provider
    local cloud = p.effective == "cloud"
    local model = cloud and (p.cloud and p.cloud.model)
      or (p.ondevice and p.ondevice.model) or "?"
    local where = cloud and "CLOUD AI" or "ON-DEVICE"
    if not cloud and p.ondevice and p.ondevice.engine == "ollama" then where = "ON-DEVICE (OLLAMA)" end
    return { enabled = true, cloud = cloud, where = where, model = tostring(model), via = "agentd" }
  end
  return {
    enabled = Ollama.enabled, cloud = Ollama.cloud, where = Ollama.where,
    model = Ollama.model, via = "curl",
  }
end

local function askBackend(messages, cb, opts)
  Ollama.inflight = Ollama.inflight + 1
  Ollama.calls = Ollama.calls + 1
  local sent = Backend.call({
    op = "brain.chat", messages = messages, tools = opts.tools,
  }, function(data, err)
    Ollama.inflight = math.max(0, Ollama.inflight - 1)
    if err then
      Ollama.lastError = err
      if cb then cb(nil, err) end
      return
    end
    local msg = data and data.message or {}
    if cb then cb(msg.content, nil, msg) end
  end)
  if not sent then
    Ollama.inflight = math.max(0, Ollama.inflight - 1)
    return false, Backend.reason
  end
  return true
end

function Ollama.ask(messages, cb, opts)
  opts = opts or {}
  if Ollama.viaBackend() then
    return askBackend(messages, cb, opts)
  end
  if not Ollama.enabled then
    return false, Ollama.reason
  end

  local think = opts.think
  if think == nil then think = Ollama.think end

  local payload = {
    model = Ollama.model,
    messages = messages,
    stream = false,
    think = think,
    options = { temperature = 0.7, num_predict = opts.numPredict or NUM_PREDICT },
  }
  if opts.tools then payload.tools = opts.tools end

  local id, err = submit("/api/chat", payload, {
    kind = "chat", cb = cb, messages = messages, tools = opts.tools,
    retried = opts.retried or false,
  })

  if not id then return false, err end
  return true
end

-- What model is actually answering: parameters, quantization, context and
-- weight size. /api/show knows the shape, /api/tags knows the disk size.
function Ollama.askSpecs()
  if not Ollama.enabled or Ollama.probe == "pending" then return false end
  Ollama.probe = "pending"
  Ollama.info = { name = Ollama.model }
  probeLeft = 2
  submit("/api/show", { model = Ollama.model }, { kind = "show", timeout = PROBE_TIMEOUT })
  submit("/api/tags", nil, { kind = "tags", timeout = PROBE_TIMEOUT })
  return true
end

local function finish(id, text, err, msg)
  local p = pending[id]
  if not p then return end
  pending[id] = nil
  if p.kind == "chat" then
    Ollama.inflight = math.max(0, Ollama.inflight - 1)
  end
  if err then Ollama.lastError = err end
  if p.cb then p.cb(text, err, msg) end
end

-- One second chance for a turn that produced only hidden reasoning (or a
-- model that rejects the think field outright): no thinking, more room.
local function retry(id, p)
  pending[id] = nil
  Ollama.inflight = math.max(0, Ollama.inflight - 1)
  local ok = Ollama.ask(p.messages, p.cb, {
    think = false, numPredict = RETRY_PREDICT, retried = true, tools = p.tools,
  })
  if not ok and p.cb then p.cb(nil, "REASONING OVERRAN THE BUDGET") end
end

local function decode(raw)
  if not raw or raw:gsub("%s", "") == "" then
    return nil, "EMPTY REPLY FROM OLLAMA"
  end
  local obj = Json.decode(raw)
  if type(obj) ~= "table" then
    return nil, "BAD REPLY: " .. raw:gsub("%s+", " "):sub(1, 90)
  end
  if obj.error then
    local e = type(obj.error) == "table" and (obj.error.message or "ERROR") or tostring(obj.error)
    return nil, e:gsub("%s+", " "):sub(1, 120)
  end
  return obj
end

-- returns text, err, retryable, msg
local function parse(raw)
  local obj, err = decode(raw)
  if not obj then return nil, err end
  local msg = type(obj.message) == "table" and obj.message or nil
  local text = msg and msg.content or nil
  local calls = msg and type(msg.tool_calls) == "table" and #msg.tool_calls > 0

  if type(text) ~= "string" or text:gsub("%s", "") == "" then
    -- Empty content plus tool_calls is the model asking to act first.
    if calls then return "", nil, false, msg end
    -- All of the token budget went into hidden reasoning: worth one retry
    -- with thinking off and more room, rather than a dead turn.
    local thought = msg and type(msg.thinking) == "string"
      and msg.thinking:gsub("%s", "") ~= ""
    if thought or obj.done_reason == "length" then
      return nil, "REASONING OVERRAN THE BUDGET", true
    end
    return nil, "NO CONTENT IN REPLY"
  end
  return text, nil, false, msg
end

-- specs -----------------------------------------------------------------

local function fmtParams(v)
  local n = tonumber(v)
  if not n then
    v = tostring(v or ""):upper()
    return v ~= "" and v or nil
  end
  if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.0fM", n / 1e6) end
  return tostring(n)
end

local function fmtBytes(n)
  n = tonumber(n)
  if not n or n <= 0 then return nil end
  if n >= 1024 * 1024 * 1024 then return string.format("%.1f GB", n / (1024 * 1024 * 1024)) end
  return string.format("%.0f MB", n / (1024 * 1024))
end

local function fmtCtx(n)
  n = tonumber(n)
  if not n or n <= 0 then return nil end
  if n >= 1024 then return string.format("%dK", math.floor(n / 1024 + 0.5)) end
  return tostring(n)
end

local function readShow(obj)
  local i = Ollama.info
  if not i then return end
  local d = type(obj.details) == "table" and obj.details or {}
  local mi = type(obj.model_info) == "table" and obj.model_info or {}
  i.params = fmtParams(mi["general.parameter_count"]) or fmtParams(d.parameter_size)
  if d.quantization_level and d.quantization_level ~= "" then
    i.quant = tostring(d.quantization_level):upper()
  end
  if d.family and d.family ~= "" then i.family = tostring(d.family):upper() end
  for k, v in pairs(mi) do
    if type(k) == "string" and k:find("%.context_length$") then
      i.ctx = fmtCtx(v)
    end
  end
  if type(obj.modified_at) == "string" then i.built = obj.modified_at:sub(1, 10) end
  if type(obj.capabilities) == "table" then
    for _, c in ipairs(obj.capabilities) do
      if c == "thinking" then i.thinks = true end
    end
  end
end

local function readTags(obj)
  local i = Ollama.info
  if not i or type(obj.models) ~= "table" then return end
  for _, m in ipairs(obj.models) do
    if m.name == Ollama.model or m.model == Ollama.model then
      i.size = fmtBytes(m.size)
      if type(m.digest) == "string" then i.build = m.digest:sub(1, 8):upper() end
      if not i.built and type(m.modified_at) == "string" then i.built = m.modified_at:sub(1, 10) end
      return
    end
  end
end

local function specsDone()
  probeLeft = math.max(0, probeLeft - 1)
  if probeLeft == 0 then Ollama.probe = "done" end
end

-- Boot-report lines: { text = ..., tone = "good"|"info"|"warn" }.
function Ollama.report()
  local out = {}
  if Ollama.viaBackend() then
    -- The console rides the agent brain; say so, and where that is.
    local st = Ollama.status()
    out[#out + 1] = { text = "SWARM CHAT  VIA THE AGENT BRAIN  (F9)", tone = "good" }
    out[#out + 1] = {
      text = st.where .. "  " .. st.model:upper(),
      tone = st.cloud and "info" or "good",
    }
    if st.cloud then
      out[#out + 1] = { text = "CAUTION  PROMPTS LEAVE THIS MACHINE", tone = "warn" }
    end
    return out
  end
  if not Ollama.enabled then
    out[#out + 1] = { text = "OFFLINE  " .. Ollama.reason, tone = "warn" }
    out[#out + 1] = { text = "LOCAL CENTRAL ONLY. NO MODEL, SIR.", tone = "info" }
    return out
  end

  local hostLabel = Ollama.host:gsub("^%a+://", ""):gsub("/+$", ""):upper()
  out[#out + 1] = {
    text = string.format("%s  %s", Ollama.where, hostLabel),
    tone = Ollama.cloud and "info" or "good",
  }

  local i = Ollama.info
  local spec = {}
  if i then
    if i.params then spec[#spec + 1] = i.params end
    if i.quant then spec[#spec + 1] = i.quant end
    if i.size then spec[#spec + 1] = i.size end
  end
  if #spec > 0 then
    out[#out + 1] = { text = "MODEL " .. Ollama.model:upper() .. "  " .. table.concat(spec, "  "), tone = "info" }
  elseif Ollama.probe == "pending" then
    out[#out + 1] = { text = "MODEL " .. Ollama.model:upper() .. "  READING SPECS...", tone = "info" }
  else
    out[#out + 1] = { text = "MODEL " .. Ollama.model:upper(), tone = "info" }
  end

  local line2 = {}
  if i and i.ctx then line2[#line2 + 1] = "CTX " .. i.ctx end
  if i and i.built then line2[#line2 + 1] = "REL " .. i.built end
  if i and i.build then line2[#line2 + 1] = "BUILD " .. i.build end
  if #line2 > 0 then
    out[#out + 1] = { text = table.concat(line2, "  "), tone = "info" }
  end

  if Ollama.cloud then
    out[#out + 1] = { text = "CAUTION  PROMPTS LEAVE THIS MACHINE", tone = "warn" }
    out[#out + 1] = { text = "KEEP PRIVATE DATA OFF THE LINK, SIR", tone = "warn" }
  end
  return out
end

function Ollama.update(dt)
  if not Ollama.enabled then return end

  while true do
    local r = results and results:pop()
    if not r then break end
    if type(r) == "table" and pending[r.id] then
      local p = pending[r.id]
      if p.kind == "chat" then
        if r.err then
          finish(r.id, nil, r.err:upper())
        else
          local text, err, retryable, msg = parse(r.raw)
          if err and not text and not p.retried
            and (retryable or err:lower():find("think", 1, true)) then
            retry(r.id, p)
          else
            finish(r.id, text, err and err:upper(), msg)
          end
        end
      else
        pending[r.id] = nil
        local obj = (not r.err) and decode(r.raw) or nil
        if obj then
          if p.kind == "show" then readShow(obj) else readTags(obj) end
        end
        specsDone()
      end
    end
  end

  for id, p in pairs(pending) do
    p.t = p.t + dt
    local cap = (p.timeout or TIMEOUT) + 10
    if p.t > cap then
      if p.kind == "chat" then
        finish(id, nil, "OLLAMA TIMED OUT")
      else
        pending[id] = nil
        specsDone()
      end
    end
  end
end

function Ollama.busy()
  return Ollama.inflight > 0
end

-- Pure helpers, reached by tests/ so the reply parsing and the cloud/on-device
-- call can be checked against captured API bodies without a network round trip.
Ollama._test = {
  parseThink = parseThink,
  classify = classify,
  parse = parse,
  decode = decode,
  readShow = readShow,
  readTags = readTags,
  fmtParams = fmtParams,
  fmtBytes = fmtBytes,
  fmtCtx = fmtCtx,
}

return Ollama
