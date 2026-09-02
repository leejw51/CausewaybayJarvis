-- Talking to a robot: what reaches the 8x8 ROM, and what the receipt says.

local Converse = require("src.converse")
local Robots = require("src.robots")

return function(F)
  F.describe("converse / flattening")

  F.it("drops the hidden reasoning block", function()
    F.eq(Converse.flatten("<think>hmm, maybe</think>the answer"), "THE ANSWER")
  end)

  F.it("folds to what the font actually has", function()
    F.eq(Converse.flatten("Malá Strana"), "MAL STRANA")
    F.eq(Converse.flatten("**bold** and `code`"), "BOLD AND CODE")
    F.eq(Converse.flatten("one\n\ntwo   three"), "ONE TWO THREE")
    F.eq(Converse.flatten(nil), "")
  end)

  F.describe("converse / wrapping")

  F.it("breaks on words, and breaks a word too long to fit", function()
    local lines = Converse.wrap("the quick brown fox", 10)
    F.eq(#lines, 2)
    F.eq(lines[1], "the quick")
    F.eq(lines[2], "brown fox")
    for _, line in ipairs(lines) do F.ok(#line <= 10) end

    local long = Converse.wrap("supercalifragilistic", 8)
    F.ok(#long >= 2)
    for _, line in ipairs(long) do F.ok(#line <= 8) end
  end)

  F.it("always returns at least one line", function()
    F.eq(#Converse.wrap("", 10), 1)
  end)

  F.describe("converse / watching the answer arrive")

  -- The backend, stubbed: `send` is driven without a daemon, a library or a
  -- model, so what is asserted here is the *screen* — that a line goes up
  -- empty, grows, and is replaced by the turn.
  -- The stub is put back whatever happens. A test that fails half way
  -- through must not leave the real `Backend.call` replaced: every suite
  -- after this one talks to the backend, and they would all fail for a
  -- reason that has nothing to do with them.
  local function withStub(script, body)
    local Backend = require("src.backend")
    local was, wasReady = Backend.call, Backend.ready
    Backend.ready = true
    Backend.call = function(request, cb, opts)
      script(request, cb, opts)
      return true
    end
    local ok, err = pcall(body)
    Backend.call, Backend.ready = was, wasReady
    if not ok then error(err, 0) end
  end

  local function answer()
    for i = #Converse.lines, 1, -1 do
      if Converse.lines[i].who ~= "YOU" then return Converse.lines[i] end
    end
    return nil
  end

  F.it("puts a line up before the first token, and grows it", function()
    Converse.reset()
    local chunk, finish
    withStub(function(_, cb, opts)
      chunk = opts and opts.onChunk
      finish = cb
    end, function()

    Converse.send("what is a mutex?")
    F.ok(Converse.busy, "the turn is in flight")
    local line = answer()
    F.ok(line ~= nil, "no line for the answer")
    F.eq(line.text, "", "the line should start empty")
    F.eq(line.partial, true)
    F.ok(Converse.streaming == line, "the streaming line is not the one on screen")

    F.ok(chunk ~= nil, "the UI never asked for chunks -- nothing would stream")
    chunk("token", "a mutex ")
    F.eq(line.text, "A MUTEX")
    chunk("token", "is a lock")
    -- Joined on the raw text, so a chunk boundary on a space cannot weld
    -- two words into one.
    F.eq(line.text, "A MUTEX IS A LOCK")

    finish({ reply = "a mutex is a lock", agent = nil, retrieved = {}, tools = {} })
    F.eq(Converse.busy, false)
    F.eq(line.partial, false)
    F.eq(line.text, "A MUTEX IS A LOCK")
    F.eq(Converse.streaming, nil)
    end)
  end)

  F.it("says what the turn is doing while there is nothing to read", function()
    Converse.reset()
    local chunk
    withStub(function(_, _, opts) chunk = opts.onChunk end, function()
      Converse.send("what did I say about bones?")
      chunk("tool", "search_context bones")
      F.has(Converse.notice, "SEARCH_CONTEXT BONES")
    end)
  end)

  F.it("lets the finished turn overrule what was streamed", function()
    Converse.reset()
    local chunk, finish
    withStub(function(_, cb, opts) chunk, finish = opts.onChunk, cb end, function()
      Converse.send("hello")
      chunk("token", "half an ans")
      finish({ reply = "the whole answer", retrieved = {}, tools = {} })
      -- Not "HALF AN ANSTHE WHOLE ANSWER": the turn replaces the preview.
      F.eq(answer().text, "THE WHOLE ANSWER")
    end)
  end)

  F.it("takes the empty line away again when the turn fails", function()
    Converse.reset()
    local finish
    withStub(function(_, cb) finish = cb end, function()
      Converse.send("hello")
      local before = #Converse.lines
      finish(nil, "AGENTD TIMED OUT")
      -- The empty line goes; the error takes its place, so the count holds.
      F.eq(#Converse.lines, before)
      F.has(answer().text, "TIMED OUT")
      F.eq(Converse.streaming, nil)
    end)
  end)

  F.it("still works against a backend that cannot stream at all", function()
    Converse.reset()
    local finish
    withStub(function(_, cb) finish = cb end, function()
      Converse.send("hello")
      -- No chunks ever arrive: the daemon path. The answer still lands.
      finish({ reply = "an answer", retrieved = {}, tools = {} })
      F.eq(answer().text, "AN ANSWER")
      F.eq(answer().partial, false)
    end)
  end)

  F.describe("converse / the receipt")

  F.it("says who took the turn, what it read and what it ran", function()
    local line = Converse.receipt({
      routed = true, confident = true,
      agent = { id = "ccc", name = "EMBER" },
      retrieved = { { id = 1 }, { id = 2 } },
      tools = { "SEARCH_CONTEXT BONES" },
      model = "gpt-oss:20b",
    })
    F.has(line, "ROUTED TO EMBER")
    F.has(line, "2 FROM ARCHIVE")
    F.has(line, "SEARCH_CONTEXT BONES")
    F.has(line, "GPT-OSS:20B")
  end)

  F.it("distinguishes a real route from a fallback", function()
    local line = Converse.receipt({
      routed = true, confident = false,
      agent = { id = "aaa", name = "JARVIS" }, retrieved = {}, tools = {},
    })
    F.has(line, "DEFAULTED TO JARVIS")
    F.lacks(line, "ROUTED TO")
  end)

  F.it("says nothing when a turn did nothing worth reporting", function()
    F.eq(Converse.receipt({ routed = false, retrieved = {}, tools = {}, model = "" }), nil)
    F.eq(Converse.receipt("not a turn"), nil)
  end)

  F.describe("converse / fitting the receipt")

  F.it("drops whole sections rather than cutting a word in half", function()
    local line = "ROUTED TO EMBER  //  5 FROM ARCHIVE  //  GPT-OSS:20B"
    F.eq(Converse.fitReceipt(line, 200), line)
    F.eq(Converse.fitReceipt(line, 40), "ROUTED TO EMBER  //  5 FROM ARCHIVE")
    F.eq(Converse.fitReceipt(line, 20), "ROUTED TO EMBER")
    F.lacks(Converse.fitReceipt(line, 40), "GPT-O")
  end)

  F.it("falls back to a marked cut when even the first section will not fit", function()
    local out = Converse.fitReceipt("ROUTED TO SOMEBODY", 8)
    F.eq(#out, 8)
    F.match(out, "%-$")
  end)

  F.describe("converse / the transcript")

  F.it("keeps the newest and drops the oldest", function()
    Converse.reset()
    for i = 1, 200 do Converse.push("YOU", "line " .. i) end
    F.ok(#Converse.lines <= 120)
    F.eq(Converse.lines[#Converse.lines].text, "LINE 200")
  end)

  F.it("finds the last thing a robot said, not the last thing typed", function()
    Converse.reset()
    Converse.push("EMBER", "six hours")
    Converse.push("YOU", "thanks")
    F.eq(Converse.lastSaid().text, "SIX HOURS")
    Converse.reset()
    F.eq(Converse.lastSaid(), nil)
  end)

  F.it("refuses an empty line and refuses to talk over itself", function()
    Converse.reset()
    Robots.reset()
    F.eq(Converse.send("   "), false)
    Converse.busy = true
    local ok, why = Converse.send("hello")
    F.eq(ok, false)
    F.has(why, "THINKING")
    Converse.busy = false
  end)
end
