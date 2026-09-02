#!/bin/bash
# Build the LÖVE client as a macOS app with the backend inside it.
#
#   tools/package.sh <agentd-binary> <out-dir> [version]
#
# What comes out is `<out-dir>/CausewaybayJarvis.app` and a zip of it: the
# stock love.app with the robots/ client fused in as `game.love`, and
# `agentd` — the server every client talks to — beside the LÖVE binary in
# Contents/MacOS. The client finds it there (see `Backend.find` in
# robots/src/backend.lua), starts it on launch and stops it on quit, so the
# app is one thing to open and one thing to close.
#
# Apple silicon only: the server links MLX. The weights are not in the
# bundle — 15 GiB — so the first run answers from the archive (and the
# cloud, with a key) until `rustcli pull` or a local ollama daemon puts the
# model on the machine.
#
# Signing: ad hoc (`-`) unless SIGN_IDENTITY names a Developer ID. An ad-hoc
# signature runs on the machine that built it; a download needs the
# Developer ID and notarization (`xcrun notarytool submit`).
set -euo pipefail

AGENTD="${1:?the agentd binary}"
OUT="${2:?the output directory}"
VERSION="${3:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NAME="CausewaybayJarvis"
IDENT="com.causewaybay.jarvis"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROBOTS="$ROOT/robots"

# The stock app: the one `brew install --cask love` puts in /Applications,
# or the bundle the `love` on PATH lives in.
LOVE_APP="${LOVE_APP:-}"
if [ -z "$LOVE_APP" ]; then
  if [ -d /Applications/love.app ]; then
    LOVE_APP=/Applications/love.app
  elif command -v love >/dev/null; then
    LOVE_APP="$(cd "$(dirname "$(readlink -f "$(command -v love)")")/../.." && pwd)"
  fi
fi
[ -d "$LOVE_APP/Contents/MacOS" ] || { echo "love.app not found — brew install --cask love, or set LOVE_APP"; exit 1; }
[ -x "$AGENTD" ] || { echo "no server binary at $AGENTD — run make agentd-mlx"; exit 1; }

APP="$OUT/$NAME.app"
rm -rf "$APP"
mkdir -p "$OUT"
cp -R "$LOVE_APP" "$APP"
# A copied cask carries a quarantine flag and nothing we want from it.
xattr -cr "$APP" 2>/dev/null || true

# The game, fused: everything in robots/ except the tests and the tooling.
GAME="$APP/Contents/Resources/game.love"
rm -f "$GAME"
( cd "$ROBOTS" && zip -q -r -9 "$GAME" . -x 'tests/*' -x 'scripts/*' -x '.env' -x '*.pyc' )

# The server, beside the LÖVE binary — and MLX's Metal library beside the
# server. MLX ships its kernels as `mlx.metallib` and looks for it next to
# the binary that contains MLX, then at the absolute path it was built at;
# the second is a directory on the build machine and nowhere else, so the
# first is the one a shipped app can rely on. cargo leaves the file in the
# mlx-sys build directory; the newest one is the one this binary was
# linked with.
cp "$AGENTD" "$APP/Contents/MacOS/agentd"
chmod +x "$APP/Contents/MacOS/agentd"
METALLIB="${METALLIB:-}"
if [ -z "$METALLIB" ]; then
  METALLIB="$(ls -t "$(dirname "$AGENTD")"/build/mlx-sys-*/out/build/lib/mlx.metallib 2>/dev/null | head -1 || true)"
fi
if [ -z "$METALLIB" ] && [ -f "$(dirname "$AGENTD")/mlx.metallib" ]; then
  METALLIB="$(dirname "$AGENTD")/mlx.metallib"
fi
[ -n "$METALLIB" ] && [ -f "$METALLIB" ] || { echo "mlx.metallib not found beside $AGENTD or under its build directory — set METALLIB"; exit 1; }
cp "$METALLIB" "$APP/Contents/MacOS/mlx.metallib"

# The bundle's own identity.
PLIST="$APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "Causewaybay Jarvis" "$PLIST"
plutil -replace CFBundleIdentifier -string "$IDENT" "$PLIST"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"
# LÖVE's own document types would make this app claim every .love file.
plutil -remove CFBundleDocumentTypes "$PLIST" 2>/dev/null || true
plutil -remove UTExportedTypeDeclarations "$PLIST" 2>/dev/null || true

# Sign everything that is Mach-O, inside out, so Gatekeeper sees one
# consistent bundle. `--deep` is not enough for a helper binary in MacOS/.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP/Contents/MacOS/agentd"
find "$APP/Contents/Frameworks" -name "*.framework" -maxdepth 1 -print0 2>/dev/null \
  | xargs -0 -n1 codesign --force --sign "$SIGN_IDENTITY" --timestamp=none 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" --timestamp=none "$APP"

ZIP="$OUT/$NAME-$VERSION-macos-arm64.zip"
rm -f "$ZIP"
( cd "$OUT" && ditto -c -k --keepParent "$NAME.app" "$(basename "$ZIP")" )

echo "app   $APP"
echo "metal $METALLIB"
echo "zip   $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "sign  $SIGN_IDENTITY$( [ "$SIGN_IDENTITY" = - ] && echo '  (ad hoc: runs here; a download needs a Developer ID and notarization)' )"
