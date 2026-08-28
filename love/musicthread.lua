-- Render the two music loops off the main thread and hand them back.
--
-- A SoundData is a `love.Data`, which a channel will carry, so the main thread
-- only has to wrap them in sources. Nothing here touches love.audio: creating
-- a source is a main-thread job.

require("love.sound")
require("love.thread")
require("love.timer")

local root = ...
package.path = root .. "/?.lua;" .. package.path

local ok, result = pcall(function()
  local started = love.timer.getTime()
  local music = require("src.musicgen")
  local tracks = music.generate()
  tracks.render_seconds = love.timer.getTime() - started
  return tracks
end)

local channel = love.thread.getChannel("music.out")
if ok then
  channel:push({
    hall = result.hall,
    forge = result.forge,
    seconds = result.seconds,
    render_seconds = result.render_seconds,
  })
else
  channel:push({ error = tostring(result) })
end
