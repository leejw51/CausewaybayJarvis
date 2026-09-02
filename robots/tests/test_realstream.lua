-- A probe of the real thing: `make gui`'s path, with no test overrides.
--
-- test_uistream pins the engine, which is useful but is not what a session
-- does. This one changes nothing at all — same space, same settings, same
-- provider the operator left set — and reports whether the answer arrived
-- in pieces. If streaming is broken for a real user, this is what says so.
local Converse = require("src.converse")
local Backend = require("src.backend")

return function(F)
  F.describe("realstream / exactly what a session does")
  if os.getenv("JARVIS_REAL_STREAM") ~= "1" then
    F.skip("the probe", "set JARVIS_REAL_STREAM=1")
    return
  end
  F.it("streams", function()
    Backend.env = nil
    Backend.home = nil
    Backend.init()
    print("  backend: " .. tostring(Backend.reason) .. "  via " .. tostring(Backend.bin))
    do
      local done, info = false, nil
      Backend.call({ op = "provider" }, function(d) done, info = true, d end)
      local deadline = love.timer.getTime() + 20
      while not done and love.timer.getTime() < deadline do
        love.timer.sleep(0.005); Backend.update(0.005)
      end
      local od = info and info.ondevice or {}
      print(string.format("  provider: %s | ondevice compiled=%s ready=%s engine=%s why=%s",
        tostring(info and info.effective), tostring(od.compiled), tostring(od.ready),
        tostring(od.engine), tostring(od.why)))
    end
    Converse.reset()
    Converse.send("in one sentence, what is a race condition?")
    local t0 = love.timer.getTime()
    local seen, last, reported = 0, "", false
    local worst, chunkFrames, chunksTotal = 0, 0, 0
    local Face = require("src.face")
    while Converse.busy and love.timer.getTime() - t0 < 180 do
      love.timer.sleep(1 / 60)
      local before = love.timer.getTime()
      local wasLen = 0
      for i = #Converse.lines, 1, -1 do
        if Converse.lines[i].who ~= "YOU" then wasLen = #Converse.lines[i].text break end
      end
      Backend.update(1 / 60)
      -- What a frame actually costs while streaming: the update, plus the
      -- wrapping the draw would do. Measured together because together is
      -- what a frame has to fit into 16ms.
      local rects = Face.rects(640, 360, false)
      local chars = math.max(10, math.floor((rects.speech.w - 12) / 8))
      for _, line in ipairs(Converse.lines) do Converse.wrap(line.text, chars) end
      local cost = love.timer.getTime() - before
      if cost > worst then worst = cost end
      local nowLen = 0
      for i = #Converse.lines, 1, -1 do
        if Converse.lines[i].who ~= "YOU" then nowLen = #Converse.lines[i].text break end
      end
      if nowLen ~= wasLen then chunkFrames = chunkFrames + 1 end
      local line
      for i = #Converse.lines, 1, -1 do
        if Converse.lines[i].who ~= "YOU" then line = Converse.lines[i] break end
      end
      -- The prefill, which is the part of the wait the face now shows.
      if Converse.progress and not reported then
        reported = true
        print(string.format("  %6.2fs  prefill visible: %d/%d",
          love.timer.getTime() - t0, Converse.progress.done, Converse.progress.total))
      end
      if line and line.text ~= last then
        seen = seen + 1
        last = line.text
        if seen <= 3 or seen % 10 == 0 then
          print(string.format("  %6.2fs  %s", love.timer.getTime() - t0, last:sub(1, 60)))
        end
      end
    end
    local turn = Converse.lastTurn or {}
    print(string.format("  answered by %s | %d distinct frames",
      tostring(turn.model or "?"), seen))
    print(string.format("  worst frame while streaming: %.1f ms  (16.7 ms is one frame at 60fps)",
      worst * 1000))
    print(string.format("  answer length: %d chars", #tostring(turn.reply or "")))
    F.ok(seen > 1, "the answer arrived all at once -- streaming is NOT working")
    F.ok(reported, "no prefill progress reached the screen -- the wait is blank")
    F.has(tostring(turn.model), "on-device")
  end)
end
