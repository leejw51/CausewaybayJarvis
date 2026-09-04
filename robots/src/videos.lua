-- Clips that live outside the LOVE sandbox.
--
-- A filed video keeps its original on the shelf -- an MP4 or a MOV, which
-- LOVE cannot play -- and the backend puts a three-second Ogg Theora clip
-- beside it (`rustagent::video`), which it can. That clip sits in
-- `~/.causewaybayjarvis/agents/<GUID>/videos/`, and `love.graphics.newVideo`
-- will not open a path there: it wants a file it can seek in, on a path
-- the sandbox allows, and unlike an image it cannot be handed the bytes.
-- So the bytes come in through plain `io`, are written once into the save
-- directory under `clips/` -- named by a hash of the path, so the same clip
-- is copied once -- and opened from there.
--
-- Loads are cached and capped, like photos, but the cap is small: a Theora
-- clip decodes on the CPU, in this thread, and eight of them looping is
-- already a laptop fan.

local Videos = {
  cache = {},
  order = {},
  failed = {},
  LIMIT = 8,
  DIR = "clips",
}

--- Where a clip is copied to inside the save directory. Pure, given LOVE:
--- a hash of the path, so a clip that moves shelves is a different file and
--- one that is asked for twice is not copied twice.
function Videos.cacheName(path)
  local digest = love.data.encode("string", "hex", love.data.hash("md5", tostring(path or "")))
  return Videos.DIR .. "/" .. digest .. ".ogv"
end

local function evict()
  while #Videos.order > Videos.LIMIT do
    Videos.forget(table.remove(Videos.order, 1))
  end
end

--- The Video at an absolute path, playing and looping, or nil. A path that
--- failed once is not retried every frame.
function Videos.get(path)
  if not path or path == "" then return nil end
  if Videos.cache[path] then return Videos.cache[path] end
  if Videos.failed[path] then return nil end
  if not love.video then
    Videos.failed[path] = true
    return nil
  end

  local name = Videos.cacheName(path)
  if not love.filesystem.getInfo(name) then
    local file = io.open(path, "rb")
    if not file then
      Videos.failed[path] = true
      return nil
    end
    local bytes = file:read("*a")
    file:close()
    if not bytes or #bytes == 0 then
      Videos.failed[path] = true
      return nil
    end
    love.filesystem.createDirectory(Videos.DIR)
    if not love.filesystem.write(name, bytes) then
      Videos.failed[path] = true
      return nil
    end
  end

  -- The clip is silent by construction; asking for no audio keeps LOVE
  -- from opening a Source it would never play.
  local ok, video = pcall(love.graphics.newVideo, name, { audio = false })
  if not ok or not video then
    love.filesystem.remove(name)
    Videos.failed[path] = true
    return nil
  end
  video:setFilter("linear", "linear")
  video:play()

  Videos.cache[path] = video
  Videos.order[#Videos.order + 1] = path
  evict()
  return video
end

--- Keep a clip going round: three seconds is a loop, not a film.
function Videos.tick(video)
  if video and not video:isPlaying() then
    video:rewind()
    video:play()
  end
end

function Videos.forget(path)
  local video = Videos.cache[path]
  Videos.cache[path] = nil
  Videos.failed[path] = nil
  if video then
    pcall(function() video:pause() end)
    if video.release then pcall(function() video:release() end) end
    love.filesystem.remove(Videos.cacheName(path))
  end
  for i, p in ipairs(Videos.order) do
    if p == path then table.remove(Videos.order, i) break end
  end
end

--- Let go of every clip, and of every copy in the save directory -- the
--- ones this run made and the ones a run that crashed left behind.
function Videos.clear()
  for path in pairs(Videos.cache) do Videos.forget(path) end
  Videos.cache = {}
  Videos.order = {}
  Videos.failed = {}
  for _, name in ipairs(love.filesystem.getDirectoryItems(Videos.DIR)) do
    love.filesystem.remove(Videos.DIR .. "/" .. name)
  end
end

return Videos
