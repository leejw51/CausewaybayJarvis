-- The roster, as this client sees it.
--
-- A robot is a GUID and a face. The GUID and everything filed under it live in
-- the backend; the face is `assets/agent_<sprite>.png`, which is why the
-- backend's `sprite` field is a name from that folder and not a number.
--
-- `Robots.selected` is the whole of the "which robot am I talking to" state:
-- nil means none is chosen, and a turn then runs in the global space and is
-- routed to whichever robot the words belong to.

local Backend = require("src.backend")
local Looks = require("src.looks")
local Sprites = require("src.sprites")
local Store = require("src.store")
local Theme = require("src.theme")

local Robots = {
  list = {},
  byId = {},
  bySlug = {},
  selected = nil,     -- GUID, or nil for the global space
  loaded = false,
  error = nil,
  -- The page of whichever robot was last asked for, and whose it is.
  page = nil,
  pageFor = false,    -- false = nothing asked yet; nil = the global page
  pageBusy = false,
  -- The last route the operator's half-typed line would take.
  hint = nil,
  -- Every robot's photos at once, for the gallery with nobody chosen.
  galleryAll = nil,
  galleryBusy = false,
}

-- The backend names a colour; the palette is here.
local COLORS = {
  gold = Theme.gold, cyan = Theme.cyan, teal = Theme.teal, jade = Theme.jade,
  magenta = Theme.magenta, orange = Theme.orange, lime = Theme.jade,
  green = Theme.jade, blue = Theme.sky, yellow = Theme.amber,
  red = Theme.crimson, violet = Theme.violet, rose = Theme.rose,
  sky = Theme.sky, amber = Theme.amber, ice = Theme.ice,
}

function Robots.color(robot)
  if not robot then return Theme.ice end
  return COLORS[tostring(robot.color or ""):lower()] or Theme.cyan
end

-- Who wants to know. There is one selection in this client — the robot on
-- the rail, the unit locked on the map, the face on screen are the same
-- choice — and it is held here, because this is where the GUID is. Anything
-- that draws it differently subscribes rather than keeping a copy.
local selectWatchers = {}
local rosterWatchers = {}

--- `fn(id)` on every change of selection, `id` nil for nobody.
function Robots.watch(fn)
  selectWatchers[#selectWatchers + 1] = fn
end

--- `fn(list)` every time the roster is (re)loaded from the backend.
function Robots.watchRoster(fn)
  rosterWatchers[#rosterWatchers + 1] = fn
end

function Robots.reset()
  Robots.list = {}
  Robots.byId = {}
  Robots.bySlug = {}
  Robots.selected = nil
  Robots.loaded = false
  Robots.page = nil
  Robots.pageFor = false
  Robots.galleryAll = nil
  Robots.galleryBusy = false
end

function Robots.index()
  Robots.byId = {}
  Robots.bySlug = {}
  for _, r in ipairs(Robots.list) do
    Robots.byId[r.id] = r
    Robots.bySlug[r.slug] = r
  end
end

function Robots.refresh(cb)
  return Backend.call({ op = "agents.list" }, function(data, err)
    if err or type(data) ~= "table" then
      Robots.error = err or "NO ROSTER"
      if cb then cb(nil, Robots.error) end
      return
    end
    Robots.list = data
    Robots.loaded = true
    Robots.error = nil
    Robots.index()
    Robots.loadFaces()
    for _, fn in ipairs(rosterWatchers) do fn(data) end
    if cb then cb(data) end
  end)
end

-- Every robot on the roster wears a sprite from `assets/`. Loading is by
-- sprite name and cached, so twelve robots wearing three faces cost three.
function Robots.loadFaces()
  local wanted = {}
  for _, r in ipairs(Robots.list) do
    if r.sprite and r.sprite ~= "" then
      wanted[#wanted + 1] = { key = r.sprite, base = r.sprite }
    end
  end
  Sprites.loadAgents(wanted)
end

function Robots.current()
  return Robots.selected and Robots.byId[Robots.selected] or nil
end

function Robots.name(robot)
  robot = robot or Robots.current()
  if not robot then return "SWARM" end
  return tostring(robot.name or robot.slug or "?"):upper()
end

--- Lock on to a robot, or (with nil) let go of all of them.
function Robots.select(id)
  if id ~= nil and not Robots.byId[id] then
    local bySlug = Robots.bySlug[id]
    if not bySlug then return false end
    id = bySlug.id
  end
  if Robots.selected == id then return false end
  Robots.selected = id
  Robots.page = nil
  Robots.pageFor = false
  for _, fn in ipairs(selectWatchers) do fn(id) end
  return true
end

function Robots.cycle(step)
  if #Robots.list == 0 then return end
  local at = 0
  for i, r in ipairs(Robots.list) do
    if r.id == Robots.selected then at = i break end
  end
  -- The ring runs 0..n, where 0 is "nobody chosen": deselecting is a stop on
  -- the way round rather than a separate key. Written out rather than as
  -- `a and nil or b`, which in Lua is always `b` -- nil is false.
  local at2 = (at + (step or 1)) % (#Robots.list + 1)
  if at2 == 0 then
    Robots.select(nil)
  else
    Robots.select(Robots.list[at2].id)
  end
end

-- ------------------------------------------------------------------ page --

--- The selected robot's page: gallery, markdown, files, notes.
function Robots.loadPage(cb)
  if Robots.pageBusy or not Backend.ready then return false end
  Robots.pageBusy = true
  local want = Robots.selected
  return Backend.call({ op = "page", agent = want or "global" }, function(data, err)
    Robots.pageBusy = false
    -- The operator may have moved on while this was in flight.
    if want ~= Robots.selected then return end
    if err then
      Robots.error = err
    else
      Robots.page = data
      Robots.pageFor = want
    end
    if cb then cb(data, err) end
  end)
end

--- Is the page we are holding the page for the robot we are looking at?
function Robots.pageFresh()
  return Robots.page ~= nil and Robots.pageFor == Robots.selected
end

--- File something into the chosen robot's space. `path` is a real file on
--- this machine; the backend copies it in and indexes it.
function Robots.add(path, opts, cb)
  opts = opts or {}
  local request = {
    op = "item.add",
    agent = Robots.selected or "global",
    path = path,
    kind = opts.kind,
    title = opts.title,
    body = opts.body,
  }
  return Backend.call(request, function(data, err)
    if data then
      Robots.page = nil
      Robots.pageFor = false
      Robots.galleryAll = nil
    end
    if cb then cb(data, err) end
  end)
end

--- Search. A chosen robot searches its own database; nobody chosen searches
--- every robot at once — the backend's rule, mirrored in the request: the
--- `agent` field is simply left out. `opts.all` is the unified search: every
--- robot and the global space, whoever is chosen, said so with `all = true`.
function Robots.search(query, mode, cb, opts)
  local request = { op = "search", query = query, mode = mode or "hybrid", limit = 20 }
  if opts and opts.all then
    request.all = true
  elseif Robots.selected then
    request.agent = Robots.selected
  end
  return Backend.call(request, cb)
end

--- Every robot's photos, grouped by folder — what the gallery draws when
--- nobody is chosen. Flattened into one list with the owner's name on each,
--- because a grid has room for a caption and not for headings.
function Robots.loadGallery(cb)
  if Robots.galleryBusy or not Backend.ready then return false end
  Robots.galleryBusy = true
  return Backend.call({ op = "gallery" }, function(data, err)
    Robots.galleryBusy = false
    if err or type(data) ~= "table" then
      if cb then cb(nil, err) end
      return
    end
    Robots.galleryAll = Robots.flattenGallery(data)
    if cb then cb(Robots.galleryAll) end
  end)
end

--- Pure: the `gallery` reply as one list, each photo carrying its owner.
function Robots.flattenGallery(data)
  local out = {}
  for _, group in ipairs((data and data.groups) or {}) do
    local agent = group.agent
    for _, photo in ipairs(group.photos or {}) do
      photo.agent_name = agent and agent.name or "GLOBAL"
      photo.agent_color = agent and agent.color or nil
      out[#out + 1] = photo
    end
  end
  table.sort(out, function(a, b) return (a.id or 0) > (b.id or 0) end)
  return out
end

--- The chosen robot's sprite as a real file the backend can open. The
--- sheets live inside the game (a zip, when packaged), so one is copied
--- into the space's tmp folder and that path is what the paper is drawn
--- from.
function Robots.spritePath(robot)
  robot = robot or Robots.current()
  if not robot or not robot.sprite or robot.sprite == "" then return nil end
  -- The face the screen wears: the current look's file, which is the same
  -- one the page header and face mode draw from.
  local bytes = love.filesystem.read(Looks.path(robot.sprite, false))
  if not bytes then return nil end
  local ok, path = Store.write("tmp/sprite-" .. tostring(Looks.current) .. "-" .. robot.sprite .. ".png", bytes)
  return ok and path or nil
end

--- Draw the chosen robot's paper — or the global space's. The reply says
--- where the PNG went; the page's PAPER shelf lists it.
function Robots.paper(cb)
  local request = { op = "paper", agent = Robots.selected or "global" }
  request.sprite = Robots.spritePath()
  return Backend.call(request, function(data, err)
    if data then
      Robots.page = nil
      Robots.pageFor = false
    end
    if cb then cb(data, err) end
  end)
end

--- Which robot would answer this, if none were chosen. Drives the face that
--- steps forward while the operator is still typing.
function Robots.ask(text, cb)
  return Backend.call({ op = "route", text = text }, function(data, err)
    if data and data.agent then
      Robots.hint = data
    elseif err then
      Robots.hint = nil
    end
    if cb then cb(data, err) end
  end)
end

--- The robot the current draft would summon, or nil.
function Robots.hinted()
  local h = Robots.hint
  if not h or not h.agent or not h.confident then return nil end
  return Robots.byId[h.agent.id]
end

return Robots
