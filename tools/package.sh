#!/bin/bash
# Build the LÖVE client as a macOS app with the backend inside it.
#
#   tools/package.sh <libjarvis.dylib> <out-dir> [version]
#
# What comes out is `<out-dir>/CausewaybayJarvis.app` and a zip of it: the
# stock love.app with the robots/ client fused in as `game.love`, and
# `libjarvis` — the backend itself — beside the LÖVE binary in Contents/MacOS.
# The client finds it there (see `Backend.findLib` in robots/src/backend.lua)
# and calls it in its own process, so the app is one thing: one process to
# start, one to quit, and nothing left running afterwards.
#
# It used to ship `agentd` here and start it as a child process on launch.
# That worked, and it meant a release was an app plus a server that had to
# find each other through a port file — twenty seconds of waiting at worst,
# an orphaned daemon holding fifteen gigabytes at worst-worst. The library
# carries the same backend, from the same dispatch, called instead of
# connected to.
#
# Apple silicon only: the library links MLX. The weights are not in the
# bundle — 15 GiB — so the first run answers from the archive (and the
# cloud, with a key) until `rustcli pull` or a local ollama daemon puts the
# model on the machine.
#
# Signing: ad hoc (`-`) unless SIGN_IDENTITY — or APPLE_SIGNING_IDENTITY, the
# name tools/codesign-binary.sh and CausewaybayWallet use — names a Developer
# ID. An ad-hoc signature runs on the machine that built it; a download needs
# the Developer ID, and then notarization (`xcrun notarytool submit --wait`,
# then `xcrun stapler staple` — a bundle, unlike a bare binary, has somewhere
# to keep the ticket).
set -euo pipefail

LIB="${1:?the libjarvis dylib}"
OUT="${2:?the output directory}"
VERSION="${3:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-${APPLE_SIGNING_IDENTITY:--}}"
NAME="CausewaybayJarvis"
IDENT="com.causewaybay.jarvis"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROBOTS="$ROOT/robots"

# The stock app: the one `make install-love` puts in /Applications, or the
# bundle the `love` on PATH lives in.
LOVE_APP="${LOVE_APP:-}"
if [ -z "$LOVE_APP" ]; then
  if [ -d /Applications/love.app ]; then
    LOVE_APP=/Applications/love.app
  elif command -v love >/dev/null; then
    LOVE_APP="$(cd "$(dirname "$(readlink -f "$(command -v love)")")/../.." && pwd)"
  fi
fi
[ -d "$LOVE_APP/Contents/MacOS" ] || { echo "love.app not found — run make install-love, or set LOVE_APP"; exit 1; }
[ -f "$LIB" ] || { echo "no library at $LIB — run make ffi"; exit 1; }

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

# The backend, beside the LÖVE binary — and MLX's Metal library beside it.
# MLX ships its kernels as `mlx.metallib` and looks for it next to the binary
# that contains MLX, then at the absolute path it was built at; the second is
# a directory on the build machine and nowhere else, so the first is the one a
# shipped app can rely on. cargo leaves the file in the mlx-sys build
# directory; the newest one is the one this library was linked with.
cp "$LIB" "$APP/Contents/MacOS/libjarvis.dylib"
METALLIB="${METALLIB:-}"
if [ -z "$METALLIB" ]; then
  METALLIB="$(ls -t "$(dirname "$LIB")"/build/mlx-sys-*/out/build/lib/mlx.metallib 2>/dev/null | head -1 || true)"
fi
if [ -z "$METALLIB" ] && [ -f "$(dirname "$LIB")/mlx.metallib" ]; then
  METALLIB="$(dirname "$LIB")/mlx.metallib"
fi
[ -n "$METALLIB" ] && [ -f "$METALLIB" ] || { echo "mlx.metallib not found beside $LIB or under its build directory — set METALLIB"; exit 1; }
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
#
# With a real identity the signature has to carry the hardened runtime and a
# secure timestamp: without the first Apple refuses to notarize, and without
# the second the signature dies with the certificate. Ad hoc can have neither
# — there is no timestamp authority for a signature nobody issued.
FLAGS=(--timestamp=none)
if [ "$SIGN_IDENTITY" != "-" ]; then
  FLAGS=(--options runtime --timestamp)
fi
codesign --force --sign "$SIGN_IDENTITY" "${FLAGS[@]}" "$APP/Contents/MacOS/libjarvis.dylib"
find "$APP/Contents/Frameworks" -name "*.framework" -maxdepth 1 -print0 2>/dev/null \
  | xargs -0 -n1 codesign --force --sign "$SIGN_IDENTITY" "${FLAGS[@]}" 2>/dev/null || true
codesign --force --deep --sign "$SIGN_IDENTITY" "${FLAGS[@]}" "$APP"

ZIP="$OUT/$NAME-$VERSION-macos-arm64.zip"
rm -f "$ZIP"
( cd "$OUT" && ditto -c -k --keepParent "$NAME.app" "$(basename "$ZIP")" )

echo "app   $APP"
echo "metal $METALLIB"
echo "zip   $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "sign  $SIGN_IDENTITY$( [ "$SIGN_IDENTITY" = - ] && echo '  (ad hoc: runs here; a download needs a Developer ID and notarization)' )"
