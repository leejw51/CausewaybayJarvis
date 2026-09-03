#!/usr/bin/env bash
# Put love.app somewhere, from the upstream release rather than from Homebrew.
#
#   tools/get-love.sh [destination]     # default /Applications
#
# Homebrew disabled the `love` cask on 2026-09-01: the bundle upstream ships
# does not pass the macOS Gatekeeper check, and brew now refuses to install it
# rather than hand over something a user cannot open. That is a fair thing for
# a package manager to do and the wrong thing for this repository to inherit,
# because `make package-app` does not run love.app — it copies it, fuses the
# client into it, and signs the whole bundle again. Whatever signature the
# download arrived with is replaced by ours.
#
# So: fetch the release directly, check it against a pinned hash, unpack it.
# The version and the hash are here, in the open, rather than implied by
# whatever a package manager happened to have that day.
#
# The bundle is universal (arm64 and x86_64), and it is LÖVE 11, which embeds
# LuaJIT — the client's `ffi.cdef` bindings need that, not plain Lua.
set -euo pipefail

VERSION="${LOVE_VERSION:-11.5}"
SHA256="${LOVE_SHA256:-6795bb3a1656af6a2fdfe741e150787b481886d3a280327a261a3fdded586913}"
DEST="${1:-/Applications}"
URL="https://github.com/love2d/love/releases/download/$VERSION/love-$VERSION-macos.zip"

[ "$(uname -s)" = "Darwin" ] || { echo "macOS only"; exit 1; }

if [ -d "$DEST/love.app" ]; then
  echo "love.app already at $DEST/love.app"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Fetching LÖVE $VERSION"
curl -fsSL --retry 3 -o "$TMP/love.zip" "$URL"

# A pinned hash rather than a signature check: the bundle's own signature is
# the thing brew objected to, and it is replaced during packaging anyway. What
# this guarantees is that the bytes are the ones this repository was tested
# against.
GOT="$(shasum -a 256 "$TMP/love.zip" | awk '{print $1}')"
if [ "$GOT" != "$SHA256" ]; then
  echo "error: love-$VERSION-macos.zip does not match the pinned hash" >&2
  echo "  expected $SHA256" >&2
  echo "  got      $GOT" >&2
  exit 1
fi

unzip -q "$TMP/love.zip" -d "$TMP"
[ -d "$TMP/love.app" ] || { echo "error: no love.app inside the archive" >&2; exit 1; }

mkdir -p "$DEST"
# The quarantine flag comes with anything curl downloaded, and a bundle that
# is about to be taken apart and signed again has no use for it.
xattr -cr "$TMP/love.app" 2>/dev/null || true
rm -rf "$DEST/love.app"
mv "$TMP/love.app" "$DEST/love.app"

echo "love  $DEST/love.app"
echo "      $("$DEST/love.app/Contents/MacOS/love" --version 2>/dev/null || echo "LÖVE $VERSION")"
