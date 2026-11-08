import Foundation
import Testing
@testable import MacFleetKit

@Suite("Snapshot storage")
struct SnapshotStoreTests {
    private func snapshot(host: String) -> SystemSnapshot {
        SystemSnapshot(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hostName: host,
            operatingSystemVersion: "test",
            activeProcessorCount: 1,
            physicalMemoryBytes: 1,
            uptimeSeconds: 1,
            loadAverage: LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0)
        )
    }

    @Test func latestReturnsMostRecentlySavedSnapshot() async {
        let store = InMemorySnapshotStore(capacity: 2)
        for host in ["a", "b", "c"] {
            await store.save(snapshot(host: host))
        }
        let latest = await store.latest()
        #expect(latest?.hostName == "c")
    }

    @Test func emptyStoreHasNoLatestSnapshot() async {
        let latest = await InMemorySnapshotStore().latest()
        #expect(latest == nil)
    }
}

@Suite("Fleet wire format")
struct FleetWireFormatTests {
    @Test func encodedSnapshotRoundTrips() throws {
        let original = MockSystemMetricsProvider.sampleSnapshot
        let data = try FleetWireFormat.encode(original)
        let decoded = try FleetWireFormat.decode(data)
        #expect(decoded == original)
    }
}
