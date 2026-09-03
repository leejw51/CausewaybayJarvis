-- The thread that holds the file box open.
--
-- One job in — `{ id, cmd }` — one result out — `{ id, out }` or
-- `{ id, err }`. The command is the operating system's dialog, which blocks
-- until the operator has chosen or cancelled; that wait happens here, so
-- the window keeps drawing.

require("love.thread")

local jobs = love.thread.getChannel("picker.jobs")
local results = love.thread.getChannel("picker.results")

while true do
  local job = jobs:demand()
  if job == "quit" then break end
  if type(job) == "table" and job.cmd then
    local pipe = io.popen(job.cmd, "r")
    if not pipe then
      results:push({ id = job.id, err = "NO FILE DIALOG ON THIS MACHINE" })
    else
      local out = pipe:read("*a") or ""
      pipe:close()
      results:push({ id = job.id, out = out })
    end
  end
end
