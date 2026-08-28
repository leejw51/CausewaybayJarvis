--- Tweens and timers, small enough to read in one sitting.
---
---     local t = tween.new()
---     t:to(panel, 0.4, {y = 20}, "outBack")
---     t:after(1.0, function() sfx.play("equip") end)
---     t:every(0.2, spark, 8)
---
--- A tween writes numeric fields of a table over time; a timer just calls
--- something later. Both live in the same list so one `:update(dt)` per scene
--- drives everything, and `:clear()` at a scene change cannot leave a stray
--- callback firing into a scene that has gone.

local ease = require("src.ease")

local Timeline = {}
Timeline.__index = Timeline

local M = {}

function M.new()
  return setmetatable({ items = {}, time = 0 }, Timeline)
end

local function add(self, item)
  item.elapsed = 0
  self.items[#self.items + 1] = item
  return item
end

--- Move `subject`'s fields to `target` over `duration`, after `delay`.
--- Returns the item, whose `on_done` may be set to a function.
function Timeline:to(subject, duration, target, curve, delay)
  local from = {}
  for key in pairs(target) do from[key] = subject[key] or 0 end
  return add(self, {
    kind = "tween",
    subject = subject,
    duration = math.max(duration, 1e-6),
    delay = delay or 0,
    from = from,
    target = target,
    curve = ease.get(curve),
  })
end

--- Drive a bare function with the eased fraction, for anything that is not a
--- field on a table -- a draw offset computed three ways, a shader uniform.
function Timeline:run(duration, curve, fn, delay)
  return add(self, {
    kind = "run",
    duration = math.max(duration, 1e-6),
    delay = delay or 0,
    curve = ease.get(curve),
    fn = fn,
  })
end

function Timeline:after(delay, fn)
  return add(self, { kind = "after", delay = delay, fn = fn })
end

--- Call `fn(n)` every `interval`, `count` times -- nil for forever.
function Timeline:every(interval, fn, count)
  return add(self, { kind = "every", delay = interval, interval = interval, fn = fn, left = count, n = 0 })
end

--- Run the items in order, each starting when the last finished. Returns the
--- total duration, which is what a scene wants for its own bookkeeping.
function Timeline:sequence(steps)
  local at = 0
  for _, step in ipairs(steps) do
    local delay, duration = at, step.duration or 0
    if step.fn and not step.subject then
      self:after(delay, step.fn)
    elseif step.subject then
      self:to(step.subject, duration, step.target, step.curve, delay)
      if step.fn then self:after(delay, step.fn) end
    end
    at = at + duration + (step.gap or 0)
  end
  return at
end

function Timeline:cancel(item)
  for i, other in ipairs(self.items) do
    if other == item then table.remove(self.items, i) return true end
  end
  return false
end

function Timeline:clear()
  self.items = {}
end

function Timeline:count() return #self.items end

function Timeline:update(dt)
  self.time = self.time + dt
  local i = 1
  while i <= #self.items do
    local item = self.items[i]
    local done = false

    if item.delay > 0 then
      item.delay = item.delay - dt
      if item.delay < 0 then
        -- Spend the overshoot on the item itself, so a chain of tweens does
        -- not drift a frame later with every link.
        dt = -item.delay
        item.delay = 0
      end
    end

    if item.delay <= 0 then
      if item.kind == "after" then
        item.fn()
        done = true
      elseif item.kind == "every" then
        item.n = item.n + 1
        item.fn(item.n)
        item.delay = item.interval
        if item.left then
          item.left = item.left - 1
          done = item.left <= 0
        end
      else
        item.elapsed = item.elapsed + dt
        local t = math.min(item.elapsed / item.duration, 1)
        local eased = item.curve(t)
        if item.kind == "tween" then
          for key, to in pairs(item.target) do
            item.subject[key] = item.from[key] + (to - item.from[key]) * eased
          end
        else
          item.fn(eased, t)
        end
        done = t >= 1
      end
    end

    if done then
      table.remove(self.items, i)
      if item.on_done then item.on_done() end
    else
      i = i + 1
    end
  end
end

return M
