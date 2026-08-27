# The LÖVE client

The same model as [`rustcli`](../rust/rustcli), behind a 720x405 screen with a
16-bit palette, a 6x8 font and a cathode ray tube. Nothing is reimplemented:
the tokenizer, the chat template, the Qwen3.5 tower and the Metal kernels are
the Rust ones, reached through `libjarvis` — the same C ABI the
[Lua CLI client](../lua) uses, loaded here by LÖVE's LuaJIT on a worker thread.

```sh
make gui         # build libjarvis and start it
make gui-demo    # the same client with a recorded model — no weights needed
make art         # paint the backgrounds with Grok (once, needs XAI_API_KEY)
```

Flags: `--demo`, `--model ALIAS`, `--palette snes|msx|apple2`, `--plate NAME`,
`--portrait` / `--landscape`, `--fullscreen` / `--windowed`, `--no-crt`. The
layout and the window mode are remembered between runs, in `settings` in the
save directory.

`brew install --cask love` if LÖVE is missing.

## What it is

A language model on its own is a thing that continues text. Everything that
makes it an **agent** — memory, tools, retrieval, a planner, a critic, a
sandbox — is bolted on around it. So the model is drawn as a knight standing in
a Bohemian street at night, and drawn deliberately **bare**: a padded gambeson,
a tabard, a belt, a helm and the sword he is leaning on, and no plate anywhere.
Every piece of armour is a harness module. Take them all off and that is what a
language model is, which is the joke Ghosts'n Goblins made about armour first
and the reason the avatar is a knight rather than a mascot.

The conceit runs all the way down. The machine boots, counts its memory,
reports both cartridge slots empty, and does nothing at all until a ROM goes
into slot one — which is when the fifteen gigabytes finish mounting on the
worker thread and the familiar wakes up.

**The harness modules are not wired to the model yet.** That is the state of
this release, and the client says so on its own harness screen. What exists is
the shape: a module declares itself, takes a socket, and is called at the
points in a turn where the real work would go.

## Playing it

| | |
| --- | --- |
| type, `ENTER` | say something |
| `ESC` | stop the answer, or close an overlay |
| `TAB` | the harness |
| `1`-`8` | bolt one module on, or take it off |
| `F9` | **suit up** — the whole harness, in sequence |
| `F10` | **take a hit** — lose a plate, Ghosts'n Goblins rules |
| `F1` | the key card |
| `F2` | palette: SNES, MSX2, Apple II |
| `F3` | the plate behind you: seven of Prague |
| `F7` | layout: across or down |
| `F8` | text size: 1, 2, 3, or automatic |
| `F12` | the settings page |
| `F4` `F5` `F6` | music, sound, the tube |
| `F11`, Alt+Enter | fullscreen or windowed |
| `PGUP` `PGDN`, wheel | scroll the transcript |
| `CTRL-E` | **export** — the transcript in all four formats |
| `CTRL-C` `CTRL-V` | copy the transcript · paste into the box |
| `CTRL-R` `CTRL-T` | forget the conversation · reasoning on or off |

`F7` and `F11` are also buttons — `ACROSS`/`DOWN` and `WINDOW`/`FULL` — in the
status bar of the chat and in the corner of every screen the machine draws
while it boots. Each is labelled with what the client *is* rather than with
what the button does, because a pair of buttons that name their opposite is a
pair you have to think about.

`EXPORT` and `COPY` sit in the top rail of the transcript, and `PASTE` in the
rail of the box you type in — cut into the masonry beside the title, because
neither panel has a row to spare. On a narrow screen at a large font the title
gives way to them and not the other way round.

## Getting the conversation out

`EXPORT` writes the whole transcript four ways at once, under one timestamp,
into `~/.causewaybayjarvis` — where the project keeps its state, rather than
the LÖVE save folder under Application Support, which is where the screenshots
go and where nothing else would look for a transcript. A card then says what
was written and where, because a toast is gone in two seconds and the path is
the point.

| | |
| --- | --- |
| `.jsonl` | one message to a line, `you`/`jarvis` mapped to `user`/`assistant`, ready to hand back to a model |
| `.md` | a heading per turn |
| `.csv` | RFC 4180, so a reply keeps its paragraphs inside one cell |
| `.txt` | the role in brackets on its own line, then what was said |

`COPY` puts the plain-text form on the clipboard; `PASTE` takes the clipboard
into the input box, folding its line breaks to spaces, because the box is one
line and `ENTER` sends. `/export` does the same as the button and
`/export csv` writes just the one.

Slash commands mirror `rustcli` and `lua/chat.lua`, so muscle memory carries
across: `/help` `/reset` `/think` `/stats` `/system` `/plate` `/palette`
`/suit` `/hit` `/strip` `/quit`.

## Adding a harness module

`src/harness.lua` is a registry. A module declares itself and takes the next
socket; the ring re-lays itself out, so nothing else has to change:

```lua
harness.register{
  id = "memory", name = "MEMORY", glyph = "book", slot = "cyan",
  key = "1", blurb = "keeps what was said, and what it meant",

  on_turn_start = function(module, ctx)
    ctx.prompt = recall(ctx.prompt)      -- rewriting it is the point
  end,
  on_turn_end = function(module, ctx)
    remember(ctx.reply, ctx.stats)
  end,
}
```

The hooks, in the order a turn fires them: `on_equip`, `on_turn_start`
(`ctx.prompt`, rewritable), `on_prefill` (`ctx.done` of `ctx.total`),
`on_reasoning` (`ctx.text`), `on_token` (`ctx.text`), `on_turn_end`
(`ctx.reply`, `ctx.stats`), `on_error` (`ctx.message`), `on_remove`.

A hook that raises is caught, the module is knocked off with a bang, and the
turn carries on — the same bargain the C ABI makes with a Lua callback, for the
same reason. Until hooks are wired, `harness.pulse()` lights the ring on every
turn so that the animation has something to say; when they are real, delete it.

## How it is put together

| file | what it holds |
| --- | --- |
| `main.lua` | the canvas, the CRT pass, scene switching, the global keys |
| `conf.lua` | the window. 1440x810 divides into a 720x405 canvas, two screen pixels per drawn one |
| `worker.lua` | the model, on its own thread, and the recorded stand-in for when there are no weights |
| `musicthread.lua` | renders the two music loops at launch, off the main thread |
| `src/layout.lua` | every rectangle in the chat scene, computed from the canvas size — pure arithmetic, no `love.*`, testable headlessly |
| `src/transcript.lua` | the conversation as JSONL, Markdown, CSV or plain text — pure string work, no `love.*`, no clock |
| `src/store.lua` | `~/.causewaybayjarvis`, and writing into it: outside the LÖVE sandbox, so plain `io` |
| `src/toggles.lua` | the two window buttons, drawn the same way wherever they appear |
| `src/settings.lua` | the settings page, shared by both scenes |
| `src/palette.lua` | three palettes: a Super Famicom one, and the two 8-bit ones it can drop to |
| `src/pixelfont.lua` | the font, drawn by hand — 5x7 glyphs in a 6x8 cell, which is MSX2 `SCREEN 0: WIDTH 80` |
| `src/text.lua` | the atlas, markup, wrapping, and folding Unicode down to what the font has |
| `src/shaders.lua` | the quantiser — posterise to the five-bit grid, or nearest of sixteen — and the tube |
| `src/sfx.lua` | the sound chip: square, pulse, triangle, saw and noise, crushed to four bits |
| `src/musicgen.lua` | eight bars of A minor as a tracker, mixed two ways |
| `src/ease.lua` `src/tween.lua` | the curves, and the timeline everything animates on |
| `src/particles.lua` | pixels with a palette ramp instead of an alpha fade |
| `src/art.lua` | the plates: loading, quantising, and the skyline drawn from rectangles when they are absent |
| `src/ui.lua` | stone windows, gauges, beams, rings |
| `src/avatar.lua` | fifty-six pixels of unarmoured knight |
| `src/harness.lua` | the registry above |
| `src/scenes/boot.lua` | the tube warming up, the POST, the cartridge |
| `src/scenes/chat.lua` | the conversation |
| `src/shots.lua` | a hand on the keyboard: `--shots` plays a script and photographs every screen |

## The screen

It opens filling the display and there is no letterbox at any shape, which
takes both halves of one idea: the **scale** is a whole number — half a pixel
of a 6x8 font is not a font — and the **canvas** is then whatever that scale
divides the window into. The scale taken is the largest that still leaves at
least `FIT` — 340 in `main.lua` — along the window's **short** side, whichever
side that is; `MIN_W`/`MIN_H` is the floor a window too small for even one such
scale falls back to. Every case fills to the edge:

| window | scale | canvas | columns | letter |
| ---: | ---: | ---: | ---: | ---: |
| 1440x810 | 2 | 720x405 | 71 | 12px |
| 1920x1080 | 3 | 640x360 | 62 | 18px |
| 3840x2160 | 6 | 640x360 | 62 | 36px |
| 810x1080 | 2 | 405x540 | 64 | 12px |
| 1080x1920 | 3 | 360x640 | 57 | 18px |
| 480x270 | 1 | 480x270 | 46 | 6px |

The short side and not a width-and-height pair, because a pair has to be turned
for a tall window and then gets the turn wrong — 810x1080 misses a 560 height
by twenty pixels and falls to a scale of one, losing all the chunk, when it is
a perfectly good 405x540 at two.

`FIT` and the divisor in `layout.compute` are one knob between them: `FIT`
decides how big the canvas is and the divisor decides how big the letters on it
are, so moving either alone just cancels the other out. Raising `FIT` gives
smaller letters and more of them.

`F11` (or the `WINDOW`/`FULL` button) comes back out, and whichever was chosen
last is what it opens as next time. The fit is *checked* every frame rather
than waited for as an event, because `love.resize` does not fire for every way
a window can change size — a programmatic `setMode` among them, and a canvas
that has stopped matching its window is bars down two sides.

## The letters

One face, at whole-number scales — scaling a bitmap font by two or three with a
nearest filter keeps every edge exactly on a pixel, where a second larger raster
would not match it. The scale is picked from the width the transcript is about
to get, so a panel holds roughly fifty to seventy characters however large the
canvas is: a 1080x1920 canvas at one scale is a hundred and seventy characters
across, which is not a column of prose but a spreadsheet. `F8` overrides it, and 1, 2
and 3 are all usable — the interface is laid out in character widths rather than
in pixels, so the harness card drops its descriptions and the status bar drops
its counters rather than printing them on top of each other.

## Which way up

Landscape is two columns, the knight standing beside what he said. Portrait is
two bands, him above it, because a column 130 pixels wide cannot hold a
transcript and a knight side by side. What is shared is the chrome: the status
bar at the top and the input at the bottom, in the same place either way.

`F7` (or the `ACROSS`/`DOWN` button) picks one. Until it is pressed there is no
preference at all and the canvas decides — bands on a tall screen, columns on a
wide one — so the client suits the display it was opened on without being told.

An arrangement has a shape, and when the window is the other way up the
arrangement is **letterboxed into the shape it wants** rather than stretched to
fill one it does not: two columns in a canvas twice as tall as it is wide is a
column of conversation beside a column of nothing. Ask for `ACROSS` on a tall
display and you get a 16:9 band with black above and below it; ask for `DOWN` on
a wide one and you get a tall strip. The tolerance is wide — anything within
about forty per cent of the shape it wants is left alone and simply fills — so
the bars only appear when they are the better answer.

`src/layout.lua` is that arrangement and nothing else: one function from a
canvas size to every rectangle, with no `love.*` anywhere in it, so the numbers
can be checked without a graphics context.

Two things have to happen in the right order when any of this changes, and both
were bugs first. The window mode is changed **before** anything is re-baked,
because changing it empties every canvas the client holds — do it the other way
round and all seven backgrounds come back blank. And the transcript is
**re-wrapped**, because lines are wrapped once when they arrive (so that
scrolling costs nothing) and a line wrapped for a 46-column panel is four
characters too long for a 40-column one.

## Waiting for fifteen gigabytes

The first run has to fetch the checkpoint, and that is a long time to watch a
bar. So the wait is the game: the knight is **put into his harness a plate at a
time**, an eighth of the bytes per piece, and the last one lands as the model
comes up. The plate behind him is an armourer's forge while the bytes are
coming in and a hall of floating steel once they are here.

In front of him is an anvil. `SPACE` swings the hammer — strike as the ring
closes on the anvil for a `PERFECT`, which builds a combo and drives the heat
up; fill the heat and the whole screen goes `WHITE HOT`. It does not make the
download go one byte faster and the screen says so, in small letters, under the
prompt.

The panel underneath is the honest part: bytes of bytes, per cent, which file
of how many, and the path they are landing in — the standard Hugging Face cache
(`~/.cache/huggingface/hub/models--…`, or wherever `HF_HOME` points). When the
weights are already on disk there is nothing to fetch, the suit goes on in about
two seconds, and the boot goes straight through.

## Settings

`F12`, or the `SETUP` button, on the boot screen and in the chat alike:

| | |
| --- | --- |
| `FONT` | 1, 2, 3, or automatic |
| `LAYOUT` | across or down |
| `SCREEN` | window or fullscreen |
| `COLOUR` | SNES, MSX2, Apple II |
| `WEIGHTS` | which model, where its cache is, and how much room it takes |

The path is sixty-four characters and the panel holds about thirty, so rather
than cut it — which loses either the cache it is in or the model it is — the
repository and the directory take a line each, and only a panel wide enough to
hold the whole path shows the whole path.

And `ERASE THE WEIGHTS`, which takes two clicks: the second one within three
seconds. The worker refuses any path that is not a Hugging Face cache entry it
computed itself, which is the only reason a delete like that is allowed near a
channel at all.

## The colours

Three palettes, and the client is built for the first one.

**SNES** is the default: every colour sits on the five-bit-per-channel grid a
Super Famicom could address, and there are enough of them to shade a sprite
properly — three or four tones per material off a fixed ramp, which is what
`avatar.lua` draws against. Backgrounds are posterised and dithered rather than
crushed, which is what a painted 16-bit background actually was.

`F2` drops it to **MSX2** (sixteen colours on the V9938's eight-level ladder,
every plate quantised to exactly those sixteen) and then to **Apple II**. The
sprite ramps collapse to aliases of the sixteen, so the knight still draws —
with less shading, and with the backgrounds visibly dithered rather than
painted. It is the same picture, two console generations apart.

## The backgrounds

Seven plates of Prague — a Gothic Old Town lane in the fourteenth century,
Golden Lane at the castle, the Klementinum library hall, Hradčany across the
Vltava, the astronomical tower, the Charles Bridge in fog, and the cartridge
itself — painted by Grok at 1280x720 and quantised at load. `make art` paints them; `tools/grokart.sh --force`
repaints them; `GROK_IMAGE_MODEL` picks a different one.

They are **not committed**, for the same reason the weights are not. A checkout
without them draws Hradčany out of rectangles instead and never mentions it, so
`make gui-demo` works on a machine with no API key and no model at all.

## Where the model runs

On a thread. `jarvis_send` blocks for as long as an answer takes and fires its
token callback from inside itself, so it cannot share a thread with sixty
frames a second. `worker.lua` owns the session and talks to the game over three
channels — commands down, events up, and a third that means *stop*, polled from
inside the token callback. That is the same trick `lua/chat.lua` plays with
SIGINT, for the same reason: a callback that has to return into Rust can set a
flag and nothing else.

Closing the window is a two-step, and has to be. MLX's Metal device is a C++
global destroyed by the static destructors that run on the main thread as the
process exits; if the worker is still inside `jarvis_send` when that happens it
hands a freed compute pipeline to the driver and the process dies with SIGSEGV
on the way out. So `love.quit` refuses the first quit, interrupts the turn,
asks the worker to close, and takes the quit only once that thread has actually
gone — with a six-second cap, so a wedged worker costs six seconds rather than
a window that will not close. It says `PUTTING THE MODEL DOWN` while it waits.
This was not theoretical: before the wait, quitting crashed two runs in three.

The `--demo` path is the same code with a recorded model behind it, streaming
canned answers at a plausible seventeen tokens a second. It exists so that the
client can be worked on — and judged — without fifteen gigabytes on disk, and
it says `DEMO - RECORDED` in the status bar for as long as it is on.

## Limits

- Text only, one turn at a time — the same limits the rest of the workspace has.
- Ninety-five glyphs. Anything else is folded to the nearest ASCII on the way to
  the screen (`Malá Strana` draws as `Mala Strana`); what you type is sent to
  the model unfolded, but CJK will not draw.
- One window, one model. Turning the screen re-bakes seven backgrounds, which
  is a few milliseconds and is why it is not animated.
- The knight has one pose. He breathes, sways, leans on the sword while it
  thinks and takes a hit when a plate comes off, but he does not walk.
- The harness hooks fire and are empty. That is the next piece of work.
