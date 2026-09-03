#!/usr/bin/env bash
# Notarize the packaged app, staple the ticket to it, and rebuild the zip.
#
#   tools/notarize-app.sh <app> <zip>
#
# Signing is what `make package-app` already did. This is the other half, and
# the half that decides whether a download opens: since macOS 10.15 anything
# distributed outside the App Store must be notarized as well as signed, or
# Gatekeeper says "Apple could not verify…" and offers no way past it.
#
# Stapling matters here in a way it cannot for a bare binary: a bundle has
# somewhere to keep the ticket, so a stapled app opens on a machine that is
# offline. Without the staple every first run pays for an online check with
# Apple.
#
# The zip is rebuilt afterwards because the ticket is written into the app
# *after* the archive that was submitted was made — ship the old zip and you
# ship the unstapled bundle.
#
#   APPLE_ID / APPLE_PASSWORD / APPLE_TEAM_ID   notarytool's credentials
#
# Nothing happens without all three: an ad-hoc-signed app cannot be notarized,
# and saying so is more useful than a failure from Apple's side.
set -euo pipefail

APP="${1:?usage: notarize-app.sh <app> <zip>}"
ZIP="${2:?usage: notarize-app.sh <app> <zip>}"

[ -d "$APP" ] || { echo "no app bundle at $APP — run make package-app"; exit 1; }

if [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_PASSWORD:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ]; then
  echo "  note: no notarization credentials, $(basename "$APP") is signed only"
  echo "        (a download will be refused by Gatekeeper; a local run is fine)"
  exit 0
fi

# Apple refuses an ad-hoc signature outright, so stop before the submission
# rather than after waiting for it to be rejected.
if codesign -dvv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo "error: $(basename "$APP") is signed ad hoc and cannot be notarized" >&2
  echo "       set APPLE_SIGNING_IDENTITY and run make package-app again" >&2
  exit 1
fi

# notarytool takes an archive. Submit the one that was built if it is there,
# and otherwise make a throwaway.
SUBMIT="$ZIP"
if [ ! -f "$SUBMIT" ]; then
  SUBMIT="$(mktemp -d)/$(basename "$APP").zip"
  ditto -c -k --keepParent "$APP" "$SUBMIT"
fi

echo "==> Notarizing $(basename "$APP")"
xcrun notarytool submit "$SUBMIT" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait --timeout 30m

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

if [ -f "$ZIP" ]; then
  rm -f "$ZIP"
  ( cd "$(dirname "$APP")" && ditto -c -k --keepParent "$(basename "$APP")" "$ZIP" )
  echo "zip   $ZIP  ($(du -h "$ZIP" | cut -f1))"
fi

# What Finder asks, asked the same way. Printed rather than enforced: the
# answer is the interesting part either way.
spctl --assess --type execute --verbose "$APP" || true
