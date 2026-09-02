# The Lua client

A chat client for [Causewaybay Jarvis](../README.md) written in Lua. A
conversation goes to the server: `chat` and `run` reach `agentd` — the one
process that holds the model — over HTTP through `curl`, and read the
answer back as server-sent events (`jarvis/client.lua`). The client loads
no weights and needs no library built; it starts the server itself when
none is running.

```sh
make agentd                    # build the server once (make agentd-mlx for the engine)
luajit lua/chat.lua            # the chat REPL
luajit lua/chat.lua run "why is the sky blue?"
make lua-chat                  # the REPL, with the server built
```

The model-management commands — `pull`, `info`, `models`, `bench` — drive
the engine in this process through `libjarvis`, the C ABI that
[`rust/rustffi`](../rust/rustffi) exports, and need `make ffi` first.

LuaJIT, not Lua: the terminal layer and the binding are `ffi.cdef`, which
plain Lua has no equivalent for. `brew install luajit`.

## Layout

| file | what it holds |
| --- | --- |
| `jarvis/client.lua` | the network client: finding or starting the server, one op over HTTP, a turn over SSE, and the conversation a session keeps |
| `jarvis/ffi.lua` | the `cdef`, a copy of `rust/rustffi/include/jarvis.h`, plus finding and version-checking the library (model management only) |
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

The handler must not call back into the session it was fired for — `send` holds
that session for the whole turn, so `session:cached_tokens()` from inside one is
refused with an error rather than allowed to corrupt it, and so is
`session:close()`. Everything else is fair game, including `jarvis.memory()` and
the interrupt flag.

Anything that can fail returns `nil, message` rather than raising, so a chat
loop can print the problem and carry on. Handles are garbage-collected, and
`:close()` releases the 15 GiB now rather than eventually. A handle that has
been closed is refused by every later call — the library hands out tokens
rather than addresses, so a stale one can never come to mean a live session.

JSON `null` decodes to `nil`, which is what an absent field means here. Inside
an array it decodes to `jarvis.json.null` instead, so that the elements after it
keep their positions.

## Where the library is found

In order: `$JARVIS_LIB`, then `rust/target/release/libjarvis.dylib` beside this
checkout, then the debug build, then whatever the system linker resolves as
`jarvis`. The version and struct sizes are checked at load: the `cdef` here is a
hand copy of the header, and a mismatch is caught then rather than as a corrupt
struct three calls later.

## Stopping a turn

A turn is a `curl` on a pipe. In the TUI, Escape or Ctrl-C between pieces
closes the pipe: `curl` goes, the server sees its socket close, and the
generation stops there — the terminal is opened with signals off, so Ctrl-C
is a key the client reads rather than a signal that would leave the shell
raw. In the REPL, Ctrl-C ends the program the way it ends any command, and
the server stops the turn for the same reason.

`jarvis.interrupt` still exists for the model session (`bench`): it takes
over SIGINT and sets a flag the engine's callback polls between tokens.

## Tests

```sh
make test-lua           # part of `make test`
make lua-test-model     # also the cases that load the real checkpoint
```

The model-backed cases skip loudly when the weights are absent or
`JARVIS_TEST_MODEL` is unset, so a green run never reads as coverage it did not
provide.
