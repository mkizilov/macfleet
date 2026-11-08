import Foundation

public protocol SystemMetricsProviding: Sendable {
    func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot

    /// Forget rate baselines, for example after the system wakes. Sources without baselines do nothing.
    func resetBaselines() async
}

extension SystemMetricsProviding {
    public func snapshot() async throws -> SystemSnapshot {
        try await snapshot(selection: .default)
    }

    public func resetBaselines() async {}
}

public enum MetricsError: Error, Equatable {
    case loadAverageUnavailable
}

extension MetricsError: LocalizedError {
    public var errorDescription: String? {
        "The system load averages could not be read."
    }
}
