-- The archive commands: the same five words wherever they are typed.
--
--   photo            a file box narrowed to pictures; each one is filed
--   file             a file box for anything; each one is filed
--   paper            this agent's archive drawn as one 1024x1024 PNG
--   gallery          the photo shelf, as a grid
--   search <words>   BM25 + vectors over this agent — or, with nobody
--                    chosen, over every agent at once
--   (unified)        the same search over every agent whoever is chosen:
--                    `Actions.run("search", words, say, { all = true })`,
--                    which is what the SEARCH button on the chat page runs
--
-- They are typed on the dashboard console, in face mode, and pressed as
-- chips and page buttons, and all of those roads lead here so that a word
-- means one thing. What is filed goes to the chosen agent, or to the global
-- space when nobody is chosen — the same rule as dropping a file on the
-- window.

local Picker = require("src.picker")
local Robots = require("src.robots")

local Actions = {
  -- A screen the last action asked for: "gallery" or "paper". The main loop
  -- reads it and clears it, the way `Dash.request` works.
  request = nil,
  -- The last search, for a screen that wants to draw it.
  lastSearch = nil,
  -- Whether the last search covered everybody.
  lastScope = nil,
}

local WORDS = {
  photo = "photo", photos = "gallery", picture = "photo", pictures = "gallery", image = "photo",
  file = "file", files = "file", upload = "file", attach = "file", add = "file",
  paper = "paper", export = "paper", print = "paper",
  gallery = "gallery", album = "gallery", grid = "gallery",
  search = "search", lookup = "search", grep = "search", recall = "search",
}

--- The action a typed line asks for, and its argument. `nil` for a line
--- that is conversation. A search needs words after it; the others take
--- none, so `photo of a cat` is a sentence and not a command.
function Actions.parse(line)
  local m = tostring(line or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local word, rest = m:match("^/?(%a+)%s*(.*)$")
  if not word then return nil end
  local id = WORDS[word]
  if not id then return nil end
  if id == "search" then
    if rest == "" then return nil end
    return id, rest
  end
  if rest ~= "" then return nil end
  return id, nil
end

--- Who a filed thing goes to, for a toast.
local function whose()
  return Robots.selected and Robots.name() or "GLOBAL"
end

--- How big a file is, read here rather than asked of the backend: it is
--- wanted once per candidate, before anything is sent.
local function sizeOf(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local n = file:seek("end")
  file:close()
  return n
end

--- Everything in `paths` this robot does not already hold.
---
--- Now that ADD takes a whole folder, the same folder added twice would
--- otherwise pile up a second copy of every picture in it -- the backend
--- deliberately keeps both, because two cameras really can make two
--- different `IMG_0001.png`. So the name *and* the size have to match
--- before one is passed over. Duplicates inside one selection are dropped
--- too, which is what a folder holding a file and a link to it looks like.
---
--- With no page loaded nothing is known and so nothing is skipped: filing a
--- second copy is a smaller wrong than silently dropping a file the robot
--- never had.
function Actions.unfiled(paths)
  local known = Robots.filedKeys()
  local keep, skipped, seen = {}, 0, {}
  for _, path in ipairs(paths) do
    local key = Robots.fileKey(path, sizeOf(path))
    if seen[key] or (known and known[key]) then
      skipped = skipped + 1
    else
      seen[key] = true
      keep[#keep + 1] = path
    end
  end
  return keep, skipped
end

local function fileAll(paths, say)
  if #paths == 0 then
    say("FILE BOX CLOSED. NOTHING ADDED.", "info")
    return
  end
  local wanted, skipped = Actions.unfiled(paths)
  if #wanted == 0 then
    say(string.format("ALL %d ALREADY WITH %s", skipped, whose()), "info")
    return
  end
  local over = skipped > 0 and string.format("  //  %d ALREADY THERE", skipped) or ""
  local left, added = #wanted, 0
  for _, path in ipairs(wanted) do
    local name = path:match("([^/]+)$") or path
    Robots.add(path, {}, function(item, err)
      left = left - 1
      if err then
        say("REFUSED " .. name:upper():sub(1, 24) .. "  " .. tostring(err):sub(1, 30), "warn")
      else
        added = added + 1
        say(tostring(item.kind):upper() .. " " .. name:upper():sub(1, 24) .. " -> " .. whose(), "good")
      end
      if left == 0 and (#wanted > 1 or skipped > 0) then
        say(string.format("%d OF %d FILED WITH %s%s", added, #wanted, whose(), over),
          added == #wanted and "good" or "warn")
      end
    end)
  end
end

local function pick(kind, say)
  local ok = Picker.open(kind, function(paths, err)
    if err then
      say(tostring(err):upper():sub(1, 40), "warn")
      return
    end
    fileAll(paths, say)
  end)
  if ok then
    say((kind == "photo" and "PHOTO BOX OPEN. PICK PICTURES FOR " or "FILE BOX OPEN. PICK FILES FOR ")
      .. whose() .. ".", "info")
  end
  return ok
end

--- One line per hit, for a console or a transcript.
function Actions.describeHit(hit, width)
  width = width or 44
  local item = hit.item or {}
  local who = hit.agent_name and (" (" .. tostring(hit.agent_name):upper() .. ")") or ""
  local head = string.format("#%d %s ", tonumber(item.id) or 0, tostring(item.kind or ""):upper())
  local title = tostring(item.title or ""):upper()
  local room = math.max(4, width - #head - #who)
  return head .. title:sub(1, room) .. who
end

--- Run one. `say(text, tone)` is how the screen that asked is told; tone is
--- "info", "good" or "warn". `opts.all` makes a search unified — every agent,
--- whoever is chosen.
function Actions.run(id, arg, say, opts)
  say = say or function() end
  opts = opts or {}
  if id == "photo" or id == "file" then
    return pick(id, say)
  end
  if id == "gallery" then
    Actions.request = "gallery"
    say("GALLERY  //  " .. whose(), "info")
    return true
  end
  if id == "paper" then
    say("DRAWING THE PAPER FOR " .. whose() .. "...", "info")
    return Robots.paper(function(data, err)
      if err then
        say("PAPER REFUSED  " .. tostring(err):sub(1, 36), "warn")
        return
      end
      local name = tostring(data.path or ""):match("([^/]+)$") or "paper.png"
      say(string.format("PAPER %dX%d -> %s", data.width or 0, data.height or 0, name:upper()), "good")
      Actions.request = "paper"
    end)
  end
  if id == "search" then
    local query = tostring(arg or "")
    local where = (opts.all or not Robots.selected) and "ALL AGENTS" or Robots.name()
    return Robots.search(query, "hybrid", function(data, err)
      if err then
        say("SEARCH FAILED  " .. tostring(err):sub(1, 36), "warn")
        return
      end
      Actions.lastSearch = data
      Actions.lastScope = data.scope
      local hits = data.hits or {}
      if #hits == 0 then
        say("NOTHING IN " .. where .. " FOR " .. query:upper():sub(1, 24), "info")
        return
      end
      say(string.format("%d HIT%s IN %s  //  %s", #hits, #hits == 1 and "" or "S", where,
        tostring(data.mode or ""):upper()), "good")
      for i = 1, math.min(#hits, 6) do
        say(Actions.describeHit(hits[i]), "info")
      end
    end, { all = opts.all })
  end
  return false
end

--- Type a line and, if it is one of the five, do it. Returns true when it
--- was, so the caller knows not to send it to a model.
function Actions.handle(line, say)
  local id, arg = Actions.parse(line)
  if not id then return false end
  Actions.run(id, arg, say)
  return true
end

return Actions
