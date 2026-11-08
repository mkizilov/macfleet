import Foundation
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
    private(set) var selections: [MonitoringSelection] = []

    func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        calls += 1
        selections.append(selection)
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

@MainActor
@Suite("Monitoring selection in the model")
struct FleetStatusSelectionTests {
    @Test func defaultSelectionExcludesLoopback() {
        let model = FleetStatusModel(provider: MockSystemMetricsProvider(), store: InMemorySnapshotStore())
        #expect(model.selection == .default)
        #expect(!model.selection.monitorsInterface(named: "lo0"))
        #expect(model.selection.monitorsInterface(named: "en0"))
    }

    @Test func togglingAnInterfaceUpdatesSelectionAndRefreshesWithIt() async {
        let provider = CountingProvider()
        let model = FleetStatusModel(provider: provider, store: InMemorySnapshotStore())

        await model.setInterfaceMonitored("en0", false)
        #expect(!model.selection.monitorsInterface(named: "en0"))
        let excluded = await provider.selections.last
        #expect(excluded?.excludedInterfaceNames.contains("en0") == true)

        await model.setInterfaceMonitored("en0", true)
        #expect(model.selection.monitorsInterface(named: "en0"))
        let restored = await provider.selections.last
        #expect(restored?.excludedInterfaceNames.contains("en0") == false)
    }

    @Test func togglingAVolumeRefreshesWithTheVolumeExcluded() async {
        let provider = CountingProvider()
        let model = FleetStatusModel(provider: provider, store: InMemorySnapshotStore())

        await model.setVolumeMonitored("/Volumes/USB", false)

        #expect(!model.selection.monitorsVolume(at: "/Volumes/USB"))
        let latest = await provider.selections.last
        #expect(latest?.excludedVolumePaths == ["/Volumes/USB"])
    }
}

@MainActor
@Suite("Dashboard state in the model")
struct FleetStatusDashboardTests {
    @Test func refreshBuildsDashboardAndHistory() async {
        let model = FleetStatusModel(provider: MockSystemMetricsProvider(), store: InMemorySnapshotStore())
        #expect(model.dashboard == nil)

        await model.refresh()
        await model.refresh()

        #expect(model.dashboard != nil)
        #expect(model.history.cpu.samples.count == 2)
        #expect(model.dashboard?.menuBar.cpuText == "25%")
    }

    @Test func historyCapacityIsRespected() async {
        let model = FleetStatusModel(
            provider: MockSystemMetricsProvider(),
            store: InMemorySnapshotStore(),
            historyCapacity: 2
        )
        for _ in 0..<5 {
            await model.refresh()
        }
        #expect(model.history.cpu.samples.count == 2)
        #expect(model.history.download.samples.count == 2)
    }

    @Test func togglingASourceRebuildsThePresentationImmediately() async {
        let provider = SimulatedSystemMetricsProvider(seed: 42, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let model = FleetStatusModel(provider: provider, store: InMemorySnapshotStore())
        await model.refresh()
        #expect(model.dashboard?.network.interfaces.availableValue?.contains { $0.id == "en0" } == true)

        await model.setInterfaceMonitored("en0", false)

        let en0 = model.dashboard?.sources.interfaces.availableValue?.first { $0.id == "en0" }
        #expect(en0?.monitored == false)
        #expect(model.dashboard?.network.interfaces.availableValue?.contains { $0.id == "en0" } == false)
    }

    @Test func detailsStateIsHeldByTheModel() {
        let model = FleetStatusModel(provider: MockSystemMetricsProvider(), store: InMemorySnapshotStore())
        #expect(model.isShowingDetails == false)
        model.isShowingDetails.toggle()
        #expect(model.isShowingDetails)
    }
}
