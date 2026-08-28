local M = { at = 0, next = 1, shots = 0 }
M.script = {
  { at = 0.8, key = "space" }, { at = 1.4, key = "space" },
  { at = 3.2, shot = "D1-early" },
  { at = 5.0, key = "space" }, { at = 6.0, key = "space" },
  { at = 7.0, shot = "D2-mid" },
  { at = 11.0, shot = "D3-late" },
  { at = 12.0, quit = true },
}
function M.update(dt)
  local spare = 1 / 60 - dt
  if spare > 0 then love.timer.sleep(spare) end
  M.at = M.at + dt
  while M.next <= #M.script do
    local step = M.script[M.next]
    if step.at > M.at then break end
    M.next = M.next + 1
    if step.key then love.keypressed(step.key, step.key, false)
    elseif step.shot then M.shots = M.shots + 1 love.graphics.captureScreenshot("shot-" .. step.shot .. ".png")
    elseif step.quit then love.event.quit() end
  end
end
return M
