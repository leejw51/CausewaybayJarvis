function love.conf(t)
  t.identity = "causewaybay-jarvis-robots"
  t.version = "11.5"
  t.console = false
  t.accelerometerjoystick = false

  t.window.title = "CAUSEWAY BAY // JARVIS 2"
  t.window.width = 1280
  t.window.height = 720
  t.window.minwidth = 640
  t.window.minheight = 360
  t.window.resizable = true
  t.window.fullscreen = os.getenv("JARVIS_TEST") ~= "1"
  -- Borderless "desktop" fullscreen is the only mode macOS screen capture
  -- can see; JARVIS_FULLSCREEN=exclusive trades that for the notch band.
  t.window.fullscreentype = os.getenv("JARVIS_FULLSCREEN") == "exclusive"
    and "exclusive" or "desktop"
  t.window.vsync = 1
  t.window.msaa = 0
  t.window.highdpi = false


  t.modules.physics = false
  t.modules.touch = false
  -- The VIDEO shelf plays the Ogg Theora clip the backend makes beside
  -- every filed video (src/videos.lua).
  t.modules.video = true
  t.modules.thread = true
end
