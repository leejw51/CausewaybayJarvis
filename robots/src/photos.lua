-- Pictures that live outside the LOVE sandbox.
--
-- Everything a robot has been shown sits in `~/.causewaybayjarvis/agents/
-- <GUID>/photos/`, which `love.filesystem` cannot read: it may only open
-- files under the game directory and the save directory, and this is neither.
-- So the bytes come in through plain `io`, are wrapped as FileData, and only
-- then become an image -- which LOVE is perfectly happy to do.
--
-- Loads are cached by path and capped, because a gallery is scrolled and a
-- decode per frame is a decode too many.

local Photos = {
  cache = {},
  order = {},
  failed = {},
  LIMIT = 48,
}

local function evict()
  while #Photos.order > Photos.LIMIT do
    local oldest = table.remove(Photos.order, 1)
    local img = Photos.cache[oldest]
    Photos.cache[oldest] = nil
    if img and img.release then pcall(function() img:release() end) end
  end
end

--- The image at an absolute path, or nil. A file that failed once is not
--- retried: a gallery of a hundred pictures must not stat a missing one sixty
--- times a second.
function Photos.get(path)
  if not path or path == "" then return nil end
  if Photos.cache[path] then return Photos.cache[path] end
  if Photos.failed[path] then return nil end

  local file = io.open(path, "rb")
  if not file then
    Photos.failed[path] = true
    return nil
  end
  local bytes = file:read("*a")
  file:close()
  if not bytes or #bytes == 0 then
    Photos.failed[path] = true
    return nil
  end

  local name = path:match("([^/]+)$") or "photo"
  local ok, img = pcall(function()
    local data = love.filesystem.newFileData(bytes, name)
    local image = love.graphics.newImage(love.image.newImageData(data))
    image:setFilter("nearest", "nearest")
    return image
  end)
  if not ok or not img then
    Photos.failed[path] = true
    return nil
  end

  Photos.cache[path] = img
  Photos.order[#Photos.order + 1] = path
  evict()
  return img
end

function Photos.forget(path)
  local img = Photos.cache[path]
  Photos.cache[path] = nil
  Photos.failed[path] = nil
  if img and img.release then pcall(function() img:release() end) end
  for i, p in ipairs(Photos.order) do
    if p == path then table.remove(Photos.order, i) break end
  end
end

function Photos.clear()
  for path in pairs(Photos.cache) do Photos.forget(path) end
  Photos.cache = {}
  Photos.order = {}
  Photos.failed = {}
end

--- Bytes to a human size. The page prints it under every file.
function Photos.size(bytes)
  bytes = tonumber(bytes) or 0
  if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / 1048576) end
  if bytes >= 1024 then return string.format("%.0f KB", bytes / 1024) end
  return string.format("%d B", bytes)
end

return Photos
