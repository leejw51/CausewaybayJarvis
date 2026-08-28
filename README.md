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
```

## Quick start

```sh
make setup     # check the toolchain
make model     # download the weights once (~15 GiB)
make chat      # talk to it
```

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
rustcli bench                 # prefill and decode throughput
rusttui                       # full-screen chat
luajit lua/chat.lua           # the same REPL, driven from Lua
love love                     # the same model, in sixteen colours
```

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
