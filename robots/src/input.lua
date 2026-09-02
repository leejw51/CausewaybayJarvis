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

return Input
