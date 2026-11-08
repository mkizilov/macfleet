import MacFleetKit
import MacFleetState
import Testing

@MainActor
@Suite("Fleet status model")
struct FleetStatusModelTests {
    @Test func refreshPublishesAndStoresSnapshot() async {
        let store = InMemorySnapshotStore()
        let sample = MockSystemMetricsProvider.sampleSnapshot
        let model = FleetStatusModel(
            provider: MockSystemMetricsProvider(result: .success(sample)),
            store: store
        )

        await model.refresh()

        #expect(model.snapshot == sample)
        #expect(model.errorMessage == nil)
        #expect(!model.isRefreshing)
        let stored = await store.latest()
        #expect(stored == sample)
    }

    @Test func refreshSurfacesProviderErrors() async {
        let model = FleetStatusModel(
            provider: MockSystemMetricsProvider(result: .failure(MetricsError.loadAverageUnavailable)),
            store: InMemorySnapshotStore()
        )

        await model.refresh()

        #expect(model.snapshot == nil)
        #expect(model.errorMessage == MetricsError.loadAverageUnavailable.errorDescription)
    }
}

private actor CountingProvider: SystemMetricsProviding {
    private(set) var calls = 0

    func snapshot() async throws -> SystemSnapshot {
        calls += 1
        return MockSystemMetricsProvider.sampleSnapshot
    }
}

@MainActor
@Suite("Fleet status sampling loop")
struct FleetStatusSamplingTests {
    @Test func samplingRefreshesUntilCancelled() async throws {
        let provider = CountingProvider()
        let model = FleetStatusModel(provider: provider, store: InMemorySnapshotStore())

        let task = Task { await model.runSampling(every: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await task.value

        let calls = await provider.calls
        #expect(calls >= 1)
        #expect(model.snapshot == MockSystemMetricsProvider.sampleSnapshot)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await provider.calls == calls)
    }
}
