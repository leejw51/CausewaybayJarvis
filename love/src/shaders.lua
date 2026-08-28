--- Two shaders, and the ordered-dither texture they share.
---
--- **quantize** is what makes a photograph look like it came off a cartridge:
--- an 8x8 Bayer threshold is added to each pixel and the result is snapped to
--- the nearest of the sixteen palette colours. Because the palette is a
--- uniform, switching from MSX2 to Apple II re-quantises the backgrounds too.
---
--- **crt** is the tube: barrel distortion, an aperture grille, scanlines at
--- the *virtual* resolution rather than the window's, a little bloom from four
--- taps, chromatic fringing at the edges, a vignette, mains flicker and a
--- brightness band that rolls down the screen every few seconds.
---
--- Both are written for GLSL 1.20, which is what LÖVE compiles to on macOS:
--- no dynamic array indexing, no textureLod, no integer arithmetic.

local palette = require("src.palette")

local M = {}

local QUANTIZE = [[
extern vec3 palette[16];
extern Image dither;
extern float spread;      // how far the threshold may push a pixel
extern float contrast;
extern float brightness;
extern float saturation;
extern vec3 tint;         // pulled towards, before matching
extern float tint_amount;
extern float snap;        // 0: nearest of the sixteen. 1: posterise to `levels`
extern float levels;      // steps per channel, before the five-bit grid

vec4 effect(vec4 colour, Image tex, vec2 uv, vec2 screen)
{
    vec4 src = Texel(tex, uv) * colour;

    // Grade first: the palette is small, so the choice of which sixteen
    // colours a pixel is *near* is most of the picture.
    vec3 c = src.rgb;
    c = (c - 0.5) * contrast + 0.5 + brightness;
    float grey = dot(c, vec3(0.299, 0.587, 0.114));
    c = mix(vec3(grey), c, saturation);
    c = mix(c, tint, tint_amount);

    float threshold = Texel(dither, screen / 8.0).r - 0.5;
    c += threshold * spread;

    if (snap > 0.5) {
        // 16-bit: posterise to a few steps per channel with the dither
        // carrying the gradients, then land on the five-bit grid, which is
        // the whole colour space a Super Famicom had. Thousands of colours
        // rather than sixteen, but still a countable number of them.
        c = clamp(c, 0.0, 1.0);
        c = floor(c * levels + 0.5) / levels;
        c = floor(clamp(c, 0.0, 1.0) * 31.0 + 0.5) / 31.0;
        return vec4(c, src.a);
    }

    // 8-bit: nearest of the sixteen, by squared distance. Sixteen is few
    // enough that the obvious loop is also the fast one.
    float best = 1e9;
    vec3 chosen = palette[0];
    for (int i = 0; i < 16; i++) {
        vec3 p = palette[i];
        vec3 d = c - p;
        float distance = dot(d, d);
        if (distance < best) { best = distance; chosen = p; }
    }
    return vec4(chosen, src.a);
}
]]

local CRT = [[
extern vec2 virtual_size;   // the low-resolution grid, for scanline pitch
extern float time;
extern float curvature;
extern float scan_depth;
extern float mask_depth;
extern float bloom;
extern float aberration;
extern float flicker;
extern float roll;          // 0 disables the rolling band
extern float pixel_scale;   // output pixels per phosphor stripe
extern float glitch;        // 0 normal, 1 the screen is having a moment

vec2 curve(vec2 uv)
{
    uv = uv * 2.0 - 1.0;
    vec2 offset = abs(uv.yx) / vec2(6.0, 5.0);
    uv += uv * offset * offset * curvature;
    return uv * 0.5 + 0.5;
}

vec4 effect(vec4 colour, Image tex, vec2 uv, vec2 screen)
{
    vec2 warped = curve(uv);

    // Tearing: a few rows slide sideways while a glitch lasts.
    if (glitch > 0.0) {
        float band = step(0.5, fract(warped.y * 9.0 + time * 3.0));
        warped.x += (band - 0.5) * 0.04 * glitch * sin(time * 40.0);
    }

    if (warped.x < 0.0 || warped.x > 1.0 || warped.y < 0.0 || warped.y > 1.0)
        return vec4(0.0, 0.0, 0.0, 1.0);

    vec2 texel = 1.0 / virtual_size;

    // Chromatic fringing, strongest at the edges where the tube is worst.
    float edge = length(uv - 0.5) * aberration;
    vec3 c;
    c.r = Texel(tex, warped + vec2(edge * texel.x, 0.0)).r;
    c.g = Texel(tex, warped).g;
    c.b = Texel(tex, warped - vec2(edge * texel.x, 0.0)).b;

    // Bloom: four taps, only the parts brighter than the picture.
    vec3 glow = vec3(0.0);
    glow += Texel(tex, warped + vec2( texel.x * 1.5, 0.0)).rgb;
    glow += Texel(tex, warped + vec2(-texel.x * 1.5, 0.0)).rgb;
    glow += Texel(tex, warped + vec2(0.0,  texel.y * 1.5)).rgb;
    glow += Texel(tex, warped + vec2(0.0, -texel.y * 1.5)).rgb;
    glow *= 0.25;
    c += max(glow - c, 0.0) * bloom;

    // Scanlines on the virtual grid, so they do not shimmer when the window
    // is resized to something that is not a whole multiple.
    float line = sin(warped.y * virtual_size.y * 3.14159265);
    c *= 1.0 - scan_depth * line * line;

    // The shadow mask: three phosphor stripes per output pixel triad.
    float phase = mod(floor(screen.x / pixel_scale), 3.0);
    vec3 mask = vec3(1.0 - mask_depth);
    if (phase < 1.0)      mask.r = 1.0 + mask_depth;
    else if (phase < 2.0) mask.g = 1.0 + mask_depth;
    else                  mask.b = 1.0 + mask_depth;
    c *= mask;

    // Mains hum, and a brightness band drifting down the tube.
    c *= 1.0 - flicker * 0.5 + flicker * 0.5 * sin(time * 46.0);
    if (roll > 0.0) {
        float band = fract(warped.y - time * 0.09);
        c += roll * 0.06 * exp(-band * band * 260.0);
    }

    // Vignette.
    vec2 v = uv * (1.0 - uv.yx);
    c *= pow(clamp(v.x * v.y * 48.0, 0.0, 1.0), 0.11);

    return vec4(c, 1.0) * colour;
}
]]

--- The 8x8 ordered dither, as a texture rather than an array: GLSL 1.20 will
--- not index a constant array with a varying, and a 64-pixel texture costs
--- nothing.
local function dither_texture()
  local BAYER = {
     0, 32,  8, 40,  2, 34, 10, 42,
    48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,
    60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,
    51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,
    63, 31, 55, 23, 61, 29, 53, 21,
  }
  local data = love.image.newImageData(8, 8)
  for y = 0, 7 do
    for x = 0, 7 do
      local v = (BAYER[y * 8 + x + 1] + 0.5) / 64
      data:setPixel(x, y, v, v, v, 1)
    end
  end
  local image = love.graphics.newImage(data)
  image:setFilter("nearest", "nearest")
  image:setWrap("repeat", "repeat")
  return image
end

function M.load()
  M.dither = dither_texture()
  M.quantize = love.graphics.newShader(QUANTIZE)
  M.crt = love.graphics.newShader(CRT)

  M.quantize:send("dither", M.dither)
  M.quantize:send("spread", 0.16)
  M.quantize:send("contrast", 1.18)
  M.quantize:send("brightness", -0.02)
  M.quantize:send("saturation", 1.25)
  M.quantize:send("tint", { 0.1, 0.08, 0.2 })
  M.quantize:send("tint_amount", 0.0)
  M.quantize:send("snap", 0.0)
  M.quantize:send("levels", 13.0)
  M.send_palette()

  M.crt:send("curvature", 0.10)
  M.crt:send("scan_depth", 0.15)
  M.crt:send("mask_depth", 0.06)
  M.crt:send("bloom", 0.70)
  M.crt:send("aberration", 1.6)
  M.crt:send("flicker", 0.02)
  M.crt:send("roll", 1.0)
  M.crt:send("glitch", 0.0)
  M.crt:send("pixel_scale", 1.0)
  M.crt:send("virtual_size", { 480, 270 })
  M.crt:send("time", 0)
  return M
end

--- Push the sixteen current colours at the quantiser. Called again whenever
--- the palette changes.
function M.send_palette()
  local colors = {}
  for i = 1, 16 do colors[i] = palette.c(i) end
  M.quantize:send("palette", unpack(colors))
end

--- Grade the next thing quantised. Used to push a plate colder or warmer than
--- it was painted, which is how one background serves two moods.
function M.grade(options)
  options = options or {}
  -- Which of the two quantisers runs is the palette's business, not the
  -- plate's: the same background is sixteen colours under MSX and a few
  -- thousand under SNES.
  M.quantize:send("snap", palette.quantize == "levels" and 1.0 or 0.0)
  M.quantize:send("levels", options.levels or palette.levels or 13)
  M.quantize:send("spread", options.spread or palette.spread or 0.16)
  M.quantize:send("contrast", options.contrast or 1.18)
  M.quantize:send("brightness", options.brightness or -0.02)
  M.quantize:send("saturation", options.saturation or 1.25)
  M.quantize:send("tint", options.tint or { 0.1, 0.08, 0.2 })
  M.quantize:send("tint_amount", options.tint_amount or 0)
end

function M.update(dt, options)
  M.time = (M.time or 0) + dt
  M.crt:send("time", M.time)
  if options then
    for key, value in pairs(options) do M.crt:send(key, value) end
  end
end

return M
