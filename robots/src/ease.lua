-- Classic Love2D / Penner easings. t is 0..1.

local Ease = {}

function Ease.linear(t) return t end

function Ease.inQuad(t) return t * t end
function Ease.outQuad(t) return 1 - (1 - t) * (1 - t) end
function Ease.inOutQuad(t)
  if t < 0.5 then return 2 * t * t end
  return 1 - ((-2 * t + 2) ^ 2) / 2
end

function Ease.inCubic(t) return t * t * t end
function Ease.outCubic(t)
  local u = 1 - t
  return 1 - u * u * u
end
function Ease.inOutCubic(t)
  if t < 0.5 then return 4 * t * t * t end
  return 1 - ((-2 * t + 2) ^ 3) / 2
end

function Ease.outQuart(t)
  local u = 1 - t
  return 1 - u * u * u * u
end

function Ease.inExpo(t)
  if t <= 0 then return 0 end
  return 2 ^ (10 * t - 10)
end

function Ease.outExpo(t)
  if t >= 1 then return 1 end
  return 1 - 2 ^ (-10 * t)
end

function Ease.inOutExpo(t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  if t < 0.5 then return (2 ^ (20 * t - 10)) / 2 end
  return (2 - 2 ^ (-20 * t + 10)) / 2
end

function Ease.inSine(t) return 1 - math.cos(t * math.pi * 0.5) end
function Ease.outSine(t) return math.sin(t * math.pi * 0.5) end
function Ease.inOutSine(t) return -(math.cos(math.pi * t) - 1) * 0.5 end

function Ease.outBack(t)
  local c1 = 1.70158
  local c3 = c1 + 1
  local u = t - 1
  return 1 + c3 * u * u * u + c1 * u * u
end

function Ease.outElastic(t)
  if t == 0 or t == 1 then return t end
  return 2 ^ (-10 * t) * math.sin((t * 10 - 0.75) * (2 * math.pi / 3)) + 1
end

function Ease.outBounce(t)
  local n1, d1 = 7.5625, 2.75
  if t < 1 / d1 then
    return n1 * t * t
  elseif t < 2 / d1 then
    t = t - 1.5 / d1
    return n1 * t * t + 0.75
  elseif t < 2.5 / d1 then
    t = t - 2.25 / d1
    return n1 * t * t + 0.9375
  else
    t = t - 2.625 / d1
    return n1 * t * t + 0.984375
  end
end

function Ease.lerp(a, b, t) return a + (b - a) * t end

function Ease.smooth(current, target, dt, speed)
  local k = 1 - math.exp(-speed * dt)
  return current + (target - current) * k
end

return Ease
