#!/bin/sh
# Builds, tests and runs MacFleet with swiftc only. SwiftPM's build service cannot
# write its databases in the restricted repository sandbox (see README.md), so this
# script is the verified path there. Outputs go to .agent-local/swiftc-build (git-ignored).
# TEST_TIMEOUT bounds the Swift Testing run, in seconds (default 900). A run that exceeds it is stopped and fails.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/bounded.sh

DEV="${DEV:-/Library/Developer/CommandLineTools}"
SDK="${SDK:-$DEV/SDKs/MacOSX.sdk}"
FW="$DEV/Library/Developer/Frameworks"
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
INTEROP="$DEV/Library/Developer/usr/lib"
MANIFEST_API="$DEV/usr/lib/swift/pm/ManifestAPI"
OUT="$PWD/.agent-local/swiftc-build"
COMMON="-swift-version 6 -target arm64-apple-macosx14.0 -sdk $SDK -enable-testing"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "== manifest"
swiftc -typecheck -swift-version 6 -target arm64-apple-macosx14.0 -sdk "$SDK" \
  -I "$MANIFEST_API" -L "$MANIFEST_API" -lPackageDescription -package-description-version 6.0.0 Package.swift

echo "== MacFleetKit"
swiftc -emit-library -emit-module -parse-as-library -module-name MacFleetKit \
  -emit-module-path "$OUT/MacFleetKit.swiftmodule" -o "$OUT/libMacFleetKit.dylib" $COMMON -lsqlite3 -framework Metal \
  -Xlinker -install_name -Xlinker @rpath/libMacFleetKit.dylib $(find Sources/MacFleetKit -name '*.swift')

echo "== MacFleetState"
swiftc -emit-library -emit-module -parse-as-library -module-name MacFleetState -I "$OUT" \
  -emit-module-path "$OUT/MacFleetState.swiftmodule" -o "$OUT/libMacFleetState.dylib" $COMMON \
  -L "$OUT" -lMacFleetKit -Xlinker -install_name -Xlinker @rpath/libMacFleetState.dylib \
  $(find Sources/MacFleetState -name '*.swift')

echo "== MacFleetUI (typecheck)"
swiftc -typecheck -parse-as-library -module-name MacFleetUI -I "$OUT" $COMMON \
  $(find Sources/MacFleetUI -name '*.swift')

echo "== macfleet-agent"
swiftc -module-name macfleet_agent -I "$OUT" -L "$OUT" -lMacFleetKit $COMMON \
  -Xlinker -rpath -Xlinker "$OUT" -o "$OUT/macfleet-agent" Sources/MacFleetAgent/main.swift
run_bounded 120 "$OUT/macfleet-agent" > /dev/null

echo "== macfleet-headless"
swiftc -module-name macfleet_headless -I "$OUT" -L "$OUT" -lMacFleetKit $COMMON \
  -Xlinker -rpath -Xlinker "$OUT" -o "$OUT/macfleet-headless" Sources/MacFleetHeadless/main.swift

echo "== Swift Testing suites"
swiftc -module-name MacFleetTests -I "$OUT" -L "$OUT" -lMacFleetKit -lMacFleetState $COMMON \
  -F "$FW" -plugin-path "$PLUGINS" \
  -Xlinker -rpath -Xlinker "$OUT" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$INTEROP" \
  -o "$OUT/macfleet-tests" $(find Tests/MacFleetKitTests Tests/MacFleetStateTests -name '*.swift') \
  scripts/swiftc-test-runner/main.swift
run_bounded "${TEST_TIMEOUT:-900}" "$OUT/macfleet-tests"

echo "== headless process smoke"
sh scripts/headless-smoke.sh

echo "swiftc verification passed"
