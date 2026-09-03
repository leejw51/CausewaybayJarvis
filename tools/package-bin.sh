#!/usr/bin/env bash
# Stage the release binaries, sign each one, and tar the result.
#
#   tools/package-bin.sh <target-release-dir> <out-dir> [version]
#
# What comes out is `<out-dir>/causewaybay-jarvis-<version>-<arch>-apple-darwin
# .tar.gz`, and the staging directory it was made from. Inside: the backend
# every client talks to, the two terminal clients, the C ABI the Lua clients
# load, and MLX's Metal library.
#
#   agentd            the server (with the on-device MLX engine)
#   rustcli           chat, ask, bench, pull — the model from the terminal
#   rusttui           the same, full-screen
#   libjarvis.dylib   the C ABI: what LuaJIT and LÖVE load
#   mlx.metallib      MLX's compiled kernels, which all of the above look for
#                     beside themselves at runtime
#
# Apple silicon only, and the weights are not in the tarball — 15 GiB. A fresh
# install answers from the archive, from a local ollama daemon, or from the
# cloud with a key, until `rustcli pull` puts the model on the machine.
#
# Signing is tools/codesign-binary.sh's: ad hoc unless APPLE_SIGNING_IDENTITY
# names a Developer ID, and notarized on top of that when APPLE_ID,
# APPLE_PASSWORD and APPLE_TEAM_ID are all set.
set -euo pipefail

BIN="${1:?the cargo release directory}"
OUT="${2:?the output directory}"
VERSION="${3:-0.1.0}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
NAME="causewaybay-jarvis-$VERSION-$ARCH-apple-darwin"
STAGE="$OUT/$NAME"

# The engine-carrying copy when `make agentd-mlx` left one, the plain build
# otherwise. Shipped as `agentd` either way: the two names exist so a lean
# rebuild cannot strip the engine out from under a running client, which is a
# build-tree problem and not something a release has to carry.
AGENTD="$BIN/agentd-mlx"
[ -x "$AGENTD" ] || AGENTD="$BIN/agentd"
[ -x "$AGENTD" ] || { echo "no server binary under $BIN — run make agentd-mlx"; exit 1; }

# MLX ships its kernels as `mlx.metallib` and looks for it next to the binary
# that contains MLX, then at the absolute path it was built at. The second is
# a directory on the build machine and nowhere else, so the first is the one a
# shipped binary can rely on. cargo leaves the file in the mlx-sys build
# directory; the newest one is the one this build linked against.
METALLIB="${METALLIB:-}"
if [ -z "$METALLIB" ]; then
  METALLIB="$(ls -t "$BIN"/build/mlx-sys-*/out/build/lib/mlx.metallib 2>/dev/null | head -1 || true)"
fi
if [ -z "$METALLIB" ] && [ -f "$BIN/mlx.metallib" ]; then
  METALLIB="$BIN/mlx.metallib"
fi
[ -n "$METALLIB" ] && [ -f "$METALLIB" ] || { echo "mlx.metallib not found under $BIN — set METALLIB"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"

cp "$AGENTD" "$STAGE/agentd"
for b in rustcli rusttui; do
  [ -x "$BIN/$b" ] || { echo "no $b under $BIN — run make release"; exit 1; }
  cp "$BIN/$b" "$STAGE/$b"
done
[ -f "$BIN/libjarvis.dylib" ] || { echo "no libjarvis.dylib under $BIN — run make ffi"; exit 1; }
cp "$BIN/libjarvis.dylib" "$STAGE/libjarvis.dylib"
cp "$METALLIB" "$STAGE/mlx.metallib"
cp "$ROOT/LICENSE" "$ROOT/README.md" "$STAGE/"
chmod +x "$STAGE/agentd" "$STAGE/rustcli" "$STAGE/rusttui"

# A copy carries the source file's signature, which the copy invalidates.
# Sign after staging, so what ships is what was signed.
echo "==> Signing"
for f in agentd rustcli rusttui libjarvis.dylib; do
  "$ROOT/tools/codesign-binary.sh" "$STAGE/$f"
done

# COPYFILE_DISABLE keeps macOS from smuggling ._ resource-fork files in.
TAR="$OUT/$NAME.tar.gz"
rm -f "$TAR"
COPYFILE_DISABLE=1 tar -czf "$TAR" -C "$OUT" "$NAME"
( cd "$OUT" && shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

echo "stage $STAGE"
echo "metal $METALLIB"
echo "tar   $TAR  ($(du -h "$TAR" | cut -f1))"
echo "sign  ${APPLE_SIGNING_IDENTITY:--}$( [ "${APPLE_SIGNING_IDENTITY:--}" = - ] && echo '  (ad hoc: runs here; a download needs a Developer ID and notarization)' )"
