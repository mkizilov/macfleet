import Foundation

public protocol SystemMetricsProviding: Sendable {
    func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot
}

extension SystemMetricsProviding {
    public func snapshot() async throws -> SystemSnapshot {
        try await snapshot(selection: .default)
    }
}

public enum MetricsError: Error, Equatable {
    case loadAverageUnavailable
}

extension MetricsError: LocalizedError {
    public var errorDescription: String? {
        "The system load averages could not be read."
    }
}
