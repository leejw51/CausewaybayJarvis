--- Playing what `musicgen` composed.
---
--- Two loops of the same eight bars, started together and left running. What
--- changes is the balance between them: `music.intensity(1)` brings the drums
--- and the bass up while the model is generating, `music.intensity(0)` leaves
--- the hall to its pad. Crossfading rather than switching means the beat never
--- restarts, which is the whole reason the two mixes share a tempo.

local M = {
  ready = false,
  enabled = true,
  volume = 0.5,
  level = 0,
  target = 0,
}

--- Kick the render off. `root` is the directory the Lua lives in, which the
--- thread needs for its own `package.path`.
function M.load(root)
  M.thread = love.thread.newThread("musicthread.lua")
  M.thread:start(root)
  M.channel = love.thread.getChannel("music.out")
  return M
end

local function source(data)
  local s = love.audio.newSource(data, "static")
  s:setLooping(true)
  s:setVolume(0)
  return s
end

function M.update(dt)
  if not M.ready then
    local result = M.channel and M.channel:pop()
    if result then
      if result.error then
        M.failed = result.error
        M.ready = true
      else
        M.hall = source(result.hall)
        M.forge = source(result.forge)
        M.seconds = result.seconds
        M.render_seconds = result.render_seconds
        M.ready = true
        if M.enabled then M.start() end
      end
    end
    return
  end
  if not M.hall then return end

  -- Chase the target rather than jumping: a harness snapping on should bring
  -- the drums in over half a second, not on the frame.
  local rate = M.target > M.level and 1.6 or 0.8
  local delta = M.target - M.level
  M.level = M.level + math.max(-rate * dt, math.min(rate * dt, delta))

  local master = M.enabled and M.volume or 0
  -- Equal-power, so the middle of the fade is not a dip.
  local angle = M.level * math.pi / 2
  M.hall:setVolume(math.cos(angle) * master)
  M.forge:setVolume(math.sin(angle) * master)
end

function M.start()
  if not M.hall then return end
  -- Both from the same instant, so the bar lines agree for as long as the
  -- process lives.
  M.hall:seek(0) M.forge:seek(0)
  love.audio.play(M.hall, M.forge)
end

function M.intensity(level) M.target = math.max(0, math.min(1, level)) end

function M.toggle()
  M.enabled = not M.enabled
  if M.enabled and M.hall and not M.hall:isPlaying() then M.start() end
  return M.enabled
end

return M
