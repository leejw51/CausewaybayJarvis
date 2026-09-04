# Causewaybay Jarvis

An on-device AI agent. Rust end to end, running **Qwen3.8-27B** (4-bit) on
**Apple MLX** — the transformer itself is a Rust port, not a binding to a Python
runtime. Nothing leaves the machine after the weights are downloaded once.

```
                          ┌──────────────────────────────┐
  rustcli  (CLI/REPL)     │           rustcore           │
  rusttui  (full screen)  │  config · Hugging Face pull  │
  lua/chat.lua ─┐         │  tokenizer · chat template   │
  love/    ─────┤         │  Engine trait, streaming     │
        │       │         │                              │
        │  rustffi (C ABI)└───────────────┬──────────────┘
        └───────┴────────────────────────►│
                                          │
                          ┌───────────────▼──────────────┐
                          │           rustmlx            │
                          │  Qwen3.5 hybrid on mlx-rs    │
                          │  16 × gated attention        │
                          │  48 × gated DeltaNet         │
                          │  4-bit quantized_matmul      │
                          │  custom Metal scan kernel    │
                          └──────────────────────────────┘

  robots/  (LOVE)         ┌──────────────────────────────┐
        │                 │          rustagent           │
        └───jsonl────────►│  ~/.causewaybayjarvis        │
                          │  one GUID + one folder each  │
                          │  BM25 (FTS5) + vectors, RRF  │
                          │  tools · harness · router    │
                          │  ollama.com or a daemon      │
                          └──────────────────────────────┘
```

Two halves that share a folder — and, since `make gui`, one client that joins
them: the **AI-agent robot system** (twelve AI agents, each a GUID with a
folder of its own photos, files, markdown and memory — one agent *is* one
folder, and the tower on screen has one floor per folder) with the
27-billion-parameter model as its **on-device brain**, and ollama.com as the
optional cloud one for a Mac that is not powerful enough. The brain lives in
**one server**: `make start` runs `agentd` as a service, and every client —
the LÖVE window, the Lua CLI, `rustcli` — talks to it over a socket. No
client loads the weights itself, and the server loads them on the first
turn that needs them, not at start.
`F9` switches between the brains mid-conversation; an explicit choice that
cannot run is refused with the reason, never quietly substituted. A Mac
without the weights can still answer on-device from a local **ollama
daemon** holding the same `qwen3.8:27b-mlx` tag (`ollama serve`, then
`make ollama-model`). Both brains are set up on the client's **SETTINGS > AI**
tab, or with `agentd config`.

## Quick start

```sh
make setup     # check the toolchain, and the on-device / cloud AI setup
make model     # download the weights once (~15 GiB)
make chat      # talk to it

make start     # the backend: agentd as a service — Qwen3.8-27B on-device, ollama.com on F9
make gui       # just the LÖVE client, no build: the Lua iteration loop
make love2d    # build + start the backend, then the client
make package   # the release: the signed app, backend inside it (dist/)
make face      # one agent, one conversation, nothing else
make ai        # the AI setup as the backend sees it, and where each value came from

make start     # the robot backend as a service under Python's supervisord,
               # on a fixed port (AGENT_PORT=47421) — prints the port it took
make status    # is it up, and where
make stop      # down again, along with any daemon a client left behind
make api       # the backend over HTTP instead: REST, and turns that stream
make web       # the web client: every agent and every shelf, in the browser
make start BIND=0.0.0.0   # …and on the Wi-Fi, for an iPhone or an iPad
```

### One server, every client on a socket — or no server at all

The model is loaded once, by `agentd`, and every client is a socket to it:
the LÖVE client and `rustcli` over a **WebSocket**, the Lua CLI and TUI
over **HTTP with server-sent events** through `curl`, and `nc` over plain
line JSON — all on the one port the space's `agentd.port` names. No client
loads weights. Close the LÖVE window and reopen it and the brain is still
warm; a fault in the engine takes the server down and not the screen; a
second client shares the same loaded model and the same archive.

`make start` runs one as a service, and every client then finds it. One
server per space: a second `agentd listen` on a space whose server still
answers refuses to start rather than take another port behind the first
one's clients. `make start` needs `pip install supervisor` (part of `make
install`).

The other way in has no server in it at all. `libjarvis` carries the same
backend, and a client that loads it calls the ops in its own process —
`jarvis_agent_open`, then `jarvis_agent_call` with the request as JSON —
getting back the same envelope a socket would have carried, from the same
dispatch in `rustagent::server::answer`. That is what the packaged app is:
one bundle with the library beside the LÖVE binary, nothing to install
next to it, nothing to start, nothing left running when the window closes.
The trade is the warm brain — a model loaded into the app dies with it —
which is why the LÖVE client still prefers a daemon when it finds one
already up, and only calls the library when it does not.

### Answers arrive as they are written

A turn against the on-device model takes seconds, so nothing waits for the
whole of it. The engine reports every token through a callback, and that
runs the length of the chain — through the brain, through the tool loop,
onto the socket as a frame, and into the screen that draws it. Over the
WebSocket a turn is `chunk` frames and then the reply; over HTTP the same
turn is an event stream:

```sh
make api                                     # the server in the foreground, on 8808
curl localhost:8808/health
curl localhost:8808/v1/agents.list -d '{}'   # any op: POST /v1/<op>
curl -N 'localhost:8808/v1/chat/stream?text=what+is+a+mutex'
websocat ws://localhost:8808/ws              # {"id":1,"op":"chat","text":"…"}
```

The stream is server-sent events — `token` frames as the model writes,
`tool` when the turn runs one, and a final `done` frame carrying exactly
what `POST /v1/chat` would have returned. A client that reads only `done`
is a correct client. The WebSocket is the same pieces with an `id` the
client chooses, and a `stop` it can send mid-turn. The server binds
loopback and has no authentication: anything that can reach the port can
read the archive and spend the GPU.

### The web client

The server is also a web page. `make web` opens `http://127.0.0.1:<port>/`
against whatever `make start` left running, and what comes up is every
agent on a rail and every shelf under the one chosen — photos as a grid
with a lightbox, videos playing inline, files, notes rendered from their
markdown, the papers, the transcript with a turn streamed as it is written,
and the same BM25-plus-vectors search the LÖVE window runs. **Add** (or a
file dropped anywhere on the page, or the camera button on a phone) files
a photo, a video or anything else with the chosen agent, through the same
`item.add` every other client uses. The page is compiled into `agentd`;
there is nothing to build or serve beside it.

It binds `127.0.0.1` unless told otherwise. To open it on an iPhone or an
iPad on the same Wi-Fi:

```sh
make start BIND=0.0.0.0      # or: agentd listen --bind 0.0.0.0, or JARVIS_BIND=0.0.0.0
```

The server then prints every address it answers on — the LAN address and
the Mac's `.local` name — and the share button on the page shows the same,
ready to type on the phone; "Add to Home Screen" there opens it in its own
window. There is no login on the page: anything that can reach the port can
read the archive and spend the GPU, which is why loopback is the default
and opening it is a flag.

Behind the page the HTTP surface grew two routes any client can use:
`GET /file/<path>` hands out what is on a shelf by the relative path the
database holds (byte ranges honoured, which is what a phone needs to play a
video), and `POST /upload?agent=…&name=…` files the request body. `GET
/api` is the JSON index that used to live at `/`, and `GET /where` says
which addresses the server answers on.

### Videos, and the clip LÖVE plays

A video filed with an agent — dropped on either window, picked from a
phone's camera roll, or `agentd add holiday.mov --agent food` — lands on a
**videos** shelf of its own, untouched. LÖVE cannot play it: `love.graphics
.newVideo` decodes Ogg Theora and nothing else. So the backend encodes the
first **three seconds** as a Theora clip beside it, no larger than 640
pixels and silent, plus one frame as a PNG poster:

```text
agents/<GUID>/videos/holiday.mov              the original — the browser plays this
agents/<GUID>/videos/holiday.clip.ogv         3 s, Ogg Theora — the LÖVE window plays this
agents/<GUID>/videos/holiday.poster.png       one frame, for a thumbnail
```

The row's `meta` names both, and the VIDEO shelf on the agent page loops
the clip. Encoding needs `ffmpeg` to decode whatever the phone recorded and
`ffmpeg2theora` to write Theora — Homebrew's ffmpeg no longer links
libtheora — and `make install` installs both. Without them the video is
still filed; its `meta` carries the sentence that says what to install,
and the shelf shows it.

`make setup` is worth reading if it fails: building MLX needs Apple's **Metal
compiler**, which ships inside Xcode rather than the Command Line Tools. Every
`cargo` line in the Makefile therefore runs with `DEVELOPER_DIR` pointed at
Xcode. Building outside the Makefile needs the same:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  cargo build --release --manifest-path rust/Cargo.toml
```

Set `HF_TOKEN` for gated repositories; public ones need nothing.

## Using it

```sh
rustcli                       # the chat REPL (the default command)
rustcli run "why is the sky blue?"
echo "summarise this" | rustcli run
rustcli --model qwen3.8:27b-mlx-8bit chat
rustcli pull                  # download without chatting
rustcli info                  # what is configured and what is on disk
rustcli models                # the aliases this build knows
rustcli bench                 # prefill and decode throughput (drives the engine here)
rustcli agent health          # any backend op, over the server
rustcli agent chat --agent food "what's for dinner?"
rusttui                       # full-screen chat
make knight                   # the original LOVE chat client (the knight)
```

### The same two clients, in Lua

The server speaks HTTP, so a client needs nothing but LuaJIT and `curl`.
Lua has both front ends the Rust side has — the same panes, the same keys,
none of the same code — and a turn arrives as server-sent events:

```sh
make lua-chat                 # the REPL:        lua/chat.lua  ≈ rustcli
make luatui                   # full-screen:     lua/tui.lua   ≈ rusttui
```

(`libjarvis`, the C ABI, is what the knight client and the Lua CLI's
`pull` / `info` / `bench` drive the raw model session through — and, since
the robot backend moved into it as well, what the packaged app answers
every op with.)

`lua/tui.lua` streams the answer into the transcript as the model writes
it, and Escape stops a turn without leaving the session — both because the
token callback is where the screen is redrawn and the keyboard is read.
`lua/jarvis/term.lua` is the terminal layer under it: raw mode, a
non-blocking key, and a size, in about two hundred lines.

### The robots

```sh
make robots                            # the AI agents: one folder, one floor each
make face                              # face mode
make archive                           # what they know, and where it is kept
make agent A="route 'why won\'t this borrow?'"
make paper A=food                      # one agent's archive as one 1024x1024 PNG
```

Each robot is a GUID with its own corner of `~/.causewaybayjarvis`: photos,
files, markdown, notes and every word it has been told, in its **own SQLite
file** (`agent.db`, with a BM25 index and a vector index over the same rows)
mirrored to `items.jsonl`, `items.csv` and `agent.md` beside it, and indexed
again in the global `robots.db`. Choose a robot and it answers — and searches
— out of its own database; choose none and every robot is searched at once,
and the words pick who answers: a question about a borrow checker summons the
coding robot, a question about dinner summons the galley. `F2` is that
robot's page, `F4` is its face, and dropping a file on the window files it.
Type `photo` or `file` for a file box, `gallery` for the photo shelf as a
grid, `search …` for BM25 + vectors, and `paper` to draw the whole archive
as one 1024x1024 PNG.

The whole half runs with no key: BM25 is SQLite's own, semantic search falls
back to a local embedder, and a turn answers out of the archive and says the
link is down. See [`robots/`](robots) and [`rust/rustagent`](rust/rustagent).

In the REPL: `/help`, `/reset`, `/think on|off`, `/effort low|medium|xhigh`,
`/temp`, `/max`, `/system`, `/show`, `/stats`, `/save`, `/model`, `/exit`.
Ctrl-C stops a long answer without leaving the session; Ctrl-D quits.

In the TUI: enter sends, Esc stops a running answer, Ctrl-R resets, Ctrl-T
shows or hides the reasoning pane, Ctrl-K turns thinking off, PgUp/PgDn scroll.

## The model

`qwen3.8:27b-mlx` resolves to `mlx-community/Qwen3.8-27B-4bit`: 26.9B
parameters, 4-bit affine quantization in groups of 64, about 15 GiB on disk and
roughly the same resident. The text tower is what runs; the vision tower in the
checkpoint is skipped.

Qwen3.5 is a **hybrid**. Of its 64 decoder layers only every fourth is ordinary
attention — gated grouped-query attention over 24 heads and 4 KV heads, with a
partial rotary embedding that rotates the first quarter of each 256-wide head.
The other 48 are [gated DeltaNet](rust/rustmlx/src/delta.rs): linear attention
that carries a fixed `[48, 128, 128]` matrix of associations instead of a
growing cache. Each position decays that matrix, reads back what the current key
already retrieves, and writes in the difference:

```
S ← S · g
S ← S + k ⊗ β(v − S k)
y  = S q
```

That is why the cache stays small: after 639 tokens the whole KV footprint is
about 187 MiB, because three quarters of the layers contribute a constant.

The recurrence is sequential, so it is a [custom Metal
kernel](rust/rustmlx/src/kernel.rs): one simd-group per (batch, head, value
dimension), the state held in registers, two `simd_sum` reductions per step. One
dispatch per layer instead of roughly ten array operations per position.
`JARVIS_DELTA_KERNEL=0` selects the portable array-ops path instead — the two
are checked against each other in the tests.

## The cartridge

There is also a game.

```sh
make gui         # the LOVE client, on the real weights
make gui-demo    # the same client with a recorded model — no weights needed
```

A 720x405 screen, a Super Famicom palette, a 6x8 font drawn by hand, an MSX2
boot sequence and a cathode ray tube. The model is a knight standing in a
Bohemian street at night, drawn deliberately bare — gambeson, tabard, helm and
the sword he leans on, and no plate anywhere. The ring of sockets around him is
the **harness** — memory, tools, retrieval, a planner, a critic, a sandbox, an
eye, a voice — and you bolt them on one plate at a time, or all at once with
`F9`, or lose one to a fault with `F10`. `F2` drops the whole thing back to
sixteen colours, MSX2 and then Apple II, if you want to see where it came
from; `F7` turns the whole client on its side, two columns becoming two bands;
`F11` fills the display.

The point of drawing it this way is that it is true: a language model continues
text, and everything that makes it an agent is strapped on around it — which is
also exactly what a knight is under the armour. The
modules are registered, they take sockets, and they are called at every point
in a turn where the real work would go — **and they are all empty**. The client
says so on its own harness screen. Wiring them up is the next piece of work;
this is the frame it goes into.

It runs the same `libjarvis` everything else here does, on a worker thread,
because `jarvis_send` blocks. See [`love/README.md`](love/README.md).

## Layout

| path | what it holds |
| --- | --- |
| `rust/rustcore` | `config.jsonl`, the model registry, Hugging Face downloads, the tokenizer, the chat template, the `Engine` trait and the reasoning/answer splitter |
| `rust/rustmlx` | the Qwen3.5 tower on `mlx-rs`: quantized linear and embedding layers, gated attention, gated DeltaNet, the Metal kernel, caches, sampling |
| `rust/rustffi` | `libjarvis`, the C ABI: opaque handles, JSON results, streaming through a callback. `include/jarvis.h` is the canonical declaration |
| `rust/rustcli` | the `rustcli` binary — REPL, one-shot `run`, `pull`, `info`, `bench` |
| `rust/rusttui` | the `rusttui` binary — full-screen chat on ratatui |
| `lua/` | the Lua client: LuaJIT `ffi` bindings over `libjarvis`, and a chat CLI with the same commands as `rustcli`. See [`lua/README.md`](lua/README.md) |
| `love/` | the LÖVE client: the same bindings behind sixteen colours, an MSX boot and an agent harness you can see. See [`love/README.md`](love/README.md) |
| `tools/` | `reference_logits.py`, which dumps what `mlx_lm` produces, and `grokart.sh`, which paints the LÖVE client's backgrounds |
| `rust-toolchain.toml` | the pinned toolchain — at the root, because rustup resolves it from the working directory the Makefile runs cargo in, not from the workspace |
| `config.jsonl` | all configuration, one `{"key":…, "value":…}` per line |

## Configuration

`config.jsonl` is read from the working directory (walking upwards), then from
beside the binary, then from a copy compiled into it. `JARVIS_CONFIG` or
`--config` override that. Keys: `app`, `model`, `generation`, `thinking`,
`system_prompt`, `paths`, `runtime`. Anything absent falls back to a default, so
a partial file is fine.

## Testing

```sh
make test         # unit and integration tests that need no weights
make test-model   # the ones that load the real checkpoint
make verify       # compare against mlx_lm, token for token
make ci           # formatting, clippy, and make test
```

`make test` covers the Lua client too, through `make test-lua`. That needs
LuaJIT — `brew install luajit` — and skips loudly without it, the same bargain
the GPU-only tests make.

The port is checked against the reference implementation rather than against
itself. `tools/reference_logits.py` runs a fixed prompt through `mlx_lm` and
writes the top-10 logits and a greedy continuation to `tools/reference.json`;
`make verify` replays the same prompt through this code and compares:

```
token       reference         rust      delta
760           27.1250      27.2500     0.1250
57590         18.3750      18.5000     0.1250
...
largest logit difference: 0.1250      ← one bfloat16 ULP at this magnitude
top-10 ordering mismatches: 2
greedy tokens matching: 24/24
```

`make test-model` additionally checks, against the real weights, that greedy
decoding is deterministic, that a seed is reproducible, that generation stops at
the end of a turn, that a caller can interrupt it, that a follow-up turn reuses
the prompt cache, that reasoning is separated from the answer, and that the
Metal kernel tracks the array-ops path.

MLX drives a single GPU queue, so tests that touch it must run with
`--test-threads=1`; the Makefile passes that everywhere.

`JARVIS_NO_METAL=1` pretends the machine has no GPU: MLX moves to the CPU
device and the tests that need a real Metal device skip themselves, saying so,
rather than failing. `make test-nogpu` is the whole suite in that mode — 91 of
the 96 tests still run. It exists because a hosted CI runner has no GPU, and
the only way to check that path is from a machine that does:

```sh
make test-nogpu   # what CI runs
make test         # everything, including the Metal kernels
```

It is a simulation of a missing GPU, not of Metal itself: the five skipped
tests — the custom kernel, and the three that check the kernel against the
array-ops path — are exactly the ones a GPU-less run cannot vouch for. Run
`make test` on a real Mac before trusting a change to `kernel.rs` or `delta.rs`.

`.github/workflows/ci.yml` runs these on every push and pull request, in two
lanes. **core** is the quick one — `rustcore` depends on no MLX, so it needs
neither Xcode nor a GPU and reports in a couple of minutes. **workspace** is
the real gate, and it pays for MLX: `mlx-sys` compiles MLX and its Metal
shaders from source, which needs the Metal *compiler* from Xcode but no Metal
*device*. Both run macOS; there is no Linux lane, because there is no Linux
build. Neither runs `make test-model` or `make verify` — those download 15 GiB.

## Releasing

`make package` builds one thing: the LÖVE client as a macOS app with
`libjarvis` — the backend itself — beside the LÖVE binary inside the bundle,
signed and zipped into `dist/`. The app calls the backend in its own process,
so a release is one download with no server to install beside it.

`make package-bin` is still there and is not part of a release: the terminal
binaries — `rustcli`, `rusttui`, `agentd` — signed and tarred for anyone who
wants them on their own.

Signing is ad hoc unless you name a certificate. Ad hoc is not nothing: on
Apple silicon an unsigned executable does not run at all. What it costs is
portability, so a build meant to leave the machine needs the real one:

```sh
export APPLE_SIGNING_IDENTITY="Developer ID Application: … (TEAMID)"
export APPLE_ID=… APPLE_PASSWORD=… APPLE_TEAM_ID=…   # app-specific password
make package         # builds and signs the app
make notarize-app    # notarizes it and staples the ticket into it
```

A signature is necessary and not sufficient: since macOS 10.15 a download from
outside the App Store must be notarized too, or Gatekeeper refuses it with
"Apple could not verify…". The bundle gets the ticket stapled into it, so it
opens offline; a bare binary has nowhere to keep one and pays for an online
check the first time it runs.

The app is built out of the upstream LÖVE release, fetched by
`tools/get-love.sh` and checked against a pinned hash — `make install-love`,
which `make install` calls. Homebrew disabled the `love` cask on 2026-09-01
because the bundle upstream ships fails Gatekeeper; packaging copies that
bundle and signs the result, so the objection does not carry over, but the
cask is gone either way.

Pushing a tag like `v0.1.0` to a commit on `main` runs
`.github/workflows/release.yml`, which does all of the above on an Apple
Silicon runner and attaches the artifacts to a GitHub release. It refuses a tag
that is not on `main`, and a tag that disagrees with `make version` — the
number in `rust/Cargo.toml`, which is stamped into every artifact name. The
certificate and the notarization credentials come from the repository secrets
`MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `APPLE_ID`,
`APPLE_APP_SPECIFIC_PASSWORD` and `TEAM_ID`; without them the run still
finishes, signed ad hoc.

## Housekeeping

Three levels of tidying up, smallest first. `make clear` throws away runtime
scratch — the `data/` directory, the REPL history and any stray test
temporaries — and leaves build output alone. `make clean` removes build output.
`make distclean` does both and drops the downloaded weights as well.

## Performance

M4 Max, 36 GiB, 512-token prompt, 128 generated:

| | Metal kernel | array ops |
| --- | ---: | ---: |
| prefill | 124.5 tok/s | 78.7 tok/s |
| decode | 17.1 tok/s | 15.4 tok/s |

For reference `mlx_lm` reaches about 23 tok/s decoding the same checkpoint. The
remaining gap is graph-level: `mlx-rs` exposes no equivalent of `mx.compile`, so
the elementwise chains in the MLP and the norms are dispatched one operation at
a time rather than fused.

## Limits

- Text only. The vision tower in the checkpoint is not loaded.
- One sequence at a time; there is no batching.
- No tool calling yet. The template supports it and `RenderOptions::tools`
  reaches the prompt, but nothing parses a `<tool_call>` back out — which is
  also why the LÖVE client's harness sockets are wired to nothing.
- The multi-token-prediction head of the MTP checkpoints is ignored.
