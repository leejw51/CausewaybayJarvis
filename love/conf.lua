-- The window. Everything is drawn into a canvas and blown up from there, so
-- this size only decides how big the pixels are: `best_fit` in `main` divides
-- 1440x810 into a 720x405 canvas at two screen pixels each, which is what a
-- 27" display wants.

function love.conf(t)
  t.identity = "causewaybay-jarvis"
  t.version = "11.5"
  t.console = false

  t.window.title = "CAUSEWAYBAY JARVIS"
  t.window.width = 1440
  t.window.height = 810
  t.window.minwidth = 480
  t.window.minheight = 270
  t.window.resizable = true
  -- Filling the display is the point: the canvas is sized to whatever whole
  -- scale divides the window, so there is no letterbox at any shape. F11, or
  -- the WINDOW button on the title screen, comes back out -- and whichever
  -- was chosen last is what it opens as next time.
  t.window.fullscreen = true
  t.window.fullscreentype = "desktop"
  t.window.vsync = 1
  t.window.highdpi = true
  -- No multisampling. This is pixel art, and the one thing it must not have
  -- is anti-aliased edges.
  t.window.msaa = 0

  -- Nothing here needs a physics world, a gamepad or a video decoder.
  t.modules.physics = false
  t.modules.joystick = false
  t.modules.video = false
  t.modules.touch = false
end
