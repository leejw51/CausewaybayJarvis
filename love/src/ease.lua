--- Easing curves. Each takes a fraction from 0 to 1 and returns one -- Penner's
--- set, normalised, so a tween is just `from + (to - from) * ease(t)`.
---
--- The ones that matter here: `outBack` for anything that snaps into place
--- (panels, armour plates), `outElastic` for anything that lands and rings
--- (the cartridge seating in the slot), `outQuint` for anything that has to
--- feel heavy, and `outBounce` for anything that falls off.

local sin, cos, pi, pow, sqrt, abs = math.sin, math.cos, math.pi, function(a, b) return a ^ b end, math.sqrt, math.abs

local M = {}

function M.linear(t) return t end

function M.inQuad(t) return t * t end
function M.outQuad(t) return t * (2 - t) end
function M.inOutQuad(t)
  if t < 0.5 then return 2 * t * t end
  return -1 + (4 - 2 * t) * t
end

function M.inCubic(t) return t * t * t end
function M.outCubic(t) return 1 + (t - 1) ^ 3 end
function M.inOutCubic(t)
  if t < 0.5 then return 4 * t * t * t end
  return 1 + 4 * (t - 1) ^ 3
end

function M.inQuart(t) return t ^ 4 end
function M.outQuart(t) return 1 - (t - 1) ^ 4 end
function M.inOutQuart(t)
  if t < 0.5 then return 8 * t ^ 4 end
  return 1 - 8 * (t - 1) ^ 4
end

function M.inQuint(t) return t ^ 5 end
function M.outQuint(t) return 1 + (t - 1) ^ 5 end
function M.inOutQuint(t)
  if t < 0.5 then return 16 * t ^ 5 end
  return 1 + 16 * (t - 1) ^ 5
end

function M.inSine(t) return 1 - cos(t * pi / 2) end
function M.outSine(t) return sin(t * pi / 2) end
function M.inOutSine(t) return -(cos(pi * t) - 1) / 2 end

function M.inExpo(t) return t == 0 and 0 or pow(2, 10 * (t - 1)) end
function M.outExpo(t) return t == 1 and 1 or 1 - pow(2, -10 * t) end
function M.inOutExpo(t)
  if t == 0 or t == 1 then return t end
  if t < 0.5 then return pow(2, 20 * t - 10) / 2 end
  return (2 - pow(2, -20 * t + 10)) / 2
end

function M.inCirc(t) return 1 - sqrt(1 - t * t) end
function M.outCirc(t) return sqrt(1 - (t - 1) ^ 2) end
function M.inOutCirc(t)
  if t < 0.5 then return (1 - sqrt(1 - 4 * t * t)) / 2 end
  return (sqrt(1 - (-2 * t + 2) ^ 2) + 1) / 2
end

-- Overshoot. 1.70158 is the constant that makes `outBack` overshoot by ten
-- per cent, which is the amount that reads as "it snapped in" rather than
-- "it wobbled".
local BACK = 1.70158

function M.inBack(t) return (BACK + 1) * t ^ 3 - BACK * t * t end
function M.outBack(t)
  local u = t - 1
  return 1 + (BACK + 1) * u ^ 3 + BACK * u * u
end
function M.inOutBack(t)
  local c = BACK * 1.525
  if t < 0.5 then return (2 * t) ^ 2 * ((c + 1) * 2 * t - c) / 2 end
  return ((2 * t - 2) ^ 2 * ((c + 1) * (t * 2 - 2) + c) + 2) / 2
end

function M.outElastic(t)
  if t == 0 or t == 1 then return t end
  return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * pi / 3)) + 1
end

function M.inElastic(t)
  if t == 0 or t == 1 then return t end
  return -pow(2, 10 * t - 10) * sin((t * 10 - 10.75) * (2 * pi / 3))
end

function M.outBounce(t)
  local n, d = 7.5625, 2.75
  if t < 1 / d then return n * t * t end
  if t < 2 / d then
    t = t - 1.5 / d
    return n * t * t + 0.75
  end
  if t < 2.5 / d then
    t = t - 2.25 / d
    return n * t * t + 0.9375
  end
  t = t - 2.625 / d
  return n * t * t + 0.984375
end

function M.inBounce(t) return 1 - M.outBounce(1 - t) end

--- Not an easing curve: a damped oscillation around zero, for shake and for
--- anything still ringing after it has arrived.
function M.ring(t, frequency, damping)
  return sin(t * (frequency or 18)) * pow(2.718281828, -t * (damping or 6))
end

--- Look one up by name, tolerating a function that is already one.
function M.get(name)
  if type(name) == "function" then return name end
  return M[name or "linear"] or M.linear
end

return M
