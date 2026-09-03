# The AI agents

Twelve AI agents, and the tower has twelve floors. Each one is a GUID, a
face, and a corner of `~/.causewaybayjarvis` holding its photos, its files,
its markdown and every word it has ever been told — because here **an agent
*is* its folder**, and nothing else. **One AI agent == one folder == one
floor.** There is one kind of agent on this screen: the robot on the tower,
the name on the rail at the bottom, the head on the page and the face in
face mode are the same agent, and choosing it anywhere chooses it everywhere.

```sh
make start       # the backend: agentd as a service, on-device MLX and cloud
make gui         # just the client, no build — iterate on the Lua and rerun this
make love2d      # build + start the backend, then the client
make package     # the client as a macOS app with the backend inside, for a release
make face        # one agent, one conversation, nothing else
make test-robots # the client, and the round trip to the backend
```

Every agent answers from the same backend, which holds the same Qwen3.8-27B
on Apple MLX that `rustcli` runs. There are two ways to reach it: `agentd`,
a server on this machine over a WebSocket, or `libjarvis`, the same backend
as a library, called in this process. `make gui` connects to whatever `make
start` left running, so the Lua loop is edit, `make gui`, look. The packaged
app has the library and no server at all. A Mac without the weights answers
on-device from a local ollama daemon holding the same tag.

With no key and no weights the whole thing still runs: the roster seeds, the
archive fills, BM25 works because SQLite has FTS5, semantic search falls back
to a local embedder, and a turn answers out of the archive and says the link
is down.

## Which brain answers

`F9` — or the `AI …` chip in the footer rail — flips between three settings,
mid-conversation, any time:

| | |
| --- | --- |
| `AUTO` | on-device when this Mac can, cloud when it cannot (the default) |
| `ON-DEV` | Qwen3.8 on this machine: the MLX engine inside `libjarvis`, in this process — or, when the weights are not on disk, a local ollama daemon holding `qwen3.8:27b-mlx`. Nothing leaves it. |
| `CLOUD` | ollama.com, for when the local Mac is not powerful enough |

The chip shows the wish and — when they differ — the outcome: `AI AUTO>ON-DEV`
means auto resolved to the local engine; `AI ON-DEV>OFFLINE` means you asked
for on-device and it cannot run (no engine in this build and no daemon, or no
weights), and the turn is **refused rather than quietly sent to the cloud**.
The choice is stored in the space, so the CLI (`agentd provider`) sees the
same answer.

## The AI setup

`SET` in the header, then the `AI` tab. It is the same setup the backend
reports with `agentd config`, and it is kept in the space beside the brain
choice:

| | |
| --- | --- |
| **BRAIN** | `AUTO` / `ONDEVICE` / `CLOUD` — the same ring as `F9` |
| **THINK** | how much hidden reasoning a model may do before it answers |
| **ON-DEVICE AI** | the engine (`auto` / `mlx` / `ollama` / `off`), the daemon's host and the tag it answers with. `READY` names what is actually running; anything else is the reason, with the command that fixes it |
| **OLLAMA AI (CLOUD)** | the host, the model and the key. The key is shown only as set or not; `CLEAR` removes it |

Next to each value is where it came from — `DEFAULT`, `FROM .ENV`, `KEPT`
(written from this screen), or `FROM ENV`. A variable set in the process
environment wins over everything for that run, which is why a value that
refuses to change from here says `FROM ENV`.

Without the weights (`make model` fetches them), the on-device brain is
ready once a daemon holds the same tag:

```sh
brew install ollama            # or `make install`
ollama serve                   # the daemon, on localhost:11434
make ollama-model              # ollama pull qwen3.8:27b-mlx
```

## What is on the screen

| | |
| --- | --- |
| click an agent on the tower | choose it: the inspector opens with its folder, `FACE` and `PAGE` |
| `F2` | the **agent page** — the head, and the four shelves under it |
| `F4` | **face mode** — one agent, what it just said, and a line to type in |
| `F6` | next agent on the ring (and off the end of it, to *nobody*) |
| `F9` | which brain answers: auto, on-device, cloud |
| drop a file | file it with the chosen agent |
| `ESC` | back |

## The archive words

Five words do the archive's work, and they mean the same thing typed on the
dashboard console, typed in face mode, pressed as a chip on the command
strip, or pressed as a button on the agent page:

| | |
| --- | --- |
| `photo` | a file box narrowed to pictures. Each one picked is filed with the chosen agent — or in the global space when nobody is chosen |
| `file` | the same box for anything: a PDF, a CSV, a markdown page, a binary |
| `gallery` | the photo shelf as a grid of thumbnails. With nobody chosen it is **every agent's photos at once**, each captioned with its owner |
| `paper` | the agent's whole archive drawn as one **1024x1024 PNG** — head, name, folder, counts, the latest photos, the shelves, the last things said — into `agents/<GUID>/paper/`, and shown on the page's PAPER shelf |
| `search <words>` | BM25 and vectors, fused by rank, over the chosen agent's **own database**. With nobody chosen, over **every agent**, and each hit says who knew |
| **SEARCH ALL** | the unified search: the same engines over **every agent and the global space, whoever is chosen**. A button on face mode's menu; the box takes the input line, enter runs it, and the hits land in the transcript with their owners' names |

The file box is the operating system's (`osascript` on macOS, `zenity`
elsewhere), opened on a worker thread so the window keeps drawing while it
is up. On the page, `P`, `F`, `X`, `G` and `/` are the same five, and the
footer has a button for each. Face mode — the chat page — has a menu row
above its input with PHOTO, FILE, GALLERY, PAPER and SEARCH ALL.
`src/actions.lua` is the one place the words are read, and
`tests/test_actions.lua` holds them to it.

The model has the unified search too: `search_all` is a tool beside
`search_context` (`rust/rustagent/src/tools.rs`), read-only across every
robot, every hit naming its owner — so a robot asked about dinner can say
the galley has a note on it, without being able to touch that note.

## Every agent's folder stands on its own

```
~/.causewaybayjarvis/
  robots.db                     the global database: the roster, the settings,
                                what was filed with nobody chosen, and an index of everything
  agents/<GUID>/
    agent.db                    this agent's OWN database — the same schema, this agent only.
                                A search scoped to the agent reads this, not robots.db
    items.jsonl                 one JSON object per event, appended: add, delete, clear
    items.csv                   one row per item filed, appended, with a header
    agent.md                    the whole archive as a page, rewritten after every change
    photos/  files/  notes/     the shelves
    paper/                      the papers drawn from all of the above
  global/                       the same mirrors and shelves for nobody-chosen
```

Everything is written to SQLite and mirrored to the three plain files in the
same call; nothing is ever searched anywhere but SQLite. `agentd export
[robot]` rebuilds a folder's own database and mirrors from the global one,
and boot does the same for any folder that has fallen behind — an archive
made before the own databases existed, or a folder somebody emptied.

## One selection

There used to be two: a drone locked on the map, and a robot chosen on the
rail at the bottom, each with its own list and neither knowing about the
other — and locking a drone made the rest of the swarm disappear. Now the
tower *is* the roster: the backend's `agents.list` answers at boot, the
catalog drones stand down, and one unit per agent takes one floor per
agent, wearing that agent's own sprite untinted. Locking a unit on the map
is `Robots.select` on its GUID; picking on the rail, `F6`, or the arrow keys
in face mode lock the unit on the map. `Fleet.lock` / `Fleet.unlock` are the
two doors, `Robots.watch` is how the map hears about the others, and the
tests in `tests/test_robots.lua` hold all three to the same GUID.

Choosing one agent narrows *orders* to it — the command strip says whose —
and nothing else: the other eleven stay on the tower. `Fleet.drawList` is
every unit, whatever is locked, and is tested to be.

The map, the tower and the flight are the dashboard this client was built
from and they work as they did: `F1` layout, `F3` compact, `F8` mute, `F11`
fullscreen, `F12` screenshot, `SPACE` to rally. With no backend built there
is no roster, and the old catalog of a hundred drones fills the tower so the
screen still has somebody on it; `SETTINGS > TOWER` sets how many.

## A robot is its context

The page is four shelves and a folder path, and the folder path is the point:
what the page draws is exactly what a turn retrieves from, so *what does this
robot know* has one answer and you can look at it.

```
~/.causewaybayjarvis/
  robots.db                     every robot, every item, both indexes
  agents/<GUID>/photos/         what it has been shown
  agents/<GUID>/files/          what it has been given
  agents/<GUID>/notes/          what it wrote down
  global/…                      the same three, for when nobody is chosen
```

Every path in the database is **relative to that root**. A home directory that
moves, a backup restored somewhere else, a database copied between machines:
all keep working, and nothing in the database leaks a username.

## Nobody chosen is a real state

With no robot locked on, a turn runs in the global space and is **routed** —
and in face mode the routing happens while you are still typing. Ask about a
borrow checker and BYTE steps forward; ask what to cook and EMBER does. Press
enter and that is who answers.

Routing is deliberately not a model call: it runs on every pause in typing and
has to work with no key and no network. It is a scored keyword match over the
roster, weighted by inverse document frequency, folded past inflections — plus
a vote from each robot's **own archive**, because if the words of the question
already appear in what one robot has filed, that is stronger evidence than a
list somebody wrote before they met you. The archive vote reads filed context
only and never the transcript, so a wrong route cannot entrench itself.

`agentd route "…"` prints the decision and the words behind it.

## How it talks to the backend

Everything factual lives in [`rust/rustagent`](../rust/rustagent). This client
holds no state the backend does not: it asks.

```
robots/ (LOVE) ──one WebSocket, on a worker thread──►  agentd listen
               ──or a function call, same thread────►  libjarvis
```

`src/backend.lua` puts every request on a worker thread, and the worker
(`src/backend_worker.lua`) picks one of the two and keeps it for that space.

A daemon already answering wins: it is holding a model this window would
otherwise load again, in a process that outlives the window. Close the
window and reopen it and the brain is still warm; a fault in the engine
takes the server down and not the screen; `rustcli` and the Lua clients
share the same loaded model and the same archive. `src/wsclient.lua` is the
client side of RFC 6455 on the luasocket LÖVE ships, two hundred lines and
no TLS, since the server is on this machine, and the port comes from the
`agentd.port` file in the space.

Failing that, the library: `src/jarvis_ffi.lua` loads `libjarvis` and calls
`jarvis_agent_open` on the space, then `jarvis_agent_call` per request. No
port file, no twenty seconds of waiting for a server to come up, nothing
left running afterwards — which is what makes the packaged app one thing to
install and one thing to quit. The model is loaded into this process and
dies with it, which is the whole cost of the arrangement. Only when there is
no library either does the worker start a daemon of its own, and it stops
that one on the way out.

Either way the reply is the same JSON envelope from the same dispatch in
Rust, so nothing above the worker knows which way it came.

A turn is watched as it is written: `Backend.call` takes an `onChunk` and
gets `token`, `tool` and `prefill` pieces on the frames they arrive on, with
the whole turn still landing once at the end. Over a socket each is a frame
carrying the request's id; through the library each is a callback fired on
the worker thread as the model writes. `tests/test_agentd.lua` runs the
whole chain against a real server on a scratch space, and
`tests/test_libjarvis.lua` runs it again through the library — including
that no daemon was started at all.

`make stop` is the hand-brake for a server a crash orphaned, and `make
start` runs one as a service under supervisord. Either way there is one
server per space: a second `agentd listen` against a server that still
answers fails rather than taking another port.

## The files

| file | what it holds |
| --- | --- |
| `src/wsclient.lua` | a WebSocket client on luasocket: the handshake, masked frames out, frames in |
| `src/agents.lua` | the agents on the tower: the roster once the backend answers (`Agents.fromRoster`), the catalog of bodies until then |
| `src/fleet.lua` | the units on the floors, one per agent, and the one selection (`Fleet.lock`) |
| `src/backend.lua` | the bridge: requests out, replies in, timeouts |
| `src/backend_worker.lua` | the thread that holds the WebSocket to `agentd`, and starts it when there is none |
| `src/robots.lua` | the roster as this client holds it: selection, the ring, colours |
| `src/agentpage.lua` | the robot page — geometry is pure arithmetic, so it is tested headlessly |
| `src/face.lua` | face mode |
| `src/converse.lua` | one turn, and the receipt under the answer |
| `src/photos.lua` | pictures from outside the LOVE sandbox, cached and capped |
| `src/actions.lua` | the five archive words — photo, file, gallery, paper, search — wherever they are typed or pressed |
| `src/picker.lua` | the operating system's file box, on a worker thread (`src/picker_worker.lua`) |
| `src/sprites.lua` | the sprite sheets, and the measured head crop both screens frame on |

The rest — `dashboard`, `world`, `boot`, `chat`, `tools`, `autopilot` — is
the swarm dashboard this client was built from; it now draws the roster.

## Testing

`make test-robots` runs the suite inside LÖVE, because half of what it checks
is the bridge and the only honest way to test that is to run one. The
daemon-facing suite opens a scratch space, seeds a roster, files a real PNG,
searches for it three ways, checks the agent's folder carries its own
database and all three mirrors, searches every agent at once with nobody
chosen, lists the gallery by folder, draws a paper and reads its PNG header
and its shelf back, rebuilds the folder with `export`, holds a turn and
reads the page back — and skips itself, rather than failing, when `agentd`
has not been built. `JARVIS_TEST_KEEP=1` leaves the scratch space and its
`agentd.log` behind.

`make robots-shots` walks the client through every screen and photographs each
one — the page, the gallery grid, a search, a paper, the face, the setup —
which is how a change to any of them is checked.

## The key

`.env` beside this file, or the environment — or the `AI` tab, which is kept
in the space and beats the file:

```sh
ONDEVICE_ENGINE=auto          # auto | mlx | ollama | off
ONDEVICE_HOST=http://localhost:11434
ONDEVICE_MODEL=qwen3.8:27b-mlx
OLLAMA_API_KEY=...            # ollama.com. The daemon needs none.
OLLAMA_HOST=https://ollama.com
OLLAMA_MODEL=gpt-oss:20b
OLLAMA_EMBED=embeddinggemma
```

The boot report says out loud whether prompts leave the machine, because that
is not a detail.
