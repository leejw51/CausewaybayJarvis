-- The other seam: the same backend, called instead of connected to.
--
-- `libjarvis` carries the whole robot backend, and the worker thread calls it
-- in this process when there is no daemon already holding the space. That is
-- what the packaged app runs on — one thing to install, nothing to start —
-- so it needs the same proof the daemon gets next door in test_agentd.lua:
-- not that the Lua is shaped right, but that the two sides actually talk.
--
-- Same round trip, then: seed a roster, file a picture, find it three ways,
-- hold a streamed turn, and be refused properly. And one assertion the daemon
-- suite cannot make — that no second process was started at all.
--
-- Skipped, not failed, when the library has not been built: a checkout that
-- has only run `make agentd` should still get a green suite.

local Backend = require("src.backend")
local Robots = require("src.robots")
local Store = require("src.store")

local function await(request, seconds)
  local done, out, err = false, nil, nil
  Backend.call(request, function(d, e)
    done, out, err = true, d, e
  end)
  local deadline = love.timer.getTime() + (seconds or 30)
  while not done and love.timer.getTime() < deadline do
    love.timer.sleep(0.005)
    Backend.update(0.005)
  end
  if not done then return nil, "TIMED OUT WAITING FOR " .. tostring(request.op) end
  return out, err
end

return function(F)
  F.describe("libjarvis / the backend in this process")

  -- Whatever the suite before this one pinned, this one is about the library.
  Backend.useLib = nil

  if not Backend.findLib() then
    F.skip("the whole suite", "libjarvis is not built -- run `make ffi`")
    return
  end

  local stamp = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  local scratch = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/jarvis-libjarvis-" .. stamp
  local wasHome, wasEnv = Backend.home, Backend.env
  local wasStore = Store.dir

  Backend.home = scratch
  -- Both brains shut, as next door: this suite is about the seam and the
  -- archive, and must not spend twenty seconds loading a model to prove that
  -- a function call works.
  Backend.env = {
    OLLAMA_API_KEY = "",
    OLLAMA_HOST = "https://ollama.com",
    JARVIS_NO_MLX = "1",
    ONDEVICE_ENGINE = "off",
  }
  Store.use(scratch .. "/love")

  -- A fresh space nobody is serving, so the worker takes the library.
  Backend.init()
  if not Backend.ready then
    F.skip("the whole suite", Backend.reason)
    return
  end

  local coding, photo

  F.it("runs the backend in this process, with nothing to connect to", function()
    F.eq(Backend.inProcess, true, "this suite must be calling the library")
    F.ok(Backend.lib ~= nil, "no library was handed to the worker")
  end)

  F.it("opens a space and seeds a roster of robots with faces", function()
    local data, err = await({ op = "agents.list" })
    F.eq(err, nil)
    F.ok(type(data) == "table" and #data >= 8, "a thin roster")
    for _, r in ipairs(data) do
      F.ok(r.id and #r.id == 36, "a robot without a GUID")
      if r.slug == "coding" then coding = r end
    end
    F.ok(coding, "no coding robot on the roster")
  end)

  F.it("reports where the prompts would go, and which space is open", function()
    local data, err = await({ op = "health" })
    F.eq(err, nil)
    F.eq(data.online, false, "the key was supposed to be blanked")
    F.has(data.root, "jarvis-libjarvis-")
  end)

  F.it("files a picture into that robot's own photo shelf", function()
    local source = love.filesystem.getSource() .. "/assets/agent_byte.png"
    local data, err = await({ op = "item.add", agent = coding.id, path = source,
      title = "a robot", body = "the byte robot, standing" })
    F.eq(err, nil)
    F.eq(data.kind, "image")
    F.has(data.path, "agents/" .. coding.id .. "/photos/")
    local f = io.open(data.abs, "rb")
    F.ok(f, "no file at " .. tostring(data.abs))
    if f then f:close() end
    photo = data
  end)

  F.it("finds it again with BM25, with vectors, and with both", function()
    for _, mode in ipairs({ "bm25", "semantic", "hybrid" }) do
      local data, err = await({ op = "search", agent = coding.id,
        query = "the byte robot standing", mode = mode })
      F.eq(err, nil, mode .. " failed")
      F.eq(data.mode, mode)
      F.ok(#data.hits >= 1, mode .. " found nothing")
      F.eq(data.hits[1].item.id, photo.id, mode .. " ranked the wrong row first")
    end
  end)

  F.it("streams a turn: the pieces arrive first, and they are the answer", function()
    local chunks = {}
    local done, out, err = false, nil, nil
    Backend.call({ op = "chat", agent = coding.id, text = "what did I show you?" },
      function(d, e) done, out, err = true, d, e end,
      { onChunk = function(kind, text)
          if kind == "token" then chunks[#chunks + 1] = text end
        end })
    local deadline = love.timer.getTime() + 60
    while not done and love.timer.getTime() < deadline do
      love.timer.sleep(0.005)
      Backend.update(0.005)
    end
    F.eq(err, nil)
    F.ok(out ~= nil and type(out.reply) == "string", "no answer in the turn")
    F.ok(#chunks > 0, "nothing was streamed at all")
    F.eq(table.concat(chunks), out.reply, "the pieces are not the answer")
  end)

  F.it("answers a bad request with a sentence rather than a crash", function()
    local data, err = await({ op = "page", agent = "no-such-robot" })
    F.eq(data, nil)
    F.has(err, "NO ROBOT")
    local _, err2 = await({ op = "drop.everything" })
    F.has(err2, "UNKNOWN OP")
  end)

  F.it("started no daemon, and left none behind", function()
    -- The port file is written by `agentd listen` on the way up and removed
    -- on the way down. A space that has been worked this hard without one
    -- ever appearing was never served by a second process.
    local f = io.open(scratch .. "/agentd.port", "rb")
    F.eq(f, nil, "something started a daemon on a space that did not need one")
    if f then f:close() end
  end)

  Robots.reset()
  Backend.home, Backend.env = wasHome, wasEnv
  Store.use(wasStore)
  if os.getenv("JARVIS_TEST_KEEP") == "1" then
    print("  kept  " .. scratch)
  else
    os.execute(string.format("rm -rf '%s' 2>/dev/null", scratch:gsub("'", "'\\''")))
  end
end
