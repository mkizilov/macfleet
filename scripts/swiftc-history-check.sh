#!/bin/sh
# Checks the history store's crash consistency (SIGKILL during writes) and measures its cost.
# Builds MacFleetKit with optimization and runs scripts/swiftc-history-check/main.swift.
# Outputs go to .agent-local and are removed on exit. TRIALS sets the number of kill trials (default 30).
set -eu
cd "$(dirname "$0")/.."

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
OUT="$PWD/.agent-local/swiftc-history-check"
COMMON="-swift-version 6 -target arm64-apple-macosx14.0 -sdk $SDK -O"
trap 'rm -rf "$OUT"' EXIT

rm -rf "$OUT"
mkdir -p "$OUT/data"

swiftc -emit-library -emit-module -parse-as-library -module-name MacFleetKit \
  -emit-module-path "$OUT/MacFleetKit.swiftmodule" -o "$OUT/libMacFleetKit.dylib" $COMMON -lsqlite3 \
  -enable-testing -Xlinker -install_name -Xlinker @rpath/libMacFleetKit.dylib $(find Sources/MacFleetKit -name '*.swift')

swiftc -module-name history_check -I "$OUT" -L "$OUT" -lMacFleetKit $COMMON -enable-testing \
  -Xlinker -rpath -Xlinker "$OUT" -o "$OUT/history-check" scripts/swiftc-history-check/main.swift

"$OUT/history-check" crash "$OUT/data" "${TRIALS:-30}"
"$OUT/history-check" benchmark "$OUT/data"
