# Causewaybay Jarvis — an on-device AI agent in Rust on Apple MLX.
#
#   make setup      check the toolchain
#   make model      download the weights (~15 GiB, once)
#   make chat       talk to it
#   make test       everything
#   make clear      throw away runtime scratch (clean = build output)
#
# Building `rustmlx` compiles MLX from source, which needs Apple's Metal
# compiler. That lives inside Xcode, not the Command Line Tools, so every
# cargo invocation below runs with DEVELOPER_DIR pointed at it.

SHELL := /bin/bash
.DEFAULT_GOAL := help

XCODE ?= /Applications/Xcode.app/Contents/Developer
CARGO := DEVELOPER_DIR=$(XCODE) cargo
# The Rust workspace lives under rust/; cargo is pointed at it rather than run
# from inside it, so recipes keep the repository root as their working
# directory — that is where config.jsonl and tools/ are looked up.
MANIFEST := --manifest-path rust/Cargo.toml
BIN := rust/target/release
# MLX drives one GPU queue, so tests that touch it must not run concurrently.
TEST_FLAGS := -- --test-threads=1

MODEL ?= qwen3.8:27b-mlx
PYTHON ?= python3
# The Lua client talks to the workspace through `libjarvis`, the cdylib that
# `rustffi` builds. LuaJIT rather than Lua: the bindings are `ffi.cdef`, which
# only LuaJIT has.
LUA ?= luajit
LIBNAME := libjarvis.dylib
LIB := $(BIN)/$(LIBNAME)
LIB_DEBUG := rust/target/debug/$(LIBNAME)
REFERENCE := tools/reference.json
# Runtime scratch, per the `paths` key in config.jsonl. `make clear` empties it.
DATA := data

BOLD := \033[1m
DIM := \033[2m
OFF := \033[0m

## ----------------------------------------------------------------- help ----

.PHONY: help
help: ## list the targets
	@echo -e "$(BOLD)Causewaybay Jarvis$(OFF)"
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

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

## ---------------------------------------------------------------- build ----

.PHONY: build
build: ## debug build of the whole workspace
	$(CARGO) build $(MANIFEST) --workspace

.PHONY: release
release: ## optimised build (use this one)
	$(CARGO) build $(MANIFEST) --release --workspace

.PHONY: ffi
ffi: ## build libjarvis, the C ABI the Lua client loads
	$(CARGO) build $(MANIFEST) --release -p rustffi
	@echo "$(LIB)"

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
	$(BIN)/rustcli --model $(MODEL) pull

.PHONY: info
info: release ## what is configured and what is on disk
	$(BIN)/rustcli --model $(MODEL) info

.PHONY: models
models: release ## list the model aliases this build knows
	$(BIN)/rustcli models

## ------------------------------------------------------------------ run ----

.PHONY: chat
chat: release ## interactive chat in the terminal
	$(BIN)/rustcli --model $(MODEL) chat

.PHONY: tui
tui: release ## full-screen chat
	$(BIN)/rusttui --model $(MODEL)

.PHONY: ask
ask: release ## one-shot: make ask Q="why is the sky blue?"
	@test -n "$(Q)" || { echo 'set Q, e.g. make ask Q="why is the sky blue?"'; exit 1; }
	$(BIN)/rustcli --model $(MODEL) run "$(Q)"

.PHONY: lua-chat
lua-chat: ffi ## interactive chat through the Lua client
	JARVIS_LIB=$(LIB) $(LUA) lua/chat.lua --model $(MODEL) chat

.PHONY: lua-ask
lua-ask: ffi ## one-shot through Lua: make lua-ask Q="why is the sky blue?"
	@test -n "$(Q)" || { echo 'set Q, e.g. make lua-ask Q="why is the sky blue?"'; exit 1; }
	JARVIS_LIB=$(LIB) $(LUA) lua/chat.lua --model $(MODEL) run "$(Q)"

.PHONY: bench
bench: release ## measure prefill and decode throughput
	$(BIN)/rustcli --model $(MODEL) bench --prompt 512 --tokens 128

## ----------------------------------------------------------------- test ----

.PHONY: test
test: test-core test-mlx test-ffi test-cli test-tui test-lua ## every unit and integration test

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
		set -x; JARVIS_LIB=$(LIB_DEBUG) $(LUA) lua/test.lua; \
	else \
		echo "skipped: $(LUA) not found — brew install luajit to run the Lua tests"; \
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
		set -x; JARVIS_TEST_MODEL=1 JARVIS_LIB=$(LIB) $(LUA) lua/test.lua; \
	else \
		echo "skipped: $(LUA) not found"; \
	fi

.PHONY: verify
verify: ## compare this port against mlx_lm token for token
	@test -f $(REFERENCE) || { echo "$(REFERENCE) missing — run: make reference"; exit 1; }
	$(CARGO) run $(MANIFEST) --release -p rustmlx --example logits_check

.PHONY: reference
reference: ## regenerate the mlx_lm reference (needs python + mlx-lm)
	$(PYTHON) tools/reference_logits.py $$($(BIN)/rustcli --model $(MODEL) info | awk '/^repository/ {print $$2}') $(REFERENCE)

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
	@echo "cleared $(DATA), the REPL history and the test temporaries"

.PHONY: clean
clean: ## remove build output (leaves the downloaded weights alone)
	cargo clean $(MANIFEST)

.PHONY: distclean
distclean: clean clear ## also delete the downloaded weights
	rm -rf ~/.cache/huggingface/hub/models--mlx-community--Qwen3.8-27B-4bit
