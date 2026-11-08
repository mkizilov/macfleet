import Foundation
import Testing
@testable import MacFleetKit

@Suite("System metrics")
struct MetricsTests {
    @Test func processProviderReportsPlausibleValues() async throws {
        let snapshot = try await ProcessSystemMetricsProvider().snapshot()
        #expect(snapshot.activeProcessorCount > 0)
        #expect(snapshot.physicalMemoryBytes > 0)
        #expect(snapshot.uptimeSeconds > 0)
        #expect(snapshot.loadAverage.oneMinute >= 0)
        #expect(!snapshot.hostName.isEmpty)
    }

    @Test func mockProviderReturnsConfiguredSnapshot() async throws {
        let provider = MockSystemMetricsProvider()
        let snapshot = try await provider.snapshot()
        #expect(snapshot == MockSystemMetricsProvider.sampleSnapshot)
    }

    @Test func mockProviderPropagatesConfiguredErrors() async {
        let provider = MockSystemMetricsProvider(result: .failure(MetricsError.loadAverageUnavailable))
        await #expect(throws: MetricsError.loadAverageUnavailable) {
            try await provider.snapshot()
        }
    }
}
