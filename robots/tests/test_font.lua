-- The 8x8 font, and the half of it that is not ASCII: composing the Hangul
-- macOS takes apart, then counting and cutting in characters rather than
-- bytes. Nothing here draws; every function under test is pure.

local Font = require("src.font")

-- The screenshot names on a Korean desk, exactly as `ls` hands them over:
-- decomposed, so a syllable is its two or three jamo.
local NFC = "\236\138\164\237\129\172\235\166\176\236\131\183"          -- 스크린샷
local NFD = "\225\132\137\225\133\179\225\132\143\225\133\179"
        .. "\225\132\137\225\133\179\225\132\128"                       -- deliberate junk tail

return function(F)
  F.describe("font / hangul that macOS took apart")

  F.it("composes jamo back into syllables, and leaves everything else alone", function()
    -- 스 = lead U+1109 + vowel U+1173.
    local one = "\225\132\137\225\133\179"
    F.eq(Font.compose(one), "\236\138\164")
    F.eq(Font.len(one), 1, "a composed syllable is one cell, not two")
    -- 한 = U+1112 + U+1161 + U+11AB, a syllable with a final consonant.
    local han = "\225\132\146\225\133\161\225\134\171"
    F.eq(Font.compose(han), "\237\149\156")
    F.eq(Font.len(han), 1)
    -- ASCII and already-composed text come back untouched.
    F.eq(Font.compose("ZKP.MOV"), "ZKP.MOV")
    F.eq(Font.compose(NFC), NFC)
    F.eq(Font.compose(""), "")
  end)

  F.it("a decomposed screenshot name fits the row it never used to", function()
    local name = NFC .. " 2026-09-04 1.17.07.png"
    F.eq(#name, 35, "the bytes")
    F.eq(Font.len(name), 27, "the cells")
    -- 27 cells is what the portrait list pane allows: the date used to be
    -- cut off because 27 *bytes* did not reach it.
    local shown = Font.clip(Font.upper(name), 27)
    F.has(shown, "2026-09-04", "the date fell off the row")
    F.has(shown, "1.17.07.PNG")
    F.eq(Font.len(shown), 27, "the whole name now fits the pane")
  end)

  F.describe("font / counting and cutting in characters")

  F.it("measures, clips and drops without splitting a character", function()
    F.eq(Font.len("ABC"), 3)
    F.eq(Font.len(NFC), 4, "four syllables, twelve bytes")
    F.eq((Font.measure(NFC, 1)), 32, "four cells of eight pixels")
    F.eq((Font.measure("ABCD", 2)), 64)
    F.eq(Font.clip(NFC, 2), "\236\138\164\237\129\172", "cut on a boundary")
    F.eq(Font.clip(NFC, 9), NFC, "asking for more than there is")
    F.eq(Font.clip(NFC, 0), "")
    F.eq(Font.drop(NFC, 2), "\235\166\176\236\131\183")
    F.eq(Font.drop(NFC, 9), "")
    F.eq(Font.drop("ABCDE", 2), "CDE")
    F.eq(Font.clip("ABCDE", 2), "AB")
  end)

  F.it("raises the ASCII and leaves the other bytes where they are", function()
    F.eq(Font.upper("zkp.mov"), "ZKP.MOV")
    F.eq(Font.upper(NFC), NFC, "a syllable is not a letter to be raised")
    F.eq(Font.upper("photo " .. NFC), "PHOTO " .. NFC)
  end)

  F.it("a byte that is not UTF-8 is one character, and does not eat the line", function()
    local junk = "A\255B"
    F.eq(Font.len(junk), 3)
    F.eq(Font.clip(junk, 2), "A\255")
    F.eq(Font.drop(junk, 2), "B")
    -- A truncated sequence: the lead byte stands alone rather than reading
    -- past the end of the string.
    F.eq(Font.len("A\236\138"), 3)
  end)

  F.describe("font / the face for the other glyphs")

  F.it("finds a face on this machine, or says so plainly", function()
    local data = Font.face()
    if not data then
      F.eq(Font.faceAt(8), nil, "no file, so no face, and no crash")
      return
    end
    F.ok(Font.facePath and #Font.facePath > 0, "a face was loaded from nowhere")
    F.ok(data:getSize() > 0, "the face file is empty")
    local face = Font.faceAt(8)
    F.ok(face ~= nil, "the file opened but the face did not: " .. tostring(Font.facePath))
    F.eq(Font.faceAt(8), face, "the face is made once and kept")
    F.ok(face:getWidth("\236\138\164") > 0, "the face cannot draw a syllable")
  end)
end
