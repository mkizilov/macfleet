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
