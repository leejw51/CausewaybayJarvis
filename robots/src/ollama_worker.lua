-- Worker thread: runs one blocking curl per job and ships the raw body back.
-- LOVE 11.5 has no built-in https module, so curl does the TLS work.

require("love.thread")

local jobs = love.thread.getChannel("ollama.jobs")
local results = love.thread.getChannel("ollama.results")

while true do
  local job = jobs:demand()
  if type(job) ~= "table" then break end

  local cmd = string.format("%s --config '%s' 2>&1", job.curl or "curl", job.cfg)
  local raw, err
  local pipe = io.popen(cmd, "r")
  if pipe then
    raw = pipe:read("*a")
    pipe:close()
  else
    err = "could not run curl"
  end
  os.remove(job.cfg)
  if job.body then os.remove(job.body) end

  results:push({ id = job.id, raw = raw or "", err = err })
end
