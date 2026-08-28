--- The sound chip.
---
--- No samples on disk: every effect is synthesised at load into a `SoundData`,
--- the way the machines this looks like had to. A voice is a square, pulse,
--- triangle, saw or noise generator with a pitch glide, a vibrato and a
--- three-segment envelope, and the result is crushed to four bits of
--- amplitude before it is written -- which is most of why it sounds like 1985
--- rather than like a sine wave with the treble turned down.
---
---     sfx.play("equip")
---     sfx.play("blip", 1.4)      -- 1.4x the pitch
---
--- Sounds are layered: `notes` is a list of voices with their own start
--- offsets, so a fanfare is one definition rather than four scheduled calls.

local M = {
  RATE = 22050,
  volume = 0.55,
  muted = false,
}

local TAU = math.pi * 2

-- A deterministic noise source. `math.random` would do, but a fixed sequence
-- means the boot sound is the same one every launch, which for a machine
-- pretending to have a ROM matters more than it sounds like it should.
local seed = 0x1234567
local function noise()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 1073741824 - 1
end

local function crush(sample, bits)
  local levels = 2 ^ (bits or 4) - 1
  return math.floor(sample * levels + 0.5) / levels
end

--- The amplitude envelope: attack up, hold, then a curve down. `shape` picks
--- how the tail falls -- `exp` for a plucked voice, `linear` for a pad, `hit`
--- for something struck.
local function envelope(t, dur, voice)
  local attack = voice.attack or 0.005
  local release = voice.release or (dur - attack)
  if t < attack then return t / attack end
  local u = (t - attack) / math.max(release, 1e-6)
  if u >= 1 then return 0 end
  local shape = voice.shape or "exp"
  if shape == "linear" then return 1 - u end
  if shape == "hit" then return (1 - u) ^ 3 end
  if shape == "hold" then return 1 end
  if shape == "swell" then return math.sin(u * math.pi) end
  return math.exp(-4.5 * u)
end

--- Instantaneous frequency: a glide from `freq` to `to`, an arpeggio through
--- `arp`, or both.
local function frequency(t, dur, voice)
  local f = voice.freq or 440
  if voice.to then
    local u = math.min(t / dur, 1)
    f = f * (voice.to / f) ^ u
  end
  if voice.arp then
    local step = math.floor(t * (voice.arp_rate or 24)) % #voice.arp + 1
    f = f * voice.arp[step]
  end
  if voice.vibrato then
    local depth = voice.vibrato_depth or 0.02
    f = f * (1 + depth * math.sin(t * TAU * voice.vibrato))
  end
  return f
end

local function oscillator(phase, voice, t)
  local wave = voice.wave or "square"
  if wave == "noise" then
    -- Pitched noise: hold each random value for a whole period, so the
    -- "frequency" of a noise voice means something.
    return voice.held or 0
  elseif wave == "square" or wave == "pulse" then
    local duty = voice.duty or 0.5
    if voice.duty_to then duty = duty + (voice.duty_to - duty) * t end
    return phase % 1 < duty and 1 or -1
  elseif wave == "tri" then
    local p = phase % 1
    return p < 0.5 and (p * 4 - 1) or (3 - p * 4)
  elseif wave == "saw" then
    return (phase % 1) * 2 - 1
  end
  return math.sin(phase * TAU)
end

--- Render one definition into a SoundData.
local function render(def)
  local voices = def.notes or { def }
  local length = 0
  for _, voice in ipairs(voices) do
    length = math.max(length, (voice.at or 0) + (voice.dur or 0.1))
  end
  local samples = math.max(2, math.floor(length * M.RATE))
  local data = love.sound.newSoundData(samples, M.RATE, 16, 1)

  local mix = {}
  for i = 0, samples - 1 do mix[i] = 0 end

  for _, voice in ipairs(voices) do
    local start = math.floor((voice.at or 0) * M.RATE)
    local dur = voice.dur or 0.1
    local count = math.floor(dur * M.RATE)
    local phase, held, next_flip = 0, 0, 0
    for n = 0, count - 1 do
      local t = n / M.RATE
      local f = frequency(t, dur, voice)
      phase = phase + f / M.RATE
      if voice.wave == "noise" then
        if phase >= next_flip then
          held = noise()
          next_flip = phase + 1
        end
        voice.held = held
      end
      local sample = oscillator(phase, voice, t / dur)
      if voice.noise_mix then
        sample = sample * (1 - voice.noise_mix) + noise() * voice.noise_mix
      end
      sample = sample * envelope(t, dur, voice) * (voice.vol or 0.5)
      local at = start + n
      if at < samples then mix[at] = mix[at] + sample end
    end
  end

  local bits = def.bits or 4
  for i = 0, samples - 1 do
    local s = math.max(-1, math.min(1, mix[i]))
    data:setSample(i, crush(s, bits))
  end
  return data
end

-- ------------------------------------------------------------- the bank ---

local bank = {}

--- Define a sound. `voices` is the number of copies kept, which is how many
--- of it can sound at once -- the token blip needs several, the fanfare one.
function M.define(name, def, voices)
  local data = render(def)
  local pool = {}
  for i = 1, voices or 3 do
    pool[i] = love.audio.newSource(data, "static")
  end
  bank[name] = { pool = pool, next = 1, data = data }
end

--- Notes, as multiples of a root. Definitions read better in ratios than in
--- hertz when what is wanted is "a fifth above".
local N = {
  root = 1, m2 = 1.0595, M2 = 1.1225, m3 = 1.1892, M3 = 1.2599, P4 = 1.3348,
  tri = 1.4142, P5 = 1.4983, m6 = 1.5874, M6 = 1.6818, m7 = 1.7818, M7 = 1.8877,
  oct = 2,
}

function M.load()
  -- The machine waking up.
  M.define("boot", { notes = {
    { freq = 220, dur = 0.09, wave = "square", vol = 0.35, shape = "hit" },
    { at = 0.10, freq = 880, dur = 0.22, wave = "square", vol = 0.32, duty = 0.25, shape = "exp" },
  } }, 2)

  -- A key in the slot, then the contacts closing: noise, then a low thud.
  M.define("insert", { notes = {
    { freq = 900, dur = 0.16, wave = "noise", vol = 0.30, shape = "linear" },
    { at = 0.14, freq = 120, to = 60, dur = 0.30, wave = "square", vol = 0.45, shape = "hit" },
    { at = 0.14, freq = 2400, dur = 0.06, wave = "noise", vol = 0.25, shape = "hit" },
  } }, 2)

  -- The ROM answering.
  M.define("rom", { notes = {
    { freq = 523, dur = 0.10, wave = "pulse", duty = 0.25, vol = 0.30 },
    { at = 0.10, freq = 659, dur = 0.10, wave = "pulse", duty = 0.25, vol = 0.30 },
    { at = 0.20, freq = 784, dur = 0.10, wave = "pulse", duty = 0.25, vol = 0.30 },
    { at = 0.30, freq = 1047, dur = 0.42, wave = "pulse", duty = 0.5, vol = 0.34 },
  } }, 1)

  M.define("key", { freq = 1800, dur = 0.018, wave = "noise", vol = 0.18, shape = "hit" }, 6)
  M.define("blip", { freq = 1200, dur = 0.022, wave = "square", duty = 0.25, vol = 0.10, shape = "hit" }, 8)
  M.define("think", { freq = 300, to = 520, dur = 0.05, wave = "tri", vol = 0.10, shape = "exp" }, 6)

  M.define("select", { freq = 700, to = 1050, dur = 0.06, wave = "square", vol = 0.25, shape = "hit" }, 4)
  M.define("confirm", { notes = {
    { freq = 784, dur = 0.07, wave = "square", vol = 0.28 },
    { at = 0.07, freq = 1175, dur = 0.14, wave = "square", vol = 0.28, shape = "exp" },
  } }, 3)
  M.define("deny", { notes = {
    { freq = 330, dur = 0.08, wave = "square", duty = 0.125, vol = 0.28 },
    { at = 0.08, freq = 220, dur = 0.20, wave = "square", duty = 0.125, vol = 0.28, shape = "exp" },
  } }, 3)

  -- A plate of armour finding its mounting.
  M.define("clank", { notes = {
    { freq = 3000, dur = 0.05, wave = "noise", vol = 0.32, shape = "hit" },
    { freq = 420, to = 260, dur = 0.22, wave = "square", duty = 0.125, vol = 0.34, shape = "exp" },
    { at = 0.03, freq = 900, dur = 0.10, wave = "tri", vol = 0.20, shape = "exp" },
  } }, 4)

  -- The whole suit, in sequence.
  M.define("suitup", { notes = {
    { freq = 262, dur = 0.09, wave = "pulse", duty = 0.25, vol = 0.26 },
    { at = 0.09, freq = 392, dur = 0.09, wave = "pulse", duty = 0.25, vol = 0.26 },
    { at = 0.18, freq = 523, dur = 0.09, wave = "pulse", duty = 0.25, vol = 0.26 },
    { at = 0.27, freq = 659, dur = 0.09, wave = "pulse", duty = 0.25, vol = 0.28 },
    { at = 0.36, freq = 784, dur = 0.50, wave = "pulse", duty = 0.5, vol = 0.34, shape = "exp" },
    { at = 0.36, freq = 1568, dur = 0.50, wave = "tri", vol = 0.16, shape = "exp" },
    { at = 0.00, freq = 60, dur = 0.60, wave = "noise", vol = 0.14, shape = "swell" },
  } }, 1)

  -- Ghosts'n Goblins: the armour comes off.
  M.define("damage", { notes = {
    { freq = 1600, to = 200, dur = 0.35, wave = "noise", vol = 0.40, shape = "exp" },
    { freq = 300, to = 90, dur = 0.40, wave = "square", duty = 0.125, vol = 0.32, shape = "exp" },
    { at = 0.10, freq = 2600, dur = 0.12, wave = "noise", vol = 0.22, shape = "hit" },
  } }, 2)

  M.define("error", { notes = {
    { freq = 200, dur = 0.12, wave = "square", duty = 0.125, vol = 0.30 },
    { at = 0.13, freq = 160, dur = 0.26, wave = "square", duty = 0.125, vol = 0.30, shape = "exp" },
  } }, 2)

  -- The core charging while the prompt is read.
  M.define("charge", {
    freq = 110, to = 880, dur = 0.9, wave = "saw", vol = 0.16, shape = "swell",
    arp = { 1, 1.5 }, arp_rate = 18,
  }, 2)

  -- An answer arriving.
  M.define("msg", { notes = {
    { freq = 880, dur = 0.05, wave = "tri", vol = 0.22 },
    { at = 0.05, freq = 1319, dur = 0.16, wave = "tri", vol = 0.22, shape = "exp" },
  } }, 3)

  -- Thunder over the castle, once in a while.
  M.define("thunder", {
    freq = 40, to = 18, dur = 1.4, wave = "noise", vol = 0.26, shape = "swell", bits = 5,
  }, 2)

  M.define("page", { freq = 600, dur = 0.03, wave = "noise", vol = 0.14, shape = "hit" }, 4)
  M.define("open", { notes = {
    { freq = 300, to = 900, dur = 0.18, wave = "square", duty = 0.25, vol = 0.24, shape = "exp" },
  } }, 3)
  return M
end

--- Play one, optionally transposed. Pitch is applied to the source, so it
--- costs nothing: the sample is rendered once.
function M.play(name, pitch, volume)
  if M.muted then return end
  local entry = bank[name]
  if not entry then return end
  local source = entry.pool[entry.next]
  entry.next = entry.next % #entry.pool + 1
  source:stop()
  source:setPitch(pitch or 1)
  source:setVolume((volume or 1) * M.volume)
  source:play()
  return source
end

--- The keyboard blip, pitched a little differently every press so a sentence
--- typed fast does not sound like one long tone.
function M.type(char)
  local pitch = 0.9 + ((char and char:byte() or 0) % 7) * 0.05
  M.play("key", pitch)
end

function M.mute(on)
  M.muted = on == nil and not M.muted or on
  if M.muted then love.audio.stop() end
  return M.muted
end

M.notes = N

return M
