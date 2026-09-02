local Audio = {
  src = {},
  muted = false,
  hum = nil,
}

local NAMES = {
  "clap", "sting", "online", "click", "blip", "alert",
  "scan", "toggle", "spark", "type", "whoosh", "hum", "crt_on",
}

function Audio.load()
  for _, name in ipairs(NAMES) do
    local path = "assets/sfx/" .. name .. ".wav"
    if love.filesystem.getInfo(path) then
      local src = love.audio.newSource(path, "static")
      if name == "hum" then
        src:setLooping(true)
        src:setVolume(0)
        Audio.hum = src
        src:stop()
      end
      Audio.src[name] = src
    end
  end
end

function Audio.play(name, pitch, vol)
  if Audio.muted then return end
  if name == "hum" then return end
  local proto = Audio.src[name]
  if not proto then return end
  local s = proto:clone()
  if pitch then s:setPitch(pitch) end
  if vol then s:setVolume(vol) end
  s:play()
end

function Audio.setHum(_on)
  if Audio.hum then
    Audio.hum:stop()
    Audio.hum:setVolume(0)
  end
end

function Audio.toggleMute()
  Audio.muted = not Audio.muted
  if Audio.muted then
    love.audio.stop()
  end
  Audio.setHum(false)
end

return Audio
