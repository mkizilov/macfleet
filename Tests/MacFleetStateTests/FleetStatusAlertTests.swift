import Foundation
import MacFleetKit
import MacFleetState
import Testing

/// Serves a fixed stream of synthetic snapshots, one per collection, and then repeats the last one.
private actor SyntheticStreamProvider: SystemMetricsProviding {
    private let snapshots: [SystemSnapshot]
    private var next = 0

    init(_ snapshots: [SystemSnapshot]) {
        self.snapshots = snapshots
    }

    func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        let index = min(next, snapshots.count - 1)
        next += 1
        return snapshots[index]
    }
}

private func cpuSnapshot(at seconds: Double, cpu: Double) -> SystemSnapshot {
    SystemSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(seconds),
        hostName: "test-mac",
        operatingSystemVersion: "test",
        activeProcessorCount: 8,
        physicalMemoryBytes: 1,
        uptimeSeconds: 1,
        loadAverage: LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0),
        cpu: .available(CPUUtilization(total: cpu, perCore: .unavailable(.notSampled)))
    )
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("Alerts through the status model")
struct FleetStatusAlertTests {
    @Test func aSustainedBreachReachesTheNotifierThroughEveryCollection() async throws {
        let samples = (0...20).map { cpuSnapshot(at: Double($0) * 2, cpu: 0.95) }
        let notifier = RecordingAlertNotifier(permission: .authorized)
        let alerts = AlertCenterModel(notifier: notifier, store: MemoryAlertSettingsStore())
        let model = FleetStatusModel(
            engine: SamplingEngine(provider: SyntheticStreamProvider(samples), store: InMemorySnapshotStore()),
            alerts: alerts
        )

        for _ in samples {
            await model.refresh()
        }

        try await waitUntil { notifier.delivered.count == 1 }
        #expect(notifier.delivered.map(\.title) == ["High CPU use"])
        #expect(model.snapshot == samples.last)
    }

    @Test func aStatusModelWithoutAlertsStillSamples() async {
        let model = FleetStatusModel(
            engine: SamplingEngine(provider: SyntheticStreamProvider([cpuSnapshot(at: 0, cpu: 0.95)]), store: InMemorySnapshotStore())
        )
        await model.refresh()
        #expect(model.snapshot != nil)
    }
}
