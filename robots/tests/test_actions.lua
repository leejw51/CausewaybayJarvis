-- The archive words, and the file box behind two of them. No dialog is
-- opened here: what is checked is that a typed line means the same thing
-- everywhere, and that the box would be asked for the right thing.

local Actions = require("src.actions")
local Picker = require("src.picker")
local Robots = require("src.robots")

return function(F)
  F.describe("actions / the words")

  F.it("recognises the five words, alone", function()
    F.eq(Actions.parse("photo"), "photo")
    F.eq(Actions.parse("  PHOTO  "), "photo")
    F.eq(Actions.parse("/photo"), "photo")
    F.eq(Actions.parse("file"), "file")
    F.eq(Actions.parse("upload"), "file")
    F.eq(Actions.parse("paper"), "paper")
    F.eq(Actions.parse("export"), "paper")
    F.eq(Actions.parse("gallery"), "gallery")
    F.eq(Actions.parse("photos"), "gallery")
    F.eq(Actions.parse("album"), "gallery")
  end)

  F.it("search carries its words, and needs some", function()
    local id, arg = Actions.parse("search pork belly")
    F.eq(id, "search")
    F.eq(arg, "pork belly")
    local id2, arg2 = Actions.parse("FIND the borrow checker")
    F.eq(id2, nil, "find is the unit search on the console, not this")
    F.eq(arg2, nil)
    F.eq(Actions.parse("search"), nil, "a search with nothing to search for")
    F.eq(Actions.parse("lookup congee"), "search")
  end)

  F.it("leaves a sentence alone", function()
    F.eq(Actions.parse("photo of a cat please"), nil)
    F.eq(Actions.parse("what file should I open?"), nil)
    F.eq(Actions.parse("the paper said rain"), nil)
    F.eq(Actions.parse(""), nil)
    F.eq(Actions.parse(nil), nil)
    F.eq(Actions.parse("hello"), nil)
  end)

  F.it("describes a hit in one console line, with its owner", function()
    local line = Actions.describeHit({
      item = { id = 7, kind = "note", title = "pork belly, slow roast" },
      agent_name = "Ember",
    }, 44)
    F.has(line, "#7 NOTE ")
    F.has(line, "PORK BELLY")
    F.has(line, "(EMBER)")
    F.ok(#line <= 44, "too long: " .. #line)
    local bare = Actions.describeHit({ item = { id = 1, kind = "image", title = "cat.png" } })
    F.eq(bare, "#1 IMAGE CAT.PNG")
  end)

  F.it("an unknown line is not handled, and says so", function()
    local said = {}
    F.eq(Actions.handle("tell me a joke", function(t) said[#said + 1] = t end), false)
    F.eq(#said, 0)
  end)

  F.it("gallery asks the main loop for the page", function()
    Actions.request = nil
    local said = {}
    F.eq(Actions.handle("gallery", function(t, tone) said[#said + 1] = { t, tone } end), true)
    F.eq(Actions.request, "gallery")
    F.has(said[1][1], "GALLERY")
    Actions.request = nil
  end)

  F.describe("actions / the file box")

  F.it("asks macOS for pictures only when it is a photo", function()
    local photo = Picker.command("photo", "osascript")
    F.has(photo, "osascript")
    F.has(photo, "choose file")
    F.has(photo, "public.image")
    F.has(photo, "multiple selections allowed")
    F.has(photo, "POSIX path")
    local any = Picker.command("file", "osascript")
    F.lacks(any, "public.image")
    F.has(any, "multiple selections allowed")
  end)

  F.it("falls back to zenity elsewhere, with the same narrowing", function()
    F.eq(Picker.tool("Linux"), "zenity")
    F.eq(Picker.tool("OS X"), "osascript")
    local photo = Picker.command("photo", "zenity")
    F.has(photo, "zenity --file-selection --multiple")
    F.has(photo, "*.png")
    F.lacks(Picker.command("file", "zenity"), "file-filter")
  end)

  F.it("reads one path per line and drops the blanks", function()
    local paths = Picker.parse("/Users/x/a.png\n/Users/x/b c.jpg  \n\n")
    F.eq(#paths, 2)
    F.eq(paths[1], "/Users/x/a.png")
    F.eq(paths[2], "/Users/x/b c.jpg")
    F.eq(#Picker.parse(""), 0, "a cancelled box is no paths")
    F.eq(#Picker.parse(nil), 0)
  end)

  F.it("refuses a second box while one is open", function()
    Picker.busy = true
    local got
    F.eq(Picker.open("photo", function(_, err) got = err end), false)
    F.has(got, "ALREADY OPEN")
    Picker.busy = false
  end)

  F.describe("actions / the gallery with nobody chosen")

  F.it("flattens every folder into one list, newest first, owner on each", function()
    local list = Robots.flattenGallery({
      groups = {
        { agent = { name = "BYTE", color = "cyan" }, photos = { { id = 3, title = "a" } } },
        { agent = { name = "EMBER", color = "orange" }, photos = { { id = 9, title = "b" }, { id = 1, title = "c" } } },
        { agent = nil, space = "global", photos = { { id = 5, title = "d" } } },
      },
    })
    F.eq(#list, 4)
    F.eq(list[1].id, 9)
    F.eq(list[1].agent_name, "EMBER")
    F.eq(list[2].id, 5)
    F.eq(list[2].agent_name, "GLOBAL")
    F.eq(list[4].id, 1)
    F.eq(#Robots.flattenGallery(nil), 0)
  end)
end
