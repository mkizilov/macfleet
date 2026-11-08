import MacFleetKit
import Observation

@MainActor
@Observable
public final class FleetStatusModel {
    public private(set) var snapshot: SystemSnapshot?
    public private(set) var dashboard: DashboardPresentation?
    public private(set) var history: MetricHistory
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false
    public private(set) var selection = MonitoringSelection.default
    /// Expanded or collapsed popover. Held here, not in a view, so views stay free of property wrappers.
    public var isShowingDetails = false

    private let provider: any SystemMetricsProviding
    private let store: any SnapshotStoring

    public init(provider: any SystemMetricsProviding, store: any SnapshotStoring, historyCapacity: Int = 120) {
        self.provider = provider
        self.store = store
        history = MetricHistory(capacity: historyCapacity)
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await provider.snapshot(selection: selection)
            await store.save(snapshot)
            self.snapshot = snapshot
            history.record(snapshot)
            errorMessage = nil
            rebuildDashboard()
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
        rebuildDashboard()
        await refresh()
    }

    public func setInterfaceMonitored(_ name: String, _ monitored: Bool) async {
        selection.setInterface(named: name, monitored: monitored)
        rebuildDashboard()
        await refresh()
    }

    private func rebuildDashboard() {
        guard let snapshot else { return }
        dashboard = DashboardPresentation(snapshot: snapshot, history: history, selection: selection)
    }
}
