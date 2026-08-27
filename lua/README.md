# The Lua client

A chat client for [Causewaybay Jarvis](../README.md) written in Lua, talking to
the same Rust workspace the `rustcli` binary uses. Nothing is reimplemented: the
tokenizer, the chat template, the Qwen3.5 tower and the Metal kernels are all
the Rust ones, reached through `libjarvis` — the C ABI that
[`rust/rustffi`](../rust/rustffi) exports.

```sh
make ffi                       # build libjarvis once
luajit lua/chat.lua            # the chat REPL
luajit lua/chat.lua run "why is the sky blue?"
make lua-chat                  # both of the above, in one target
```

LuaJIT, not Lua: the binding is `ffi.cdef`, which plain Lua has no equivalent
for. `brew install luajit`.

## Layout

| file | what it holds |
| --- | --- |
| `jarvis/ffi.lua` | the `cdef`, a copy of `rust/rustffi/include/jarvis.h`, plus finding and version-checking the library |
| `jarvis/json.lua` | a JSON reader, because structured results cross the boundary as text |
| `jarvis/init.lua` | the binding proper: `config`, `models`, `pull`, `open`, and the session object |
| `jarvis/ui.lua` | colour, a status line that redraws in place, byte and token formatting |
| `chat.lua` | the client: argument parsing, the REPL and its `/commands`, `run`, `pull`, `info`, `models`, `bench` |
| `test.lua` | the tests, run by `make test` |

## Using the binding

```lua
local jarvis = require("jarvis")

local session = assert(jarvis.open("qwen3.8:27b-mlx"))
session:set_system("You are Jarvis.")

local params = jarvis.params()
params.temperature = 0
params.max_tokens = 256

local reply = assert(session:send("why is the sky blue?", params, function(kind, text)
  if kind == "token" then io.write(text) io.flush() end
end))

print(reply.stats.decode_tps, reply.stop_reason)
```

The handler is called with `"prefill"` (and `a` of `b` tokens read),
`"reasoning"`, `"token"` and `"reasoning_done"`. Return `true` from it to stop
the answer; the reply is then whatever had arrived, with a `stop_reason` of
`"interrupted"`.

Anything that can fail returns `nil, message` rather than raising, so a chat
loop can print the problem and carry on. Handles are garbage-collected, and
`:close()` releases the 15 GiB now rather than eventually.

## Where the library is found

In order: `$JARVIS_LIB`, then `rust/target/release/libjarvis.dylib` beside this
checkout, then the debug build, then whatever the system linker resolves as
`jarvis`. The version and struct sizes are checked at load: the `cdef` here is a
hand copy of the header, and a mismatch is caught then rather than as a corrupt
struct three calls later.

## Ctrl-C

`jarvis.interrupt.install()` takes over SIGINT and sets a flag; the streaming
handler polls it between tokens and stops the turn. A signal handler cannot
safely re-enter LuaJIT, so the flag is the whole mechanism — during generation
it stops the answer, and at the prompt it is what tells an interrupted read
apart from a real end of input.

## Tests

```sh
make test-lua           # part of `make test`
make lua-test-model     # also the cases that load the real checkpoint
```

The model-backed cases skip loudly when the weights are absent or
`JARVIS_TEST_MODEL` is unset, so a green run never reads as coverage it did not
provide.
