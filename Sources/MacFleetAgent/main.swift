import Foundation
import MacFleetKit

func run() async throws {
    let snapshot = try await ProcessSystemMetricsProvider().snapshot()
    FileHandle.standardOutput.write(try FleetWireFormat.encode(snapshot) + Data("\n".utf8))
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("macfleet-agent: \(error.localizedDescription)\n".utf8))
    exit(1)
}
