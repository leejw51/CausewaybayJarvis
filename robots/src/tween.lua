local Ease = require("src.ease")

local Tween = { items = {} }

function Tween.clear()
  Tween.items = {}
end

function Tween.kill(obj)
  for i = #Tween.items, 1, -1 do
    if Tween.items[i].obj == obj then table.remove(Tween.items, i) end
  end
end

function Tween.to(obj, dest, dur, easeName, ondone)
  local start = {}
  for k, v in pairs(dest) do
    start[k] = obj[k] or 0
  end
  Tween.items[#Tween.items + 1] = {
    obj = obj,
    start = start,
    dest = dest,
    dur = math.max(0.01, dur or 0.35),
    t = 0,
    ease = Ease[easeName or "outCubic"] or Ease.outCubic,
    done = ondone,
  }
  return Tween.items[#Tween.items]
end

function Tween.update(dt)
  for i = #Tween.items, 1, -1 do
    local tw = Tween.items[i]
    tw.t = tw.t + dt
    local u = tw.t / tw.dur
    if u >= 1 then
      for k, v in pairs(tw.dest) do tw.obj[k] = v end
      table.remove(Tween.items, i)
      if tw.done then tw.done() end
    else
      local k = tw.ease(u)
      for key, dest in pairs(tw.dest) do
        tw.obj[key] = tw.start[key] + (dest - tw.start[key]) * k
      end
    end
  end
end

return Tween
