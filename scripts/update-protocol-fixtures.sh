#!/bin/sh
# Regenerates the protocol 1.0 wire fixtures from the codec. Run it only when a wire change is intended, and review the
# diff: a changed fixture changes what every peer must agree on. ProtocolConformanceTests fails until the fixtures match.
set -eu
cd "$(dirname "$0")/.."

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
WORK="$PWD/.agent-local/protocol-fixtures"
COMMON="-swift-version 6 -target arm64-apple-macosx14.0 -sdk $SDK -O"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

swiftc -emit-library -emit-module -parse-as-library -module-name MacFleetKit \
  -emit-module-path "$WORK/MacFleetKit.swiftmodule" -o "$WORK/libMacFleetKit.dylib" $COMMON -lsqlite3 \
  -Xlinker -install_name -Xlinker @rpath/libMacFleetKit.dylib $(find Sources/MacFleetKit -name '*.swift')
swiftc -module-name protocol_fixtures -I "$WORK" -L "$WORK" -lMacFleetKit $COMMON \
  -Xlinker -rpath -Xlinker "$WORK" -o "$WORK/protocol-fixtures" \
  scripts/protocol-fixtures/main.swift Tests/MacFleetKitTests/ProtocolFixtureCatalog.swift
"$WORK/protocol-fixtures" "$PWD/Tests/MacFleetKitTests/Fixtures/protocol-1.0"
echo "fixtures written. Review the diff before committing it."
