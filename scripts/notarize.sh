#!/bin/sh
# Notarizes the Developer ID build made by scripts/package-app.sh, then staples the ticket and writes a notarized zip.
# This script never asks for an Apple ID or password. It uses a notarytool keychain profile that you create once, on your
# own Mac, with `xcrun notarytool store-credentials`. docs/distribution.md has the steps. Nothing here runs in CI.
#
#   MACFLEET_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" sh scripts/package-app.sh
#   MACFLEET_NOTARY_PROFILE=macfleet-notary sh scripts/notarize.sh
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/config.sh

PROFILE="${MACFLEET_NOTARY_PROFILE:-}"
if [ -z "$PROFILE" ]; then
  echo "notarize: set MACFLEET_NOTARY_PROFILE to a notarytool keychain profile. docs/distribution.md explains how." >&2
  exit 2
fi

VERSION=$(xcconfig_value Config/Version.xcconfig MARKETING_VERSION)
IDENTITY=$(signing_identity)
if [ "$IDENTITY" = "-" ]; then
  echo "notarize: the package is signed ad hoc. Notarization needs a Developer ID build first (MACFLEET_SIGN_IDENTITY)." >&2
  exit 2
fi
ZIP="dist/MacFleet-$VERSION.zip"
if [ ! -f "$ZIP" ]; then
  echo "notarize: $ZIP is missing. Run scripts/package-app.sh with a Developer ID first." >&2
  exit 2
fi

STAGE=$(mktemp -d "$PWD/.agent-local/notarize.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto -x -k "$ZIP" "$STAGE"

xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$STAGE/MacFleet.app"
xcrun stapler validate "$STAGE/MacFleet.app"
spctl --assess --type execute --verbose=4 "$STAGE/MacFleet.app"

OUT="dist/MacFleet-$VERSION-notarized.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$STAGE/MacFleet.app" "$OUT"
(cd dist && shasum -a 256 "MacFleet-$VERSION-notarized.zip" > SHA256SUMS-notarized)
echo "notarized and stapled: $OUT"
