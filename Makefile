# Causewaybay Jarvis — an on-device AI agent in Rust on Apple MLX.
#
#   make download   install the build dependencies and the Metal toolchain
#   make setup      check the toolchain, and the on-device AI setup
#   make model      download the weights (~15 GiB, once)
#   make ollama-model  pull the same model into a local ollama daemon
#   make chat       talk to it (rustcli, over the server)
#   make luatui     the same, full-screen, in Lua (over the server)
#   make start      the backend as a service (agentd: on-device MLX, cloud on F9)
#   make gui        just the LÖVE client — the Lua iteration loop
#   make love2d     build + start the backend, then the client
#   make package    the release: the app, with the backend inside it
#   make face       one robot, one conversation
#   make start      the robot backend as a service, under Python's supervisord
#   make stop       ...and down again
#   make api        the same backend over HTTP: REST, and turns that stream
#   make web        the web client — every agent, every shelf — in the browser
#                   (make start BIND=0.0.0.0 to open it to a phone on the Wi-Fi)
#   make test       everything
#   make clear      throw away runtime scratch (clean = build output)
#
# Building `rustmlx` compiles MLX from source, which needs Apple's Metal
# compiler. That lives inside Xcode, not the Command Line Tools, so every
# cargo invocation below runs with DEVELOPER_DIR pointed at it.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Where this Makefile lives, absolute.
#
# Not `$(CURDIR)`: that is the directory make was *started* in, which is the
# repository root only when somebody happened to be standing there. Run
# `make -f /path/to/Makefile robots` from anywhere else and every relative
# path below resolves against the wrong place — LÖVE is handed a `robots`
# that is not there, and the error it prints names a directory nobody wrote.
# `MAKEFILE_LIST` names this file, so this is the one anchor that cannot
# drift.
ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

XCODE ?= /Applications/Xcode.app/Contents/Developer
CARGO := DEVELOPER_DIR=$(XCODE) cargo
# The Rust workspace lives under rust/; cargo is pointed at it rather than
# run from inside it, so a recipe's working directory is never the one the
# build cares about. Everything is addressed from $(ROOT) instead, and the
# recipes that run a tool which looks things up in the current directory —
# `config.jsonl`, `tools/` — step into $(ROOT) first.
MANIFEST := --manifest-path $(ROOT)/rust/Cargo.toml
# `rustagent` is the one crate that does not touch MLX, so it builds — and
# tests — on a machine with no Xcode and no GPU. Keep it off the DEVELOPER_DIR
# path so that stays true.
CARGO_PLAIN := cargo
BIN := $(ROOT)/rust/target/release
# MLX drives one GPU queue, so tests that touch it must not run concurrently.
TEST_FLAGS := -- --test-threads=1

MODEL ?= qwen3.8:27b-mlx
# The on-device brain for a build without MLX: a local ollama daemon holding
# the same tag. `make setup` reports it, `make ollama-model` pulls it.
OLLAMA ?= ollama
OLLAMA_MODEL ?= $(MODEL)
OLLAMA_EMBED ?= embeddinggemma
ONDEVICE_HOST ?= http://localhost:11434
PYTHON ?= python3
BREW ?= brew
# `make start` runs the robot backend under Python's supervisord: a fixed
# port, a log with rotation, a restart when it crashes, and a `status`.
# `pip install supervisor` (or `make install`) puts both commands on PATH.
SUPERVISORD ?= supervisord
SUPERVISORCTL ?= supervisorctl
SUPERVISOR_CONF := $(ROOT)/tools/supervisord.conf
AGENT_PORT ?= 47421
# The HTTP backend's port — `make api`, and `rustcli backend --port`.
API_PORT ?= 8808
# The interface the backend binds. `127.0.0.1` is this Mac only; `make start
# BIND=0.0.0.0` opens the web client to the Wi-Fi, for a phone or a tablet —
# there is no login on it, so that is a choice and not the default.
BIND ?= 127.0.0.1
# The Lua client talks to the workspace through `libjarvis`, the cdylib that
# `rustffi` builds. LuaJIT rather than Lua: the bindings are `ffi.cdef`, which
# only LuaJIT has.
LUA ?= luajit
# The LÖVE client. LÖVE 11 embeds LuaJIT, so the same `ffi` bindings the CLI
# client uses load inside it — on a worker thread, because generating blocks.
#
# `love` on PATH when something put it there, and the binary inside the bundle
# otherwise: the Homebrew cask that used to make that symlink was disabled on
# 2026-09-01, so `make install-love` installs the app and nothing else.
LOVE ?= $(shell command -v love 2>/dev/null || echo /Applications/love.app/Contents/MacOS/love)
AGENTD := $(BIN)/agentd
# The robot swarm client. A second LOVE app beside `love/`: same workspace,
# same `~/.causewaybayjarvis`, different job — one is the model behind a face,
# the other is the agents and everything they know.
ROBOTS := $(ROOT)/robots
LIBNAME := libjarvis.dylib
LIB := $(BIN)/$(LIBNAME)
# The engine-carrying copy. See `ffi-mlx`.
LIB_MLX := $(BIN)/libjarvis-mlx.dylib
LIB_DEBUG := $(ROOT)/rust/target/debug/$(LIBNAME)
REFERENCE := $(ROOT)/tools/reference.json
# Runtime scratch, per the `paths` key in config.jsonl. `make clear` empties it.
DATA := $(ROOT)/data

BOLD := \033[1m
DIM := \033[2m
OFF := \033[0m

## ----------------------------------------------------------------- help ----

.PHONY: help
help: ## list the targets
	@echo -e "$(BOLD)Causewaybay Jarvis$(OFF)"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

## -------------------------------------------------------------- install ----

.PHONY: download
download: install metalframework ## everything a fresh machine needs before `make setup`

.PHONY: install
# ffmpeg and ffmpeg2theora are the video pair: ffmpeg decodes whatever a
# phone records, ffmpeg2theora writes the Ogg Theora clip LÖVE plays
# (Homebrew's ffmpeg no longer links libtheora itself). Without them a
# video is still filed; it just has no clip on the VIDEO shelf.
install: ## install the build dependencies with Homebrew (cmake, luajit, love, ollama, ffmpeg, ffmpeg2theora)
	@command -v $(BREW) >/dev/null || { echo "brew not found — install Homebrew from https://brew.sh"; exit 1; }
	@command -v cargo >/dev/null || { echo "cargo not found — install Rust from https://rustup.rs"; exit 1; }
	@for f in cmake luajit ollama ffmpeg ffmpeg2theora; do \
		if $(BREW) list --formula $$f >/dev/null 2>&1; then \
			echo "$$f already installed"; \
		else \
			$(BREW) install $$f; \
		fi; \
	done
	@if $(BREW) list --cask love >/dev/null 2>&1 || command -v $(LOVE) >/dev/null || [ -d /Applications/love.app ]; then \
		echo "love already installed"; \
	else \
		$(ROOT)/tools/get-love.sh /Applications; \
	fi
	@if command -v $(SUPERVISORD) >/dev/null; then \
		echo "supervisor already installed"; \
	else \
		$(PYTHON) -m pip install supervisor; \
	fi

.PHONY: install-love
# Homebrew disabled the `love` cask on 2026-09-01 — the bundle upstream ships
# does not pass Gatekeeper, so brew refuses to hand it over. `make package-app`
# does not run that bundle, it copies it and signs the result, so this fetches
# the release directly and checks it against a pinned hash.
install-love: ## install love.app from the upstream release (the cask is gone)
	@$(ROOT)/tools/get-love.sh /Applications

.PHONY: metalframework
# Since Xcode 16.3 the Metal compiler is a separate download rather than part
# of Xcode itself, and MLX cannot build its shaders without it. This is the
# fetch `make setup` tells you to run when it finds the toolchain missing.
metalframework: ## download Apple's Metal toolchain, the compiler MLX builds shaders with
	@test -d "$(XCODE)" || { \
		echo "Xcode not found at $(XCODE)."; \
		echo "Install Xcode, or point make at it: make XCODE=/path/to/Xcode.app/Contents/Developer"; \
		exit 1; }
	@if DEVELOPER_DIR=$(XCODE) xcrun --find metal >/dev/null 2>&1; then \
		echo "metal toolchain already installed"; \
	else \
		DEVELOPER_DIR=$(XCODE) xcodebuild -downloadComponent MetalToolchain; \
	fi

## ---------------------------------------------------------------- setup ----

.PHONY: setup
setup: ## check that everything needed to build is installed
	@command -v cargo >/dev/null || { echo "cargo not found — install Rust from https://rustup.rs"; exit 1; }
	@echo "rust      $$(rustc --version)"
	@test -d "$(XCODE)" || { \
		echo "Xcode not found at $(XCODE)."; \
		echo "MLX needs the Metal compiler, which the Command Line Tools do not ship."; \
		echo "Install Xcode, or point make at it: make XCODE=/path/to/Xcode.app/Contents/Developer"; \
		exit 1; }
	@DEVELOPER_DIR=$(XCODE) xcrun --find metal >/dev/null 2>&1 || { \
		echo "the Metal toolchain is missing — run: DEVELOPER_DIR=$(XCODE) xcodebuild -downloadComponent MetalToolchain"; \
		exit 1; }
	@echo "metal     $$(DEVELOPER_DIR=$(XCODE) xcrun -sdk macosx metal --version 2>&1 | head -1)"
	@echo "cmake     $$(cmake --version 2>/dev/null | head -1 || echo 'not found — brew install cmake')"
	@if [ -n "$$HF_TOKEN" ]; then echo "HF_TOKEN  set"; else echo -e "HF_TOKEN  $(DIM)unset (fine for public repos)$(OFF)"; fi
	@$(MAKE) --no-print-directory setup-ai

.PHONY: setup-ai
# The two brains the robot backend can use, checked without building it: is
# there an ollama daemon on this machine, does it hold the model, and is
# there a key for the cloud. `make setup` fails only on the toolchain; a
# missing daemon is reported with the command that fixes it, because the lean
# build runs without one.
setup-ai: ## the on-device and cloud AI setup: ollama daemon, model, cloud key
	@echo
	@echo -e "$(BOLD)on-device AI$(OFF)  (MLX when built with \`make gui\`, else a local ollama daemon)"
	@if command -v $(OLLAMA) >/dev/null; then \
		echo "ollama    $$($(OLLAMA) --version 2>/dev/null | head -1)"; \
	else \
		echo -e "ollama    $(DIM)not installed — brew install ollama (or make install)$(OFF)"; \
	fi
	@tags=$$(curl -s -m 3 "$(ONDEVICE_HOST)/api/tags" 2>/dev/null); \
	if [ -z "$$tags" ]; then \
		echo -e "daemon    $(DIM)nothing at $(ONDEVICE_HOST) — run: ollama serve$(OFF)"; \
	else \
		echo "daemon    $(ONDEVICE_HOST)"; \
		if echo "$$tags" | grep -q "\"name\":\"$(OLLAMA_MODEL)\""; then \
			echo "model     $(OLLAMA_MODEL)  pulled"; \
		else \
			echo -e "model     $(DIM)$(OLLAMA_MODEL) not pulled — run: make ollama-model$(OFF)"; \
		fi; \
		if echo "$$tags" | grep -q "\"name\":\"$(OLLAMA_EMBED)"; then \
			echo "embed     $(OLLAMA_EMBED)  pulled (real vectors for semantic search)"; \
		else \
			echo -e "embed     $(DIM)$(OLLAMA_EMBED) not pulled — optional: ollama pull $(OLLAMA_EMBED)$(OFF)"; \
		fi; \
	fi
	@echo -e "$(BOLD)cloud AI$(OFF)  (ollama.com)"
	@key="$${OLLAMA_API_KEY:-$$(sed -n 's/^OLLAMA_API_KEY=//p' $(ROBOTS)/.env 2>/dev/null | head -1)}"; \
	if [ -n "$$key" ]; then echo "key       set"; else echo -e "key       $(DIM)unset — copy $(ROBOTS)/.env.example to $(ROBOTS)/.env$(OFF)"; fi
	@echo -e "$(DIM)every value can be changed on the client's SETTINGS > AI tab, or: agentd config.set <key> <value>$(OFF)"

## ---------------------------------------------------------------- build ----

.PHONY: build
build: ## debug build of the whole workspace
	$(CARGO) build $(MANIFEST) --workspace

.PHONY: release
release: ## optimised build (use this one)
	$(CARGO) build $(MANIFEST) --release --workspace

.PHONY: ffi
# libjarvis carries the on-device engine for the robots as well as the model
# session: the `mlx` feature is on by default in rustffi, because the library
# links MLX outright and so needs Xcode either way. This is what makes the
# robot client's backend in-process *and* on-device — the model is loaded
# into the client's own address space, through this binding, rather than
# into a daemon's.
ffi: ## build libjarvis, the C ABI the Lua clients load — with the on-device MLX engine in it
	$(CARGO) build $(MANIFEST) --release -p rustffi
	@echo "$(LIB)  (with the MLX engine)"

.PHONY: ffi-mlx
# The same library under its old second name. The copy used to be the only
# engine-carrying one; now every `make ffi` carries it, and this exists so
# a client that still looks for `libjarvis-mlx` first finds the same build
# rather than a stale one. Copied and renamed into place rather than written
# over, because a client may still have the old inode open.
ffi-mlx: ffi ## the same library, also under the libjarvis-mlx name
	@cp $(LIB) $(LIB_MLX).tmp && mv -f $(LIB_MLX).tmp $(LIB_MLX)
	@echo "$(LIB_MLX)  (the same library)"

.PHONY: ffi-debug
ffi-debug: ## the same library, unoptimised — what `make test-lua` links against
	$(CARGO) build $(MANIFEST) -p rustffi

.PHONY: check
check: ## type-check without producing binaries
	$(CARGO) check $(MANIFEST) --workspace --all-targets

.PHONY: fmt
fmt: ## format the source
	cargo fmt $(MANIFEST) --all

.PHONY: fmt-check
fmt-check: ## fail if the source is not formatted
	cargo fmt $(MANIFEST) --all -- --check

.PHONY: lint
lint: ## clippy, warnings are errors
	$(CARGO) clippy $(MANIFEST) --workspace --all-targets -- -D warnings

## ---------------------------------------------------------------- model ----

.PHONY: model
model: release ## download the weights into the Hugging Face cache (~15 GiB)
	cd $(ROOT) && $(BIN)/rustcli --model $(MODEL) pull

.PHONY: ollama-model
ollama-model: ## pull the on-device model into the local ollama daemon (for `make robots`)
	@command -v $(OLLAMA) >/dev/null || { echo "ollama not found — brew install ollama (or make install)"; exit 1; }
	$(OLLAMA) pull $(OLLAMA_MODEL)

.PHONY: info
info: release ## what is configured and what is on disk
	cd $(ROOT) && $(BIN)/rustcli --model $(MODEL) info

.PHONY: models
models: release ## list the model aliases this build knows
	cd $(ROOT) && $(BIN)/rustcli models

## ------------------------------------------------------------------ run ----

.PHONY: chat
chat: release ## interactive chat in the terminal
	cd $(ROOT) && $(BIN)/rustcli --model $(MODEL) chat

.PHONY: tui
tui: release ## full-screen chat
	cd $(ROOT) && $(BIN)/rusttui --model $(MODEL)

.PHONY: ask
ask: release ## one-shot: make ask Q="why is the sky blue?"
	@test -n "$(Q)" || { echo 'set Q, e.g. make ask Q="why is the sky blue?"'; exit 1; }
	cd $(ROOT) && $(BIN)/rustcli --model $(MODEL) run "$(Q)"

.PHONY: lua-chat
lua-chat: agentd-mlx ## interactive chat through the Lua client, over the server
	cd $(ROOT) && $(LUA) $(ROOT)/lua/chat.lua chat

.PHONY: luatui
# The Lua half of the pair: `lua/chat.lua` is the CLI, this is the TUI.
# Both talk to the server — HTTP and server-sent events through `curl` —
# so they need LuaJIT and nothing built but `agentd`: the same panes and
# the same keys as `make tui`, with none of the same code.
luatui: agentd-mlx ## full-screen chat through the Lua client (the Lua `make tui`), over the server
	@command -v $(LUA) >/dev/null || { echo "$(LUA) not found - brew install luajit"; exit 1; }
	cd $(ROOT) && $(LUA) $(ROOT)/lua/tui.lua

.PHONY: lua-ask
lua-ask: agentd-mlx ## one-shot through Lua: make lua-ask Q="why is the sky blue?"
	@test -n "$(Q)" || { echo 'set Q, e.g. make lua-ask Q="why is the sky blue?"'; exit 1; }
	cd $(ROOT) && $(LUA) $(ROOT)/lua/chat.lua run "$(Q)"

.PHONY: knight
knight: ffi ## the original LOVE chat client: the knight, on libjarvis
	@command -v $(LOVE) >/dev/null || { echo "love not found - run make install-love"; exit 1; }
	cd $(ROOT) && JARVIS_LIB=$(LIB) $(LOVE) $(ROOT)/love --model $(MODEL)

.PHONY: knight-demo
knight-demo: ## the knight against a recorded model, so it needs no weights
	@command -v $(LOVE) >/dev/null || { echo "love not found - run make install-love"; exit 1; }
	cd $(ROOT) && $(LOVE) $(ROOT)/love --demo

# The old names still answer; the combined client took `gui` over.
.PHONY: gui-demo
gui-demo: knight-demo

.PHONY: art
art: ## paint the backgrounds with Grok (needs XAI_API_KEY)
	cd $(ROOT) && $(ROOT)/tools/grokart.sh

.PHONY: shots
shots: ## drive the client from a script and photograph every screen
	@command -v $(LOVE) >/dev/null || { echo "love not found - run make install-love"; exit 1; }
	cd $(ROOT) && $(LOVE) $(ROOT)/love --demo --shots

.PHONY: bench
bench: release ## measure prefill and decode throughput
	cd $(ROOT) && $(BIN)/rustcli --model $(MODEL) bench --prompt 512 --tokens 128

## --------------------------------------------------------------- robots ----
#
# The AI-agent robot system. `agentd` owns ~/.causewaybayjarvis — one SQLite
# file, one folder per robot — and the LOVE client in robots/ is its face.
# Neither needs the weights, Xcode or a GPU, so this half of the project runs
# on any machine — and with `ollama serve` holding $(OLLAMA_MODEL) it still
# has an on-device brain.

.PHONY: agentd
agentd: ## build the robot backend (no MLX, no Xcode, no GPU)
	$(CARGO_PLAIN) build $(MANIFEST) --release -p rustagent
	@echo "$(AGENTD)"

.PHONY: agentd-mlx
# Copied to its own name, because cargo writes both variants to the same file
# and a lean rebuild would otherwise quietly strip the engine out from under a
# `make gui`. Everything that runs the backend prefers `agentd-mlx` when it
# exists; the health report and the AI chip tell the truth either way.
# Copied to a new name and renamed into place, never written over the old
# file: a daemon from the last session may still be running that inode, and
# macOS answers an in-place overwrite of a running Mach-O by killing every
# later exec of it with signal 9 — the client then waits for a daemon that
# dies at launch and reports a timeout.
agentd-mlx: ## the same backend carrying the on-device engine (needs Xcode)
	$(CARGO) build $(MANIFEST) --release -p rustagent --features mlx
	@cd $(ROOT) && cp $(AGENTD) $(BIN)/agentd-mlx.tmp && mv -f $(BIN)/agentd-mlx.tmp $(BIN)/agentd-mlx
	@cd $(ROOT) && echo "$(BIN)/agentd-mlx  (with the MLX engine)"

# The engine-carrying binary when there is one, the lean one otherwise.
AGENTD_BEST = $$([ -x $(BIN)/agentd-mlx ] && echo $(BIN)/agentd-mlx || echo $(AGENTD))

# The space the backend owns, and the environment `tools/supervisord.conf`
# is filled in from. One shell word each, evaluated in the recipe.
JARVIS_HOME_DIR = $${JARVIS_HOME:-$$HOME/.causewaybayjarvis}
# supervisord's control socket lives in the space — unless the space's path is
# too long for a UNIX socket (104 bytes on macOS), when it moves to /tmp under
# a name derived from that path, so two spaces still never share one.
JARVIS_SOCK = $$(sock="$(JARVIS_HOME_DIR)/supervisord.sock"; \
	if [ $${\#sock} -gt 100 ]; then echo "/tmp/jarvis-$$(printf %s "$$sock" | cksum | cut -d' ' -f1).sock"; else echo "$$sock"; fi)
# Every variable after the `cd`, not before it: an assignment in front of a
# shell builtin lasts for that builtin alone, so the three in front of `cd`
# never reached supervisord and it refused the config for naming them.
SUPERVISE = cd $(ROOT) && JARVIS_HOME="$(JARVIS_HOME_DIR)" JARVIS_ROOT="$(ROOT)" JARVIS_SOCK="$(JARVIS_SOCK)" \
	JARVIS_AGENTD="$(AGENTD_BEST)" JARVIS_AGENT_PORT="$(AGENT_PORT)" JARVIS_BIND="$(BIND)"
CTL = $(SUPERVISE) $(SUPERVISORCTL) -c $(SUPERVISOR_CONF)

.PHONY: start
# Always a fresh process. The binary was just rebuilt, and a server that
# kept running through that would be serving the code from before the
# change: so whatever is running is stopped first — `make stop`, the same
# one you would type — and only then is supervisord brought up. That covers
# a supervised server, one a client started on its own, and an orphan that
# lost its pid file but still holds the port.
# The daemon itself refuses to run twice — a second `listen` on a port
# anything else holds exits at once — and supervisord does not retry it, so
# a clash shows up here as FATAL with the daemon's own sentence, never as a
# silent second copy.
start: agentd-mlx ## start the backend: agentd as a service under supervisord — any previous server is stopped first (AGENT_PORT=47421, BIND=127.0.0.1)
	@command -v $(SUPERVISORD) >/dev/null || { echo "supervisord not found — pip install supervisor (or make install)"; exit 1; }
	@$(MAKE) --no-print-directory stop
	@home="$(JARVIS_HOME_DIR)"; mkdir -p "$$home"; \
	echo "agentd    $(AGENTD_BEST)"; \
	echo "space     $$home"; \
	echo "port      $(AGENT_PORT)"; \
	echo "bind      $(BIND)"; \
	$(SUPERVISE) $(SUPERVISORD) -c $(SUPERVISOR_CONF) || exit 1; \
	for i in $$(seq 1 40); do \
		state=$$($(CTL) status agentd 2>/dev/null | awk '{print $$2}'); \
		case "$$state" in RUNNING|FATAL|EXITED) break;; esac; \
		sleep 0.25; \
	done; \
	$(CTL) status agentd; \
	if [ "$$state" = RUNNING ]; then \
		port=$$(cat "$$home/agentd.port" 2>/dev/null); \
		echo -e "$(BOLD)agentd listening on $(BIND):$${port:-$(AGENT_PORT)}$(OFF)  (pid $$(cat "$$home/agentd.pid" 2>/dev/null), log $$home/agentd.log)"; \
		echo -e "web       $(BOLD)http://127.0.0.1:$${port:-$(AGENT_PORT)}/$(OFF)  (make web opens it)"; \
		grep -h "also reachable" "$$home/agentd.log" 2>/dev/null | tail -n 2 | sed 's/^ *also reachable at/phone    /'; \
	else \
		echo; echo "agentd did not come up — the last lines of $$home/agentd.log:"; \
		tail -n 5 "$$home/agentd.log" 2>/dev/null | sed 's/^/  /'; \
		exit 1; \
	fi

.PHONY: stop
# Three things can be running: the supervised service, a daemon the client
# started on its own (or that a crashed session orphaned), and a daemon that
# lost its pid file but still holds the port. All three are stopped.
# The port and pid files go too: a daemon killed by a signal does not get to
# clean up after itself, and a stale file is what the next client would read.
stop: ## stop the supervised backend, and any daemon the client left behind
	@home="$(JARVIS_HOME_DIR)"; supervised=no; \
	if $(CTL) pid >/dev/null 2>&1; then \
		$(CTL) stop agentd; \
		$(CTL) shutdown; \
		for i in $$(seq 1 40); do [ -f "$$home/supervisord.pid" ] || break; sleep 0.25; done; \
		echo "supervisord stopped"; supervised=yes; \
	fi; \
	if [ -f "$$home/agentd.pid" ]; then \
		if kill $$(cat "$$home/agentd.pid") 2>/dev/null; then echo "agentd stopped"; \
		elif [ "$$supervised" = no ]; then echo "agentd was not running (stale pid file removed)"; fi; \
		rm -f "$$home/agentd.port" "$$home/agentd.pid"; \
	elif [ "$$supervised" = no ]; then \
		echo "no daemon on record in $$home"; \
	fi; \
	if command -v lsof >/dev/null; then \
		for i in $$(seq 1 40); do \
			left=$$(lsof -ti tcp:$(AGENT_PORT) -sTCP:LISTEN 2>/dev/null); \
			[ -n "$$left" ] || break; \
			[ $$i -eq 1 ] && echo "killing what still holds port $(AGENT_PORT) (pid $$(echo $$left | tr '\n' ' '))"; \
			kill $$left 2>/dev/null; sleep 0.25; \
		done; \
		[ -z "$$left" ] || kill -9 $$left 2>/dev/null; \
	fi

.PHONY: api
# The server in the foreground on a port of your choosing, because it prints
# what it is doing. It is the same `agentd listen` that `make start`
# supervises: REST at /v1/<op>, a turn that streams over server-sent events
# at /v1/chat/stream, and the WebSocket at /ws — every client on one port.
#
#   curl localhost:8808/health
#   curl -N 'localhost:8808/v1/chat/stream?text=what+is+a+mutex'
api: agentd-mlx ## the server in the foreground: the web client, REST, SSE and the WebSocket (API_PORT=8808, BIND=127.0.0.1)
	cd $(ROOT) && $(AGENTD_BEST) listen --port $(API_PORT) --bind $(BIND)

.PHONY: web
# The web client is the backend itself, at `/`: every agent on a rail, every
# shelf under it, a turn streamed, a phone's camera roll filed straight onto
# a shelf. This opens it in the browser against whatever `make start` left
# running. `make start BIND=0.0.0.0` first, and the same page answers on the
# Wi-Fi — the share button on it shows the address to type on a phone.
web: ## open the web client in the browser (backend from `make start`)
	@home="$(JARVIS_HOME_DIR)"; port=$$(cat "$$home/agentd.port" 2>/dev/null); \
	[ -n "$$port" ] || { echo "no backend on record in $$home — make start first"; exit 1; }; \
	echo "http://127.0.0.1:$$port/"; open "http://127.0.0.1:$$port/"

.PHONY: status
status: ## is the backend up, and on which port
	@home="$(JARVIS_HOME_DIR)"; \
	if $(CTL) pid >/dev/null 2>&1; then $(CTL) status; else echo "supervisord  not running"; fi; \
	if [ -f "$$home/agentd.port" ]; then \
		echo "agentd       127.0.0.1:$$(cat "$$home/agentd.port")  pid $$(cat "$$home/agentd.pid" 2>/dev/null)  $$home"; \
		echo "web          http://127.0.0.1:$$(cat "$$home/agentd.port")/"; \
		grep -h "also reachable" "$$home/agentd.log" 2>/dev/null | tail -n 2 | sed 's/^ *also reachable at/phone       /'; \
	else \
		echo "agentd       no port on file in $$home"; \
	fi

# The old name still answers; `stop` took it over.
.PHONY: agent-stop
agent-stop: stop

.PHONY: gui
# Nothing is built and nothing is started: this is the inner loop for work
# on the Lua client. The window connects to the backend `make start` left
# running — or, with none running, starts `agentd` itself from the last
# build and stops it on the way out.
gui: ## just the LÖVE client, no build — the Lua iteration loop (backend from `make start`, or started on demand)
	@command -v $(LOVE) >/dev/null || { echo "love not found - run make install-love"; exit 1; }
	cd $(ROOT) && $(LOVE) $(ROBOTS)

.PHONY: love2d
# The whole thing from source: build the backend, run it as a service, then
# the client on top of it. `ONDEVICE_ENGINE=mlx` pins the on-device brain to
# the engine in the server for this run rather than falling through to an
# ollama daemon that happens to be running; the provider ring (F9) still
# reaches the cloud.
love2d: start ## build and start the backend, then run the LÖVE client against it
	@command -v $(LOVE) >/dev/null || { echo "love not found - run make install-love"; exit 1; }
	cd $(ROOT) && ONDEVICE_ENGINE=mlx $(LOVE) $(ROBOTS)

# The old names still answer.
.PHONY: robots
robots: love2d

.PHONY: face
face: ## face mode: one agent, one conversation, nothing else (backend as `make gui`)
	@command -v $(LOVE) >/dev/null || { echo "love not found - run make install-love"; exit 1; }
	cd $(ROOT) && $(LOVE) $(ROBOTS) --face

## -------------------------------------------------------------- package ----
#
# What a release is made of, and how it is signed.
#
# One artifact: the LÖVE client as a double-clickable app, with `libjarvis` —
# the backend itself — inside it. The client calls the backend in its own
# process, so there is no server to ship beside the app, none to start on
# launch, and none left running after the window closes. One thing to
# download, one to open, one to quit.
#
# Signing is ad hoc unless APPLE_SIGNING_IDENTITY names a Developer ID, and
# `make notarize-app` then submits the bundle and staples the ticket into it.
# Ad hoc is not nothing: on arm64 an unsigned executable does not run at all.
# What it costs is portability, so a build meant to be downloaded needs the
# real certificate.
#
#   APPLE_SIGNING_IDENTITY="Developer ID Application: …" make package
#
# The same environment contract as CausewaybayWallet, so one exported set of
# credentials covers both repositories.
#
# `make package-bin` is still here and is not part of a release: the terminal
# binaries — rustcli, rusttui, agentd — signed and tarred for anyone who wants
# them without the app.

DIST := $(ROOT)/dist
VERSION ?= $(shell sed -n 's/^version = "\(.*\)"/\1/p' $(ROOT)/rust/Cargo.toml | head -1)

.PHONY: version
# The one number a release is allowed to carry. The tag check in
# .github/workflows/release.yml reads it from here rather than being told it,
# so a tag that disagrees with the workspace stops the release.
version: ## print the version of record (rust/Cargo.toml)
	@echo $(VERSION)

.PHONY: package
package: package-app ## the release: the signed app, with the backend inside it (dist/)

.PHONY: package-bin
# The terminal binaries: built optimised, staged, signed one by one, tarred.
# Not part of a release — the app is — but a working target for anyone who
# wants the command-line tools on their own. `release` builds the whole
# workspace, and `agentd-mlx` then rebuilds the server with the on-device
# engine in it, which is the copy that ships in the tarball.
package-bin: release agentd-mlx ## the terminal binaries, signed and tarred — not part of a release
	@cd $(ROOT) && $(ROOT)/tools/package-bin.sh $(BIN) $(DIST) $(VERSION)

.PHONY: package-app
# The app: the LÖVE client fused in and `libjarvis` — the backend — beside the
# LÖVE binary inside the bundle. `tools/package.sh` does the work. `ffi` and
# not `agentd-mlx`: what ships is the library the client calls, engine and all,
# and there is no second process in the bundle any more.
# What it needs is the bundle, not a `love` on PATH: the app is copied and
# signed, never run. tools/package.sh looks for it and says where to get one.
package-app: ffi ## build the LÖVE app with the backend inside it, zipped for a release (dist/)
	@cd $(ROOT) && $(ROOT)/tools/package.sh $(LIB) $(DIST) $(VERSION)

.PHONY: notarize-app
# The other half of shipping the app: a Developer ID signature is necessary
# and not sufficient, because macOS also wants the bundle notarized before it
# will open a download. A no-op without APPLE_ID, APPLE_PASSWORD and
# APPLE_TEAM_ID, so a build with no credentials still finishes.
notarize-app: ## notarize the packaged app, staple the ticket, rebuild the zip
	@cd $(ROOT) && $(ROOT)/tools/notarize-app.sh \
		$(DIST)/CausewaybayJarvis.app $(DIST)/CausewaybayJarvis-$(VERSION)-macos-arm64.zip

.PHONY: ai
ai: agentd ## the AI setup as the backend sees it: engine, daemon, cloud, and where each value came from
	@cd $(ROOT) && $(AGENTD_BEST) config

.PHONY: agent
agent: agentd ## drive the backend by hand: make agent A="chat 'what should I cook?'"
	@test -n "$(A)" || { echo 'set A, e.g. make agent A="health" or A="search bones --mode bm25"'; exit 1; }
	@cd $(ROOT) && eval "$(AGENTD_BEST) $(A)"

.PHONY: robots-shots
# Deliberately does not rebuild agentd: it photographs whichever backend is
# there — `make agentd` for the lean one, `make agentd-mlx` for the engine —
# instead of quietly downgrading a gui build to the cloud on its way out.
robots-shots: ## walk the client through every screen and photograph each one
	@cd $(ROOT) && test -x "$(AGENTD)" -o -x "$(BIN)/agentd-mlx" || { echo "agentd not built - run make agentd or make agentd-mlx"; exit 1; }
	@command -v $(LOVE) >/dev/null || { echo "love not found - run make install-love"; exit 1; }
	@cd $(ROOT) && JARVIS_QA=1 $(LOVE) $(ROBOTS) || true
	@out=/tmp/robots-shots; save="$$HOME/Library/Application Support/LOVE/causewaybay-jarvis-robots"; \
	  mkdir -p $$out; \
	  for f in qa_boot qa_dash qa_page qa_gallery qa_search qa_paper qa_filebox qa_face qa_setup qa_setup_alt qa_agents qa_dash_alt; do \
	    cp "$$save/$$f.png" "$$out/$$f.png" 2>/dev/null || echo "missing $$f.png"; \
	  done; \
	  ls -la $$out

.PHONY: paper
paper: agentd ## one robot's archive as a 1024x1024 PNG: make paper A=food
	@cd $(ROOT) && $(AGENTD_BEST) paper $(or $(A),global) --sprite $(ROBOTS)/assets/agent_$$($(AGENTD_BEST) agents.get $(or $(A),global) 2>/dev/null | sed -n 's/.*"sprite":"\([a-z0-9_]*\)".*/\1/p').png

.PHONY: archive
archive: agentd ## what the robots know, and where it is kept
	@cd $(ROOT) && $(AGENTD_BEST) stats
	@$(AGENTD_BEST) agents.list | $(PYTHON) -c "import json,sys; \
	  [print('  %-10s %-8s %-16s %s' % (a['slug'], a['sprite'], a['name'], a['role'])) \
	   for a in json.load(sys.stdin)['data']]"

## ----------------------------------------------------------------- test ----

.PHONY: test
test: test-core test-mlx test-ffi test-cli test-tui test-agent test-lua test-love test-robots ## every unit and integration test

.PHONY: test-core
test-core: ## rustcore: config, templating, tokenizer, streaming
	$(CARGO) test $(MANIFEST) -p rustcore $(TEST_FLAGS)

.PHONY: test-mlx
test-mlx: ## rustmlx: layers, cache, sampler, Metal kernel
	$(CARGO) test $(MANIFEST) -p rustmlx $(TEST_FLAGS)

.PHONY: test-ffi
test-ffi: ## rustffi: the C ABI, driven the way C drives it
	$(CARGO) test $(MANIFEST) -p rustffi $(TEST_FLAGS)

.PHONY: test-lua
# LuaJIT is not a build dependency of anything else here, so a machine without
# it skips rather than fails — the same bargain the GPU-only tests make. CI
# installs it, so the lane that gates a pull request does run these.
test-lua: ffi-debug ## the Lua bindings and the chat client
	@if command -v $(LUA) >/dev/null; then \
		set -x; JARVIS_LIB=$(LIB_DEBUG) $(LUA) $(ROOT)/lua/test.lua; \
	else \
		echo "skipped: $(LUA) not found — brew install luajit to run the Lua tests"; \
	fi

.PHONY: test-love
# The LOVE client cannot be unit-tested without a graphics context, but it can
# be parsed, and a typo in a file only reached by one keypress is exactly the
# kind of thing that otherwise ships.
test-love: ## syntax-check every file of both LOVE clients
	@if command -v $(LUA) >/dev/null; then \
		n=0; for f in $(ROOT)/love/*.lua $(ROOT)/love/src/*.lua $(ROOT)/love/src/scenes/*.lua \
		              $(ROBOTS)/*.lua $(ROBOTS)/src/*.lua $(ROBOTS)/tests/*.lua; do \
			$(LUA) -e "assert(loadfile('$$f'))" || exit 1; n=$$((n+1)); \
		done; \
		echo "love: $$n files parse"; \
	else \
		echo "skipped: $(LUA) not found - brew install luajit"; \
	fi

.PHONY: test-agent
test-agent: ## rustagent: the space, the schema, both searches, the harness, the protocol
	$(CARGO_PLAIN) test $(MANIFEST) -p rustagent

.PHONY: test-robots
# Runs inside LOVE, because half of what it checks is the bridge to `agentd`
# and the only honest way to test that is to run one. The daemon-facing suite
# skips itself when `make agentd` has not been run.
test-robots: agentd ## the robot client, and the round trip to the server
	@if command -v $(LOVE) >/dev/null; then \
		JARVIS_TEST=1 $(LOVE) $(ROBOTS) --test; \
	else \
		echo "skipped: love not found - run make install-love"; \
	fi

.PHONY: test-cli
test-cli: ## rustcli: argument handling and the commands that need no model
	$(CARGO) test $(MANIFEST) -p rustcli $(TEST_FLAGS)

.PHONY: test-tui
test-tui: ## rusttui: editing and rendering, against a test backend
	$(CARGO) test $(MANIFEST) -p rusttui $(TEST_FLAGS)

.PHONY: test-nogpu
# `--nocapture` is not noise here: a skipped test still reports `ok`, so
# without it the GPU-only tests would silently read as coverage they did not
# provide. The skip lines are the only evidence of what was not checked.
test-nogpu: ## the suite the way CI runs it: no Metal device, GPU-only tests skipped
	JARVIS_NO_METAL=1 $(MAKE) test TEST_FLAGS="-- --test-threads=1 --nocapture"
	@echo
	@echo "note: tests marked 'skipped: no Metal device' were NOT run —"
	@echo "      use 'make test' on a machine with a GPU to cover them."

.PHONY: test-model
test-model: ## the tests that load the real checkpoint (needs `make model`)
	JARVIS_TEST_MODEL=1 $(CARGO) test $(MANIFEST) --release -p rustmlx --test checkpoint $(TEST_FLAGS) --nocapture
	JARVIS_TEST_MODEL=1 $(CARGO) test $(MANIFEST) --release -p rustcli --test commands $(TEST_FLAGS)
	JARVIS_TEST_MODEL=1 $(CARGO) test $(MANIFEST) --release -p rustcore --test template $(TEST_FLAGS)
	$(MAKE) lua-test-model

.PHONY: lua-test-model
lua-test-model: ffi ## the Lua tests that load the real checkpoint
	@if command -v $(LUA) >/dev/null; then \
		set -x; JARVIS_TEST_MODEL=1 JARVIS_LIB=$(LIB) $(LUA) $(ROOT)/lua/test.lua; \
	else \
		echo "skipped: $(LUA) not found"; \
	fi

.PHONY: verify
verify: ## compare this port against mlx_lm token for token
	@test -f $(REFERENCE) || { echo "$(REFERENCE) missing — run: make reference"; exit 1; }
	$(CARGO) run $(MANIFEST) --release -p rustmlx --example logits_check

.PHONY: reference
reference: ## regenerate the mlx_lm reference (needs python + mlx-lm)
	cd $(ROOT) && $(PYTHON) $(ROOT)/tools/reference_logits.py $$($(BIN)/rustcli --model $(MODEL) info | awk '/^repository/ {print $$2}') $(REFERENCE)

.PHONY: ci
ci: fmt-check lint test ## what a pull request has to pass

.PHONY: test-all
test-all: test test-model verify ## everything, including the checks that need the weights

## ---------------------------------------------------------------- clean ----

.PHONY: clear
clear: ## delete runtime scratch: the data dir, the REPL history, stray test temps
	rm -rf $(DATA)
	rm -f "$${XDG_CONFIG_HOME:-$$HOME/.config}/jarvis/history"
	rm -rf "$${TMPDIR:-/tmp}"/jarvis-hub-* "$${TMPDIR:-/tmp}"/jarvis-transcript-*.json
	rm -f "$$HOME/Library/Application Support/LOVE/causewaybay-jarvis"/shot-*.png
	@echo "cleared $(DATA), the REPL history and the test temporaries"

.PHONY: clean
clean: ## remove build output (leaves the downloaded weights alone)
	cargo clean $(MANIFEST)

.PHONY: distclean
distclean: clean clear ## also delete the downloaded weights
	rm -rf ~/.cache/huggingface/hub/models--mlx-community--Qwen3.8-27B-4bit
