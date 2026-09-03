#!/usr/bin/env bash
# Sign one standalone macOS executable (or dylib), and notarize it when there
# is a real identity to notarize with.
#
#   tools/codesign-binary.sh <path-to-mach-o>
#
# The environment contract is the one CausewaybayWallet uses, so a single
# exported set of credentials covers both repositories:
#
#   APPLE_SIGNING_IDENTITY  Developer ID Application: …   (default: `-`, ad hoc)
#   APPLE_ID                the Apple ID notarytool submits as
#   APPLE_PASSWORD          its app-specific password
#   APPLE_TEAM_ID           the team the certificate belongs to
#
# Ad hoc is not a fallback nobody wants: on arm64 every executable must carry
# *some* signature to run at all, so an unsigned binary is a broken one. What
# the ad-hoc signature costs is portability — it is valid only on the machine
# that made it, so a download needs the Developer ID.
#
# Why this stops at notarization and does not staple: a ticket cannot be
# attached to a bare Mach-O. `stapler` writes into a bundle's
# Contents/CodeResources or a disk image's metadata, and a single executable
# has nowhere to put one. A notarized CLI binary therefore still costs the
# first machine that runs it one online check with Apple.
#
# A no-op off macOS, so a packaging path can call it unconditionally.
set -euo pipefail

BIN="${1:?usage: codesign-binary.sh <path-to-executable>}"

[ "$(uname -s)" = "Darwin" ] || exit 0
[ -f "$BIN" ] || { echo "error: no such file: $BIN" >&2; exit 1; }

IDENTITY="${APPLE_SIGNING_IDENTITY:--}"

command -v codesign >/dev/null 2>&1 || {
  echo "  note: codesign not available, leaving $(basename "$BIN") unsigned"
  exit 0
}

if [ "$IDENTITY" = "-" ]; then
  echo "  signing $(basename "$BIN") ad hoc"
  codesign --force --sign - "$BIN"
  exit 0
fi

# `--options runtime` is the hardened runtime, without which Apple will not
# notarize; `--timestamp` gets a secure timestamp, without which the signature
# expires along with the certificate.
echo "  signing $(basename "$BIN") as $IDENTITY"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BIN"
codesign --verify --strict "$BIN"

if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "  note: no notarization credentials, $(basename "$BIN") is signed only"
  exit 0
fi

# notarytool takes an archive, never a loose executable.
ZIP="$(mktemp -d)/$(basename "$BIN").zip"
trap 'rm -rf "$(dirname "$ZIP")"' EXIT
ditto -c -k "$BIN" "$ZIP"

echo "  notarizing $(basename "$BIN")"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait --timeout 30m

# No `stapler staple` here — see the header. The check below is what a user's
# machine does on first run, so failing it now is worth knowing about.
if ! spctl --assess --type execute "$BIN" 2>/dev/null; then
  echo "  note: spctl still refuses $(basename "$BIN") — expected for a bare"
  echo "        binary until Gatekeeper's online check sees the ticket"
fi
