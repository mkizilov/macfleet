import Foundation

public protocol SystemMetricsProviding: Sendable {
    func snapshot() async throws -> SystemSnapshot
}

public enum MetricsError: Error, Equatable {
    case loadAverageUnavailable
}

extension MetricsError: LocalizedError {
    public var errorDescription: String? {
        "The system load averages could not be read."
    }
}
