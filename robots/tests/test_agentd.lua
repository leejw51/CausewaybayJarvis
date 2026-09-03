-- The real daemon, through the real bridge.
--
-- This is the seam nothing else covers: the Rust side is tested in Rust and
-- the Lua side is tested with fixtures, but *whether the two actually talk* is
-- only answered by running one. So this suite starts the worker thread, points
-- it at a scratch space, and drives a whole conversation through it — seed the
-- roster, file a picture, search for it three ways, hold a turn, read the
-- page — and asserts on what comes back.
--
-- It is skipped, not failed, when `agentd` has not been built: a checkout that
-- has only run `make` on the Lua side should still get a green suite.

local Backend = require("src.backend")
local Robots = require("src.robots")
local Store = require("src.store")

--- Run one request and spin the frame loop until it answers. The bridge is
--- asynchronous by design; a test is the one place that wants to wait.
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
  F.describe("agentd / the real daemon")

  local bin = Backend.find()
  if not bin then
    F.skip("the whole suite", "agentd is not built -- run `make robots`")
    return
  end

  local stamp = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
  local scratch = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/jarvis-agentd-" .. stamp
  local wasHome, wasEnv = Backend.home, Backend.env
  local wasStore = Store.dir

  Backend.home = scratch
  -- Both brains deliberately shut, whatever this machine has: a blank key
  -- closes the cloud (a blank value is "unset"), JARVIS_NO_MLX keeps an
  -- engine-carrying binary off its engine, and ONDEVICE_ENGINE=off keeps an
  -- ollama daemon that happens to be running here out of it. The suite is
  -- about the bridge and the archive, and it must not spend twenty seconds
  -- loading a model to prove a socket works.
  Backend.env = {
    OLLAMA_API_KEY = "",
    OLLAMA_HOST = "https://ollama.com",
    JARVIS_NO_MLX = "1",
    ONDEVICE_ENGINE = "off",
  }
  Store.use(scratch .. "/love")

  if not Backend.ready then Backend.init() end
  if not Backend.ready then
    F.skip("the whole suite", Backend.reason)
    return
  end

  local roster, coding, photo

  F.it("runs against a server in its own process, over a WebSocket", function()
    F.eq(Backend.inProcess, false, "the client must load nothing")
    F.eq(Backend.reason, "BACKEND READY")
  end)

  F.it("opens a space and seeds a roster of robots with faces", function()
    local data, err = await({ op = "agents.list" })
    F.eq(err, nil)
    F.ok(type(data) == "table" and #data >= 8, "a thin roster")
    roster = data
    for _, r in ipairs(roster) do
      F.ok(r.id and #r.id == 36, "a robot without a GUID")
      F.eq(r.space, "agents/" .. r.id, "the folder is not the GUID")
      F.ok(love.filesystem.getInfo("assets/agent_" .. r.sprite .. ".png") ~= nil,
        "no sprite for " .. tostring(r.sprite))
      if r.slug == "coding" then coding = r end
    end
    F.ok(coding, "no coding robot on the roster")
  end)

  F.it("reports where the prompts would go", function()
    local data, err = await({ op = "health" })
    F.eq(err, nil)
    F.eq(data.online, false, "the key was supposed to be blanked")
    F.has(data.root, "jarvis-agentd-")
  end)

  F.it("files a picture into that robot's own photo shelf", function()
    -- A real PNG, from the assets this client draws with.
    local source = love.filesystem.getSource() .. "/assets/agent_byte.png"
    local data, err = await({ op = "item.add", agent = coding.id, path = source,
      title = "a robot", body = "the byte robot, standing" })
    F.eq(err, nil)
    F.eq(data.kind, "image")
    F.eq(data.mime, "image/png")
    F.has(data.path, "agents/" .. coding.id .. "/photos/")
    F.match(data.path, "^agents/", "the stored path is not relative")
    F.ok(data.bytes > 0)
    -- The file really is where the row says it is.
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

  F.it("keeps the robot's folder complete: its own database and three mirrors", function()
    local root = scratch .. "/" .. coding.space
    for _, name in ipairs({ "agent.db", "items.jsonl", "items.csv", "agent.md" }) do
      local f = io.open(root .. "/" .. name, "rb")
      F.ok(f, "no " .. name .. " in " .. root)
      if f then
        local body = f:read("*a")
        f:close()
        if name ~= "agent.db" then
          F.has(body, "a robot", name .. " does not carry the photo")
        end
        if name == "agent.md" then
          F.has(body, coding.id, "the page does not name the GUID")
          F.has(body, "| photos | 1 |")
        end
      end
    end
  end)

  F.it("keeps one robot's archive out of another's search", function()
    local other
    for _, r in ipairs(roster) do
      if r.slug ~= "coding" then other = r break end
    end
    local data, err = await({ op = "search", agent = other.id,
      query = "the byte robot standing", mode = "hybrid" })
    F.eq(err, nil)
    F.eq(#data.hits, 0, "the archive leaked into " .. other.slug)
  end)

  F.it("searches every robot at once when nobody is chosen", function()
    local food
    for _, r in ipairs(roster) do
      if r.slug == "food" then food = r end
    end
    local note = await({ op = "item.add", agent = food.id, body = "the byte robot standing by the stove" })
    F.ok(note and note.id, "could not file the food note")
    -- No agent named at all: the reply says it looked everywhere, and the
    -- hits say who knew.
    local data, err = await({ op = "search", query = "the byte robot standing", mode = "bm25" })
    F.eq(err, nil)
    F.eq(data.scope, "all")
    F.ok(#data.hits >= 2, "expected both robots' rows, got " .. #data.hits)
    local owners = {}
    for _, hit in ipairs(data.hits) do owners[hit.agent_name] = true end
    F.ok(owners[coding.name], "no hit from " .. coding.name)
    F.ok(owners[food.name], "no hit from " .. food.name)
    -- The client's own helper leaves the agent out when nobody is chosen.
    Robots.selected = nil
    local done, got = false, nil
    Robots.search("the byte robot standing", "hybrid", function(d) done, got = true, d end)
    local deadline = love.timer.getTime() + 20
    while not done and love.timer.getTime() < deadline do
      love.timer.sleep(0.005)
      Backend.update(0.005)
    end
    F.ok(done, "the search never came back")
    F.eq(got.scope, "all")
    -- The unified search: a robot is chosen, and the search still reaches
    -- every one — the SEARCH ALL button on the chat page.
    Robots.selected = coding.id
    done, got = false, nil
    Robots.search("the byte robot standing", "bm25", function(d) done, got = true, d end, { all = true })
    deadline = love.timer.getTime() + 20
    while not done and love.timer.getTime() < deadline do
      love.timer.sleep(0.005)
      Backend.update(0.005)
    end
    F.ok(done, "the unified search never came back")
    F.eq(got.scope, "all")
    F.ok(#got.hits >= 2, "the unified search did not reach the other robot")
    local Actions = require("src.actions")
    local said = {}
    Actions.run("search", "the byte robot standing", function(text) said[#said + 1] = text end, { all = true })
    deadline = love.timer.getTime() + 20
    while #said == 0 and love.timer.getTime() < deadline do
      love.timer.sleep(0.005)
      Backend.update(0.005)
    end
    F.has(said[1] or "", "ALL AGENTS", "the unified search did not say how far it reached")
    Robots.selected = nil
    -- The row goes as `item`: over the socket `id` is the frame's number.
    local gone, derr = await({ op = "item.delete", item = note.id })
    F.eq(derr, nil)
    F.eq(gone.deleted, true)
  end)

  F.it("lists every photo by the folder that holds it", function()
    local data, err = await({ op = "gallery" })
    F.eq(err, nil)
    F.eq(data.total, 1)
    local mine
    for _, g in ipairs(data.groups) do
      if g.agent and g.agent.id == coding.id then mine = g end
    end
    F.ok(mine, "no group for the coding robot")
    F.eq(mine.count, 1)
    F.eq(mine.photos[1].id, photo.id)
    F.has(mine.folder, "/photos")
    local flat = Robots.flattenGallery(data)
    F.eq(#flat, 1)
    F.eq(flat[1].agent_name, coding.name)
  end)

  F.it("draws the robot's paper: one 1024x1024 PNG in its paper folder", function()
    local sprite = love.filesystem.getSource() .. "/assets/agent_" .. coding.sprite .. ".png"
    local data, err = await({ op = "paper", agent = coding.id, sprite = sprite }, 60)
    F.eq(err, nil)
    F.eq(data.width, 1024)
    F.eq(data.height, 1024)
    F.has(data.path, "agents/" .. coding.id .. "/paper/coding-")
    local f = io.open(data.abs, "rb")
    F.ok(f, "no file at " .. tostring(data.abs))
    local head = f:read(24)
    f:close()
    -- The PNG signature, then IHDR with the width and the height.
    F.eq(head:sub(1, 8), "\137PNG\r\n\26\n")
    F.eq(head:sub(13, 16), "IHDR")
    local function be32(s) return s:byte(1) * 16777216 + s:byte(2) * 65536 + s:byte(3) * 256 + s:byte(4) end
    F.eq(be32(head:sub(17, 20)), 1024)
    F.eq(be32(head:sub(21, 24)), 1024)
    -- The page lists it on the paper shelf, and the gallery is untouched.
    local page = await({ op = "page", agent = coding.id })
    F.eq(#page.papers, 1)
    F.eq(page.papers[1].kind, "paper")
    F.eq(page.papers[1].abs, data.abs)
    F.eq(#page.gallery, 1)
    -- And it decodes in LOVE, the way the page will draw it.
    local Photos = require("src.photos")
    local img = Photos.get(data.abs)
    F.ok(img, "LOVE could not read the paper")
    if img then
      F.eq(img:getWidth(), 1024)
      Photos.forget(data.abs)
    end
  end)

  F.it("the PAPER word draws a paper through the same bridge, sprite and all", function()
    local Actions = require("src.actions")
    Robots.list = roster
    Robots.index()
    Robots.select(coding.id)
    local sprite = Robots.spritePath()
    F.ok(sprite and io.open(sprite, "rb"), "no sprite file for the backend to read: " .. tostring(sprite))
    local said = {}
    Actions.request = nil
    F.ok(Actions.handle("paper", function(text, tone) said[#said + 1] = { text = text, tone = tone } end))
    local deadline = love.timer.getTime() + 60
    while not Actions.request and love.timer.getTime() < deadline do
      love.timer.sleep(0.005)
      Backend.update(0.005)
    end
    F.eq(Actions.request, "paper", "the action never asked for the paper shelf")
    Actions.request = nil
    F.eq(said[#said].tone, "good")
    F.has(said[#said].text, "PAPER 1024X1024 -> CODING-")
    local page = await({ op = "page", agent = coding.id })
    F.eq(#page.papers, 2, "the second paper is not on the shelf")
    -- And `search` the same way, with nobody chosen: every robot, said back.
    Robots.select(nil)
    said = {}
    local done = false
    F.ok(Actions.handle("search a robot", function(text, tone)
      said[#said + 1] = text
      if tone == "good" or tone == "info" then done = true end
    end))
    deadline = love.timer.getTime() + 30
    while #said == 0 and love.timer.getTime() < deadline do
      love.timer.sleep(0.005)
      Backend.update(0.005)
    end
    F.ok(#said >= 2, "the search said nothing back")
    F.has(said[1], "ALL AGENTS")
    F.has(said[2], "#" .. tostring(photo.id))
    Robots.reset()
  end)

  F.it("rebuilds a robot's folder from the global database on request", function()
    local data, err = await({ op = "export", agent = coding.id })
    F.eq(err, nil)
    F.eq(#data.exported, 1)
    F.eq(data.exported[1].space, coding.space)
    F.ok(data.exported[1].items >= 1)
    F.ok(#data.exported[1].files == 4, "agent.db, items.jsonl, items.csv, agent.md")
  end)

  F.it("routes a question nobody chose a robot for", function()
    local data, err = await({ op = "route", text = "why does this rust code not compile?" })
    F.eq(err, nil)
    F.eq(data.agent.slug, "coding")
    F.eq(data.confident, true)

    local food = await({ op = "route", text = "what should I cook for dinner?" })
    F.eq(food.agent.slug, "food")
  end)

  F.it("holds a turn, and remembers both halves of it", function()
    local turn, err = await({ op = "chat", text = "what should I cook for dinner?" }, 45)
    F.eq(err, nil)
    F.eq(turn.agent.slug, "food")
    F.eq(turn.routed, true)
    F.ok(#turn.reply > 0, "an empty answer")

    local messages = await({ op = "messages", agent = turn.agent.id })
    F.eq(#messages, 2)
    F.eq(messages[1].role, "user")
    F.eq(messages[2].role, "assistant")
    F.eq(messages[2].body, turn.reply)
  end)

  F.it("draws the page from what is actually on the shelves", function()
    local page, err = await({ op = "page", agent = coding.id })
    F.eq(err, nil)
    F.eq(page.agent.slug, "coding")
    F.eq(#page.gallery, 1)
    F.eq(page.gallery[1].title, "a robot")
    F.has(page.folder, coding.id)
    F.eq(#page.markdowns, 0)
  end)

  F.it("the client's own roster loads through the same bridge", function()
    Robots.reset()
    local done = false
    Robots.refresh(function() done = true end)
    local deadline = love.timer.getTime() + 20
    while not done and love.timer.getTime() < deadline do
      love.timer.sleep(0.005)
      Backend.update(0.005)
    end
    F.ok(done, "the roster never arrived")
    F.ok(#Robots.list >= 8)
    F.ok(Robots.select("food"), "could not select by slug")
    F.eq(Robots.name(), "EMBER")
  end)

  F.it("the brain can be switched mid-session, and refuses to lie about it", function()
    local info, err = await({ op = "provider" })
    F.eq(err, nil)
    F.eq(info.current, "auto")
    -- The key is blanked in this suite, so asking for the cloud outright must
    -- come back offline rather than quietly using anything else.
    local set = await({ op = "provider.set", provider = "cloud" })
    F.eq(set.current, "cloud")
    F.eq(set.effective, "offline")
    local _, bad = await({ op = "provider.set", provider = "abacus" })
    F.has(bad, "NO PROVIDER")
    local back = await({ op = "provider.set", provider = "auto" })
    F.eq(back.current, "auto")
  end)

  F.it("keeps the AI setup in the space, and says where each value came from", function()
    local info, err = await({ op = "config" })
    F.eq(err, nil)
    F.eq(info.setup["ondevice.engine"].value, "off")
    -- "env": this suite hands its settings to the server on its command
    -- line (`Backend.env`), and that is the process environment as far as
    -- the server is concerned. The screen says where a value came from.
    F.eq(info.setup["ondevice.engine"].source, "env")
    F.eq(info.setup["ondevice.model"].value, "qwen3.8:27b-mlx")
    F.eq(info.setup["ondevice.model"].source, "default")
    F.eq(info.setup["cloud.key"].set, false)

    local set, err2 = await({ op = "config.set", values = { ["ondevice.model"] = "qwen3.8:8b" } })
    F.eq(err2, nil)
    F.eq(set.setup["ondevice.model"].value, "qwen3.8:8b")
    F.eq(set.setup["ondevice.model"].source, "space")
    F.ok(set.provider, "the reply carries the provider picture too")

    local _, bad = await({ op = "config.set", key = "ondevice.host", value = "nowhere" })
    F.has(bad, "HTTP://")

    local cleared = await({ op = "config.set", key = "ondevice.model", value = "" })
    F.eq(cleared.setup["ondevice.model"].source, "default")
  end)

  F.it("refuses a raw brain call the same way it refuses a turn", function()
    local _, err = await({ op = "brain.chat", messages = { { role = "user", content = "hi" } } })
    F.has(err, "NO BRAIN CAN ANSWER")
  end)

  -- Streaming, through the whole bridge.
  --
  -- The chain is four links long — the engine's token callback, the
  -- server's WebSocket frame, the LÖVE channel the worker pushes onto, and
  -- the frame that pops it — and this is the only test that runs all
  -- four. It does not assert on *how many* pieces arrive: offline there is
  -- one, on-device there are hundreds, and the contract is the same either
  -- way. What it asserts is that the pieces arrive before the reply does,
  -- and that joined together they are the answer.
  F.it("streams a turn: the pieces arrive first, and they are the answer", function()
    local chunks, replied = {}, false
    local done, out, err = false, nil, nil
    Backend.call({ op = "chat", text = "what should I cook for dinner?" },
      function(data, e)
        done, out, err = true, data, e
      end,
      { onChunk = function(kind, text)
          F.ok(not replied, "a chunk arrived after the reply had landed")
          if kind == "token" then chunks[#chunks + 1] = text end
        end })

    local deadline = love.timer.getTime() + 120
    while not done and love.timer.getTime() < deadline do
      love.timer.sleep(0.005)
      Backend.update(0.005)
    end
    replied = true
    F.ok(done, "the turn never came back")
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

  F.it("the daemon this suite started goes down with it", function()
    local bye, err = await({ op = "daemon.stop" })
    F.eq(err, nil)
    F.eq(bye.stopping, true)
  end)

  -- Put everything back the way the rest of the suite expects it.
  Robots.reset()
  Backend.home, Backend.env = wasHome, wasEnv
  Store.use(wasStore)
  -- JARVIS_TEST_KEEP=1 leaves the scratch space and its agentd.log behind,
  -- for a failure that only shows over the socket.
  if os.getenv("JARVIS_TEST_KEEP") == "1" then
    print("  kept  " .. scratch)
  else
    os.execute(string.format("rm -rf '%s' 2>/dev/null", scratch:gsub("'", "'\\''")))
  end
end
