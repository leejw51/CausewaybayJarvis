-- A probe, not a test: run one real turn and print the answer line on the
-- frames it changed, which is what the screen would have shown.
local Converse = require("src.converse")
local Backend = require("src.backend")

return function(F)
  F.describe("uistream / one real turn, watched")
  if os.getenv("JARVIS_UI_STREAM") ~= "1" then
    F.skip("the probe", "set JARVIS_UI_STREAM=1")
    return
  end
  F.it("grows on screen", function()
    -- Only this backend's settings. The suites above shut their engines
    -- off, and that no longer reaches anything but their own backends —
    -- which is the point of carrying settings per handle rather than
    -- writing them into the process.
    Backend.env = { ONDEVICE_ENGINE = "mlx" }
    Backend.init()
    Converse.reset()
    Converse.send("in one sentence, what is a semaphore?")
    local t0 = love.timer.getTime()
    local last, frames = "", 0
    while Converse.busy and love.timer.getTime() - t0 < 180 do
      love.timer.sleep(1 / 60)
      Backend.update(1 / 60)
      local line
      for i = #Converse.lines, 1, -1 do
        if Converse.lines[i].who ~= "YOU" then line = Converse.lines[i] break end
      end
      if line and line.text ~= last then
        frames = frames + 1
        print(string.format("  %6.2fs  %s", love.timer.getTime() - t0, line.text))
        last = line.text
      end
    end
    -- Which brain answered, said out loud: a lean library with `auto` set
    -- falls back to the cloud, and a probe that did not say so would read
    -- as proof of on-device streaming when it was nothing of the kind.
    local turn = Converse.lastTurn or {}
    print(string.format("  answered by %s (%s), line changed on %d separate frames",
      tostring(turn.model or "?"), tostring(turn.effective or Backend.providerShort()), frames))
    F.ok(frames > 1, "the answer appeared all at once, not as it was written")
  end)
end
