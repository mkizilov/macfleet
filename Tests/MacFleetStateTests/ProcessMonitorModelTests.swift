import Foundation
import MacFleetKit
import MacFleetState
import Testing

private func makeListing(_ pid: Int32, _ name: String, memory: UInt64) -> ProcessListing {
    ProcessListing(
        pid: pid,
        name: name,
        outcome: .readable(ProcessCounters(startMicroseconds: 1_000_000, cpuNanoseconds: 0, footprintBytes: memory))
    )
}

/// Polls until the condition holds, so a test waits for a watch loop to run without assuming an exact timing.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("Process monitor model: sampling")
struct ProcessMonitorModelSamplingTests {
    private func makeModel(
        _ script: [Result<[ProcessListing], MetricIssue>],
        interval: Duration = .seconds(60)
    ) -> (model: ProcessMonitorModel, inventory: MockProcessInventory) {
        let inventory = MockProcessInventory(script)
        let monitor = ProcessMonitor(source: inventory)
        return (ProcessMonitorModel(monitor: monitor, interval: interval), inventory)
    }

    @Test func refreshBuildsThePresentationFromOneSample() async {
        let (model, inventory) = makeModel([
            .success([makeListing(1, "Safari", memory: 100), makeListing(2, "Terminal", memory: 300)]),
        ])

        await model.refresh()

        #expect(model.presentation.rows.map(\.pidText) == ["PID 1", "PID 2"])
        #expect(inventory.callCount == 1)
    }

    @Test func sortingSearchingAndGroupingRebuildFromTheLastSampleWithoutSampling() async {
        let (model, inventory) = makeModel([
            .success([makeListing(1, "Safari", memory: 100), makeListing(2, "Terminal", memory: 300)]),
        ])
        await model.refresh()

        model.setSort(.memory)
        #expect(model.presentation.rows.map(\.pidText) == ["PID 2", "PID 1"])

        model.setSearchText("saf")
        #expect(model.searchText == "saf")
        #expect(model.presentation.rows.map(\.pidText) == ["PID 1"])

        model.setMode(.apps)
        #expect(model.presentation.groups.map(\.title) == ["Safari"])
        #expect(inventory.callCount == 1)
    }

    @Test func watchingSamplesWhileOpenAndStopsWhenClosed() async throws {
        let (model, inventory) = makeModel(
            [.success([makeListing(1, "Safari", memory: 100)])],
            interval: .milliseconds(5)
        )

        model.processesDidAppear()
        model.processesDidAppear()
        try await waitUntil { inventory.callCount >= 3 }
        #expect(inventory.callCount >= 3)
        #expect(model.presentation.rows.count == 1)

        await model.processesDidDisappear()
        let stoppedAt = inventory.callCount
        try await Task.sleep(for: .milliseconds(40))
        #expect(inventory.callCount == stoppedAt)
    }
}
