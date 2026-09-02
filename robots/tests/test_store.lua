-- Persistence lives in ~/.causewaybayjarvis, not in the LOVE save tree.
local Store = require("src.store")

return function(t)
  t.describe("store")

  local scratch = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/jarvis-store-test"

  t.it("defaults to ~/.causewaybayjarvis", function()
    Store.use(nil)
    local root = Store.root()
    t.has(root, ".causewaybayjarvis")
    t.has(root, os.getenv("HOME") or "/", "it sits in the user's home")
  end)

  t.it("writes and reads a file", function()
    Store.use(scratch)
    t.eq(Store.root(), scratch)
    t.ok(Store.write("settings.txt", "42\n"))
    t.eq(Store.read("settings.txt"), "42\n")
    t.eq(Store.exists("settings.txt"), true)
  end)

  t.it("creates subdirectories on the way", function()
    Store.use(scratch)
    local ok, path = Store.write("tmp/deep/req_1.json", '{"model":"x"}')
    t.ok(ok)
    t.has(path, scratch .. "/tmp/deep/req_1.json")
    t.eq(Store.read("tmp/deep/req_1.json"), '{"model":"x"}')
  end)

  t.it("removes a file and reports a missing one", function()
    Store.use(scratch)
    Store.write("gone.txt", "x")
    t.eq(Store.remove("gone.txt"), true)
    t.eq(Store.exists("gone.txt"), false)
    t.eq(Store.read("gone.txt"), nil)
    t.eq(Store.read("never_written.txt"), nil)
  end)

  t.it("hands out absolute paths curl can use", function()
    Store.use(scratch)
    local p = Store.path("tmp/req_9.cfg")
    t.eq(p:sub(1, 1), "/", "the worker thread runs curl with this path")
    t.has(p, "tmp/req_9.cfg")
  end)

  t.it("restores the real store for the suites that follow", function()
    os.remove(scratch .. "/settings.txt")
    os.remove(scratch .. "/tmp/deep/req_1.json")
    Store.use(nil)
    t.has(Store.root(), ".causewaybayjarvis")
  end)
end
