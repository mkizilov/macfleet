import Foundation
import MacFleetKit

func run() async throws {
    let provider = ProcessSystemMetricsProvider()
    _ = try await provider.snapshot()
    try await Task.sleep(for: .seconds(2))
    let snapshot = try await provider.snapshot()
    FileHandle.standardOutput.write(try FleetWireFormat.encode(snapshot) + Data("\n".utf8))
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("macfleet-agent: \(error.localizedDescription)\n".utf8))
    exit(1)
}
