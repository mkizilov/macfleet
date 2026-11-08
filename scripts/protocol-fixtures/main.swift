import Foundation
import MacFleetKit

// Writes the protocol 1.0 wire fixtures. scripts/update-protocol-fixtures.sh compiles this file with the catalog that the
// conformance tests also use, so the fixtures and the tests cannot disagree about the messages.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for entry in protocolFixtureCatalog() {
    let data = try RemoteCodec.encode(entry.message, version: RemoteProtocol.current)
    // A plain write: each file is replaced whole and the run is explicit. An atomic write stages a temporary file, which
    // the repository's sandbox does not permit here.
    try data.write(to: directory.appendingPathComponent("\(entry.name).json"))
    print("wrote \(entry.name).json (\(data.count) bytes)")
}
