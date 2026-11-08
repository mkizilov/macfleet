import MacFleetKit
import Observation

@MainActor
@Observable
public final class FleetStatusModel {
    public private(set) var snapshot: SystemSnapshot?
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false

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
            let snapshot = try await provider.snapshot()
            await store.save(snapshot)
            self.snapshot = snapshot
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
