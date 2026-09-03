-- Test entry point. `make test` runs the offline suites; `make test-live`
-- adds real round trips to the configured Ollama host.

local F = require("tests.framework")

local SUITES = {
  "tests.test_json",
  "tests.test_store",
  "tests.test_layout",
  "tests.test_env",
  "tests.test_ollama",
  "tests.test_agents",
  "tests.test_tools",
  "tests.test_chat",
  "tests.test_autopilot",
  "tests.test_backend",
  "tests.test_settings",
  "tests.test_looks",
  "tests.test_robots",
  "tests.test_rail",
  "tests.test_page",
  "tests.test_actions",
  "tests.test_draw",
  "tests.test_face",
  "tests.test_converse",
  "tests.test_agentd",
  "tests.test_live",
  "tests.test_uistream",
  "tests.test_realstream",
}

local M = {}

function M.run()
  print("")
  print("CAUSEWAY BAY // ROBOTS  --  tests")
  for _, name in ipairs(SUITES) do
    local ok, suite = pcall(require, name)
    if not ok then
      F.describe(name)
      F.it("loads", function() error(suite) end)
    else
      suite(F)
    end
  end
  local passed = F.report()
  return passed
end

return M
