-- Immediate-mode input snapshot
local Input = {
  mx = 0, my = 0,
  pressed = false,
  released = false,
  down = false,
  keys = {},
  text = "",
  backspace = false,
  wheel = 0,
}

function Input.begin()
  Input.pressed = false
  Input.released = false
  Input.keys = {}
  Input.text = ""
  Input.backspace = false
  Input.wheel = 0
end

function Input.wheelmoved(dy)
  Input.wheel = (Input.wheel or 0) + dy
end

function Input.mousepressed()
  Input.pressed = true
  Input.down = true
end

function Input.mousereleased()
  Input.released = true
  Input.down = false
end

function Input.keypressed(key)
  Input.keys[key] = true
  if key == "backspace" then Input.backspace = true end
end

function Input.textinput(t)
  Input.text = Input.text .. t
end

-- Did the operator touch anything this frame? The autopilot watches this.
function Input.any()
  if Input.pressed or Input.released or Input.backspace then return true end
  if Input.text ~= "" or (Input.wheel or 0) ~= 0 then return true end
  for _ in pairs(Input.keys) do return true end
  return false
end

function Input.wasKey(key)
  return Input.keys[key] == true
end

--- Take this frame's events away from whoever reads them next, and hand
--- back what was taken so `restore` can give them to the one screen that
--- should see them: the file box drawn over everything else.
function Input.mask()
  local taken = {
    pressed = Input.pressed, released = Input.released, keys = Input.keys,
    text = Input.text, backspace = Input.backspace, wheel = Input.wheel,
  }
  Input.pressed, Input.released, Input.keys = false, false, {}
  Input.text, Input.backspace, Input.wheel = "", false, 0
  return taken
end

function Input.restore(taken)
  if not taken then return end
  Input.pressed, Input.released, Input.keys = taken.pressed, taken.released, taken.keys
  Input.text, Input.backspace, Input.wheel = taken.text, taken.backspace, taken.wheel
end

return Input
