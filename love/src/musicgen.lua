--- The music, composed here and synthesised at launch.
---
--- Two mixes of the same eight bars in A minor, at the same tempo and the same
--- length, so they can be looped together and crossfaded by volume alone:
---
---   **hall**  -- what the library sounds like when nothing is happening. A
---               slow triangle pad, an arpeggio at eighths, no drums.
---   **forge** -- what it sounds like while the model is thinking. The same
---               harmony with a pulse bass on eighths, sixteenth arpeggios, a
---               noise backbeat and the lead an octave up.
---
--- Both are rendered in a thread (`musicthread.lua`) because a minute of audio
--- at 22 kHz is a second of arithmetic, and a second is a visible hitch.
---
--- Parts are written as strings on a sixteenth grid, one bar of sixteen
--- characters at a time: a digit or letter starts a note, `.` is a rest and
--- `-` holds the note before it. It is a tracker, which is what everything
--- that sounded like this was written in.

local M = {}

M.RATE = 22050
M.BPM = 126
M.BARS = 8
M.STEPS_PER_BAR = 16

-- A minor, two and a bit octaves. Lower case is the octave below middle,
-- digits the octave above it; `s` is the G sharp that the dominant needs.
local NOTE = {
  A = 110.00, B = 123.47, C = 130.81, D = 146.83, E = 164.81, F = 174.61, G = 196.00,
  a = 220.00, b = 246.94, c = 261.63, d = 293.66, e = 329.63, f = 349.23, g = 392.00,
  s = 415.30,
  ["1"] = 440.00, ["2"] = 493.88, ["3"] = 523.25, ["4"] = 587.33, ["5"] = 659.25,
  ["6"] = 698.46, ["7"] = 783.99, ["8"] = 880.00, ["9"] = 987.77, ["0"] = 1046.50,
  ["S"] = 830.61,
}

-- Am - Am - F - G - Am - C - F - E. Eight bars that come back round to the
-- start, which is all a loop has to do.
local BASS = {
  "A.......A...E...",
  "A.......A...E...",
  "F.......F...C...",
  "G.......G...D...",
  "A.......A...E...",
  "C.......C...G...",
  "F.......F...C...",
  "E.......E...B...",
}

-- The arpeggio: chord tones, up and back down, on sixteenths.
local ARP = {
  "aceaceacaecaecae",
  "aceaceacaecaecae",
  "facfacfafcafcafc",
  "gbdgbdgbgdbgdbgd",
  "aceaceacaecaecae",
  "cegcegcegcegcege",
  "facfacfafcafcafc",
  "esbesbesbesbeseb",
}

-- The tune. Chord tones on the beat, scale steps in between, and a G sharp in
-- the last bar so that the loop point pulls rather than merely repeats.
local LEAD = {
  "5---.7--8---7-5-",
  "4---.3--4-------",
  "6---5---3---4---",
  "7---4---2---4---",
  "8---.7--5---3-5-",
  "7---5---3---5---",
  "6---8---6---5---",
  "4---3---2---S---",
}

-- Kick on one and three, snare on two and four, hats on eighths. Written on
-- the same grid: `K` kick, `S` snare, `h` hat.
local DRUM = {
  "K.h.S.h.K.h.S.h.",
  "K.h.S.h.K.h.S.hh",
  "K.h.S.h.K.h.S.h.",
  "K.h.S.h.K.hhS.hh",
  "K.h.S.h.K.h.S.h.",
  "K.h.S.h.K.h.S.hh",
  "K.h.S.h.K.h.S.h.",
  "K.h.S.h.K.hhSShh",
}

-- The drum "notes": a pitch each, so the same sequencer carries them.
local DRUMS = { K = 90, S = 900, h = 4200 }

--- Turn a part into note events: `{at, dur, freq}`, in seconds.
local function events(part, step_seconds, transpose, map)
  map = map or NOTE
  local out = {}
  local open
  for bar, pattern in ipairs(part) do
    for i = 1, #pattern do
      local char = pattern:sub(i, i)
      local step = (bar - 1) * M.STEPS_PER_BAR + (i - 1)
      if char == "-" then
        if open then open.dur = open.dur + step_seconds end
      elseif char == "." then
        open = nil
      else
        local freq = map[char]
        if freq then
          open = { at = step * step_seconds, dur = step_seconds, freq = freq * (transpose or 1), key = char }
          out[#out + 1] = open
        end
      end
    end
  end
  return out
end

local seed = 0x2A6D3C1
local function noise()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 1073741824 - 1
end

--- Add one note to the buffer. `voice` decides the waveform and the shape of
--- its decay; everything here is the same three-line synthesiser the sound
--- effects use, which is the point -- one chip, one voice count, one sound.
local function play(buffer, samples, event, voice)
  local start = math.floor(event.at * M.RATE)
  local length = math.floor(math.min(event.dur * (voice.gate or 0.9), voice.max or 4) * M.RATE)
  local phase, held, flip = 0, 0, 0
  local levels = 15

  for n = 0, length - 1 do
    local at = start + n
    if at >= samples then break end
    local t = n / M.RATE
    local u = n / math.max(length - 1, 1)

    local f = event.freq
    if voice.drop then f = f * (1 - voice.drop * u) end
    phase = phase + f / M.RATE

    local sample
    if voice.wave == "noise" then
      if phase >= flip then held = noise() flip = phase + 1 end
      sample = held
    elseif voice.wave == "tri" then
      local p = phase % 1
      sample = p < 0.5 and (p * 4 - 1) or (3 - p * 4)
    elseif voice.wave == "saw" then
      sample = (phase % 1) * 2 - 1
    else
      sample = (phase % 1) < (voice.duty or 0.5) and 1 or -1
    end

    local env
    if voice.shape == "hold" then
      env = math.min(1, n / (0.01 * M.RATE)) * (1 - u * (voice.fade or 0.2))
    elseif voice.shape == "hit" then
      env = (1 - u) ^ 3
    elseif voice.shape == "swell" then
      env = math.sin(u * math.pi)
    else
      env = math.exp(-3.2 * u) * math.min(1, n / (0.004 * M.RATE))
    end

    sample = sample * env * voice.vol
    -- Four bits of amplitude, per voice rather than per mix: the crunch has
    -- to happen before the parts are added or it just sounds like clipping.
    sample = math.floor(sample * levels + 0.5) / levels
    buffer[at] = buffer[at] + sample
  end
end

--- Render one mix. `parts` is a list of `{events, voice}`.
local function render(parts, seconds)
  local samples = math.floor(seconds * M.RATE)
  local buffer = {}
  for i = 0, samples - 1 do buffer[i] = 0 end
  for _, part in ipairs(parts) do
    for _, event in ipairs(part.events) do play(buffer, samples, event, part.voice) end
  end
  local data = love.sound.newSoundData(samples, M.RATE, 16, 1)
  for i = 0, samples - 1 do
    local s = buffer[i]
    -- Soft clip rather than hard: four voices at once do go over one, and a
    -- square wave that clips flat sounds like a fault rather than like loud.
    if s > 1 then s = 1 - 1 / (1 + s) elseif s < -1 then s = -1 + 1 / (1 - s) end
    data:setSample(i, s * 0.9)
  end
  return data
end

--- Both mixes, and how long a loop lasts.
function M.generate()
  local step = 60 / M.BPM / 4
  local seconds = M.BARS * M.STEPS_PER_BAR * step

  local bass = events(BASS, step)
  local arp = events(ARP, step)
  local lead = events(LEAD, step)
  local drum = events(DRUM, step, 1, DRUMS)

  -- The quiet mix. The arpeggio is thinned to eighths by dropping every other
  -- event, the pad holds, and there is nothing to keep time with.
  local thinned = {}
  for i, event in ipairs(arp) do
    if i % 2 == 1 then thinned[#thinned + 1] = event end
  end
  local pad = {}
  for i, event in ipairs(bass) do
    pad[#pad + 1] = { at = event.at, dur = event.dur * 3, freq = event.freq * 2 }
    if i % 2 == 1 then
      pad[#pad + 1] = { at = event.at, dur = event.dur * 3, freq = event.freq * 3 }
    end
  end

  local hall = render({
    { events = pad, voice = { wave = "tri", vol = 0.22, shape = "hold", fade = 0.35, gate = 1.0 } },
    { events = thinned, voice = { wave = "square", duty = 0.125, vol = 0.10, gate = 0.5 } },
    { events = lead, voice = { wave = "tri", vol = 0.16, gate = 0.95, shape = "hold", fade = 0.5 } },
  }, seconds)

  -- The loud one. Same harmony, twice the motion.
  local kick, snare, hat = {}, {}, {}
  for _, event in ipairs(drum) do
    if event.key == "K" then
      kick[#kick + 1] = { at = event.at, dur = 0.16, freq = 90 }
    elseif event.key == "S" then
      snare[#snare + 1] = { at = event.at, dur = 0.12, freq = 900 }
    else
      hat[#hat + 1] = { at = event.at, dur = 0.04, freq = 4200 }
    end
  end

  local forge = render({
    { events = bass, voice = { wave = "square", duty = 0.5, vol = 0.26, gate = 0.55 } },
    { events = arp, voice = { wave = "square", duty = 0.25, vol = 0.13, gate = 0.6 } },
    { events = lead, voice = { wave = "square", duty = 0.375, vol = 0.20, gate = 0.9 } },
    { events = kick, voice = { wave = "noise", vol = 0.30, shape = "hit", drop = 0.7, gate = 1 } },
    { events = snare, voice = { wave = "noise", vol = 0.22, shape = "hit", gate = 1 } },
    { events = hat, voice = { wave = "noise", vol = 0.10, shape = "hit", gate = 1 } },
  }, seconds)

  return { hall = hall, forge = forge, seconds = seconds, bpm = M.BPM }
end

return M
