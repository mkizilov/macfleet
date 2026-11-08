#!/bin/sh
# Builds the release packages under dist/: MacFleet.app (the menu bar app) and the headless agent with its install scripts.
#
# Each product is one executable. The modules are compiled to objects and linked in, so no dylib sits beside the program.
# The reason is the hardened runtime: it only maps a library signed by the same team as the program, and an ad hoc build
# has no team, so a separate dylib would be refused at launch. A single executable keeps the hardened runtime on without any
# relaxing entitlement, and it needs no credential. The bundle's Info.plist is written from Config/Version.xcconfig.
#
# Signing is ad hoc unless MACFLEET_SIGN_IDENTITY, or Config/Signing.local.xcconfig, names a Developer ID. Notarization is a
# separate step: scripts/notarize.sh. Packages are arm64 only. docs/distribution.md has the rest.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/config.sh

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
VERSION=$(xcconfig_value Config/Version.xcconfig MARKETING_VERSION)
BUILD=$(xcconfig_value Config/Version.xcconfig CURRENT_PROJECT_VERSION)
BUNDLE_ID=$(xcconfig_value Config/Version.xcconfig MACFLEET_BUNDLE_ID)
MIN_OS=$(xcconfig_value Config/Version.xcconfig MACFLEET_MIN_MACOS)
if [ -z "$VERSION" ] || [ -z "$BUILD" ] || [ -z "$BUNDLE_ID" ] || [ -z "$MIN_OS" ]; then
  echo "package-app: Config/Version.xcconfig is missing a value" >&2
  exit 2
fi
IDENTITY=$(signing_identity)
if [ "$IDENTITY" = "-" ]; then
  TIMESTAMP="--timestamp=none"
  echo "signing: ad hoc (no credential). The packages run on this Mac but cannot be notarized."
else
  TIMESTAMP="--timestamp"
  echo "signing: $IDENTITY, with a secure timestamp"
fi

WORK="$PWD/.agent-local/package-build"
DIST="$PWD/dist"
APP="$WORK/app/MacFleet.app"
HEADLESS="$WORK/headless/macfleet-headless-$VERSION"
COMMON="-swift-version 6 -target arm64-apple-macosx$MIN_OS -sdk $SDK -O -whole-module-optimization"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$WORK"
mkdir -p "$WORK/modules" "$WORK/objects" "$APP/Contents/MacOS" \
  "$HEADLESS/bin" "$HEADLESS/launchd" "$HEADLESS/scripts" "$HEADLESS/docs" "$DIST"

echo "== compiling the modules"
swiftc -emit-object -parse-as-library -module-name MacFleetKit -emit-module \
  -emit-module-path "$WORK/modules/MacFleetKit.swiftmodule" -o "$WORK/objects/MacFleetKit.o" $COMMON \
  -lsqlite3 $(find Sources/MacFleetKit -name '*.swift')
swiftc -emit-object -parse-as-library -module-name MacFleetState -I "$WORK/modules" -emit-module \
  -emit-module-path "$WORK/modules/MacFleetState.swiftmodule" -o "$WORK/objects/MacFleetState.o" $COMMON \
  $(find Sources/MacFleetState -name '*.swift')
swiftc -emit-object -parse-as-library -module-name MacFleetUI -I "$WORK/modules" -emit-module \
  -emit-module-path "$WORK/modules/MacFleetUI.swiftmodule" -o "$WORK/objects/MacFleetUI.o" $COMMON \
  $(find Sources/MacFleetUI -name '*.swift')

echo "== linking the app"
swiftc -parse-as-library -module-name MacFleet -I "$WORK/modules" $COMMON \
  -framework Metal -framework AppKit -framework SwiftUI -lsqlite3 \
  "$WORK/objects/MacFleetKit.o" "$WORK/objects/MacFleetState.o" "$WORK/objects/MacFleetUI.o" \
  App/MacFleetApp.swift App/MacFleetAppDelegate.swift \
  -o "$APP/Contents/MacOS/MacFleet"
sed -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" -e "s|@MIN_OS@|$MIN_OS|g" \
  Support/app/Info.plist.template > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" > /dev/null

echo "== linking the headless agent"
swiftc -module-name macfleet_headless -I "$WORK/modules" $COMMON -framework Metal -lsqlite3 \
  "$WORK/objects/MacFleetKit.o" Sources/MacFleetHeadless/main.swift \
  -o "$HEADLESS/bin/macfleet-headless"
cp Support/launchd/com.macfleet.headless.plist "$HEADLESS/launchd/"
cp scripts/install-agent.sh scripts/uninstall-agent.sh "$HEADLESS/scripts/"
cp docs/installation.md docs/headless-agent.md docs/troubleshooting.md docs/remote-protocol.md "$HEADLESS/docs/"
cp README.md "$HEADLESS/"

echo "== signing"
codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP/Contents/MacOS/MacFleet"
codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --force --options runtime $TIMESTAMP --sign "$IDENTITY" --identifier dev.macfleet.headless "$HEADLESS/bin/macfleet-headless"

echo "== verifying"
codesign --verify --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$HEADLESS/bin/macfleet-headless"
codesign -dv --verbose=4 "$APP" 2> "$WORK/signing-report.txt"
if ! grep -q 'runtime' "$WORK/signing-report.txt"; then
  echo "package-app: the app was not signed with the hardened runtime" >&2
  exit 1
fi
VERSION_LINE=$("$HEADLESS/bin/macfleet-headless" version)
echo "$VERSION_LINE"
case "$VERSION_LINE" in
  "MacFleet $VERSION (build $BUILD),"*) ;;
  *)
    echo "package-app: the headless agent reports a different version than Config/Version.xcconfig" >&2
    exit 1
    ;;
esac

echo "== writing packages"
rm -f "$DIST/MacFleet-$VERSION.zip" "$DIST/macfleet-headless-$VERSION.tar.gz" "$DIST/SHA256SUMS"
ditto -c -k --keepParent "$APP" "$DIST/MacFleet-$VERSION.zip"
tar -C "$WORK/headless" -czf "$DIST/macfleet-headless-$VERSION.tar.gz" "macfleet-headless-$VERSION"
cp "$WORK/signing-report.txt" "$DIST/signing-report-$VERSION.txt"
(cd "$DIST" && shasum -a 256 "MacFleet-$VERSION.zip" "macfleet-headless-$VERSION.tar.gz" > SHA256SUMS)
echo "packages written to dist/:"
ls -1 "$DIST"
