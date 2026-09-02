# `rustagent` — the AI-agent robot system

One SQLite file and one folder per robot, in `~/.causewaybayjarvis`. BM25 and
vector retrieval over it. A tool harness the model acts through. And the
ollama.com calls that drive a turn.

```sh
make agentd                                # build it (lean: no Xcode, no GPU)
make agentd-mlx                            # the same, carrying the on-device engine
agentd listen                              # the daemon: TCP on 127.0.0.1, port in agentd.port
agentd health                              # is there a model, and where does it run
agentd provider                            # which brain answers, and why
agentd provider.set ondevice               # auto | ondevice | cloud — persists in the space
agentd config                              # the AI setup, and where each value came from
agentd config.set ondevice.model qwen3.8:27b-mlx   # change one (a key alone clears it)
agentd agents.list
agentd add ~/photo.png --agent food        # file something with a robot
agentd search "pork belly" --mode bm25     # bm25 | semantic | hybrid  [--all]
agentd route "why won't this borrow?"      # which robot would answer, and why
agentd chat --agent coding "..."           # one turn
agentd serve                               # a JSON request per line, on stdin
```

## The shape

```
robots/ (LOVE)  ──jsonl──►  agentd  ──►  Backend
                                          ├─ store    sqlite + the folder, in step
                                          ├─ router   which robot answers
                                          ├─ search   BM25 + vectors, fused
                                          ├─ tools    what the model may call
                                          ├─ harness  one turn, end to end
                                          └─ ollama   ollama.com or a daemon
```

## An agent is its context

There is no separate notion of *the agent* and *the agent's stuff*. A robot is
a GUID, a persona, and everything filed under it — so one table, `items`, holds
photos, files, markdown, notes **and the conversation**, and `agent_id` is what
says whose they are. `NULL` there is the global space, which is where a turn
lands when no robot has been chosen.

Both indexes read those same rows. `items_fts` is an FTS5 index kept in step by
triggers, and BM25 comes straight out of it; `embeddings` hangs off the same
rowid. Neither owns a copy of the text, so they cannot drift from it or from
each other.

Every stored path is relative to the space root — `agents/<GUID>/photos/…`,
never `/Users/…`.

## Two searches, and why they are fused by rank

**BM25** finds the rows that use the words you typed: exact, rare words
weighted heavily, long documents discounted. It needs no model and never has.

**Semantic** is brute-force cosine over embeddings — the row that means the
same thing in other words. Exact, because a personal archive is thousands of
rows and an exact scan has no index to go stale.

**Hybrid** is Reciprocal Rank Fusion: each engine votes `1/(60 + rank)` and the
votes are added. RRF rather than a weighted sum, because a BM25 score and a
cosine are not on the same scale and never will be — one is unbounded and
corpus-relative, the other is in `[-1, 1]`. Ranks are comparable; the numbers
behind them are not.

## Embeddings, and the fallback that is not optional

ollama.com has no embedding models at all — `/api/embed` answers `unauthorized`
for every key. A cloud-only setup would therefore have *no* semantic search,
and the hybrid half of every query would silently vanish. So the real embedder
sits behind [`embed::Fallback`], and a local hashing embedder takes over on the
first failure.

That is why the model name is part of the `embeddings` primary key: two
embedders are two unrelated geometries, and a cosine between them is noise.
`search::semantic` only ever compares vectors written by the embedder that is
running, and `reindex` only ever fills in what *that* embedder is missing.

## Layout

| file | what it holds |
| --- | --- |
| `space.rs` | `~/.causewaybayjarvis`: the shelves, the GUIDs, and the one door between a stored string and the filesystem |
| `db.rs` | the schema, the FTS5 triggers, and the query cleaner that keeps punctuation away from the parser |
| `agent.rs` | a robot, and the shipped roster of twelve |
| `context.rs` | one row of what a robot knows |
| `store.rs` | the database and the folder, kept in step |
| `search.rs` | BM25, cosine, RRF, and the archive vote the router uses |
| `embed.rs` | the embedder trait, the hashing one, and the fallback |
| `router.rs` | which robot answers, and why |
| `tools.rs` | the functions the model may call |
| `harness.rs` | route → retrieve → call → tool → remember |
| `ollama.rs` | ollama.com or a local daemon, the daemon probe, and where the prompts go |
| `setup.rs` | the AI setup: every value, its source, and the two client configs it becomes |
| `provider.rs` | the brain choice, and the outcome it resolves to |
| `proto.rs` | one JSON object in, one out |

## Two brains, one harness

The model sits behind the `Brain` trait, so the harness — route, retrieve,
tool loop, remember — is identical whichever answers:

* **on-device**: two engines, one word. With `--features mlx` it is the same
  Qwen3.8-27B on Apple MLX that `rustcli` runs, loaded lazily on the first
  local turn and held for the life of the daemon; tool calls use the
  checkpoint's own template format (`<function=…>` blocks), parsed by
  `ondevice::parse_tool_calls` — which compiles and is tested on machines
  with no Metal at all. Without it — the lean `make agentd` build — it is a
  **local ollama daemon** at `ONDEVICE_HOST` holding `ONDEVICE_MODEL`
  (`qwen3.8:27b-mlx` by default, the same tag). `proto::pick_engine` decides:
  `auto` tries MLX and then the daemon, `mlx` / `ollama` insist on one, `off`
  rules both out. The daemon is probed (`/api/tags`, three seconds) and the
  answer cached for ten, so a health check never waits on a generation.
* **cloud**: ollama.com, or any host that is not this machine.

`provider` decides which: `auto` (on-device when either engine can, cloud
otherwise), or an explicit `ondevice` / `cloud` — and an explicit choice that
cannot run is refused with the reason, never silently substituted. The setting
lives in the `settings` table, so the GUI's `F9` and the CLI see the same
state. `JARVIS_NO_MLX=1` keeps an mlx build off the engine; the hermetic
tests set it — with `ONDEVICE_ENGINE=off`, so a daemon that happens to be
running stays out of the picture too.

## The setup

[`setup.rs`](src/setup.rs) resolves every AI value — engine, daemon host and
tag, cloud host, model and key, think level — from three places, first
non-empty answer wins: the **process environment**, then the **`settings`
table** in the space, then **`.env`**, then the default. The space is what
the client's `SETTINGS > AI` tab and `config.set` write, so a choice made on
the screen survives a restart and the CLI sees it; the environment beats it
so a one-off `ONDEVICE_MODEL=… agentd chat …` does what it says. `config`
reports each value with its source, and a secret only as set or not.
`config.set` validates, writes, and rebuilds the clients in place — the
running daemon follows the setup screen without a restart.

## The server

`agentd listen` binds 127.0.0.1, writes the port to `<space>/agentd.port`, and
serves any number of connections through one dispatcher thread that owns the
backend — the same single-file discipline every MLX client in this workspace
keeps. On that one port it speaks three ways, sniffed from a connection's
first bytes (`server.rs`):

* a **WebSocket** at `/ws` — the LÖVE client and `rustcli`. Text frames of
  JSON with an `id` the client chooses; a turn streams as `chunk` frames
  (`token`, `reasoning`, `tool`, `prefill`) and then the reply under that
  id; `{"op":"stop","id":…}` cancels a turn mid-generation.
* **HTTP** — `POST /v1/<op>`, and `/v1/chat/stream` as server-sent events
  (`http.rs`): the Lua CLI and TUI through `curl`, a browser, a script.
* **line JSON** over plain TCP, for `nc` and the daemon tests.

`daemon.stop` (the op) shuts it down and removes the port file, after its
reply is on the wire; a chat *about* daemon.stop does not, which is tested.
`serve` speaks the line protocol on stdin for one-shots and pipes.
`tests/server.rs` drives all three transports over real sockets.

## Testing

```sh
make test-agent
```

Seventy-two tests, none of which touch the network or the GPU — the daemon
suite runs the real binary over a real socket against a scratch space with
both brains deliberately shut, and the harness suite drives the whole
pipeline with a scripted model, so *what the turn did* is what is asserted
rather than what a model happened to say. The same suite passes with and
without `--features mlx`.
