import MacFleetKit
import Observation

@MainActor
@Observable
public final class FleetStatusModel {
    public private(set) var snapshot: SystemSnapshot?
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false
    public private(set) var selection = MonitoringSelection.default

    private let provider: any SystemMetricsProviding
    private let store: any SnapshotStoring

    public init(provider: any SystemMetricsProviding, store: any SnapshotStoring) {
        self.provider = provider
        self.store = store
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await provider.snapshot(selection: selection)
            await store.save(snapshot)
            self.snapshot = snapshot
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes every `interval` until the calling task is cancelled.
    public func runSampling(every interval: Duration) async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    public func setVolumeMonitored(_ mountPoint: String, _ monitored: Bool) async {
        selection.setVolume(at: mountPoint, monitored: monitored)
        await refresh()
    }

    public func setInterfaceMonitored(_ name: String, _ monitored: Bool) async {
        selection.setInterface(named: name, monitored: monitored)
        await refresh()
    }
}
