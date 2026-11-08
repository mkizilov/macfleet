#!/bin/sh
# Measures per-sample dashboard work (history update and presentation build) in optimized builds.
# Compiles with swiftc, like scripts/swiftc-verify.sh. Outputs are removed on exit.
set -eu
cd "$(dirname "$0")/.."

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
OUT="$PWD/.agent-local/swiftc-benchmark"
COMMON="-swift-version 6 -target arm64-apple-macosx14.0 -sdk $SDK -O"
trap 'rm -rf "$OUT"' EXIT

rm -rf "$OUT"
mkdir -p "$OUT"

swiftc -emit-library -emit-module -parse-as-library -module-name MacFleetKit \
  -emit-module-path "$OUT/MacFleetKit.swiftmodule" -o "$OUT/libMacFleetKit.dylib" $COMMON \
  -Xlinker -install_name -Xlinker @rpath/libMacFleetKit.dylib $(find Sources/MacFleetKit -name '*.swift')

swiftc -emit-library -emit-module -parse-as-library -module-name MacFleetState -I "$OUT" \
  -emit-module-path "$OUT/MacFleetState.swiftmodule" -o "$OUT/libMacFleetState.dylib" $COMMON \
  -L "$OUT" -lMacFleetKit -Xlinker -install_name -Xlinker @rpath/libMacFleetState.dylib \
  $(find Sources/MacFleetState -name '*.swift')

swiftc -module-name dashboard_benchmark -I "$OUT" -L "$OUT" -lMacFleetKit -lMacFleetState $COMMON \
  -Xlinker -rpath -Xlinker "$OUT" -o "$OUT/dashboard-benchmark" scripts/swiftc-benchmark/main.swift

"$OUT/dashboard-benchmark"
