import Foundation

public enum MetricIssue: Error, Codable, Equatable, Sendable {
    case notSampled
    case notMonitored
    case counterReset
    case noElapsedTicks
    case noElapsedTime
    case coreCountChanged(previous: Int, current: Int)
    case kernelCallFailed(call: String, code: Int32)
    case readFailed(resource: String, code: Int)
    case permissionDenied(resource: String)
    case notProvided(resource: String)
    case volumeDisconnected
    case unrecognizedPressureLevel(Int32)
    case inconsistentMemoryAccounting
    case inconsistentStorageCounters
    case timedOut
    /// No public API reports this measurement on this Mac or macOS version. The reason says why.
    case unsupported(reason: String)
    /// The measurement exists but needs access the user has not granted. The reason says what to grant.
    case permissionRestricted(reason: String)
}

extension MetricIssue: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSampled:
            "Waiting for a second sample"
        case .notMonitored:
            "Not monitored"
        case .counterReset:
            "Counters moved backwards; waiting for the next sample"
        case .noElapsedTicks:
            "No CPU time elapsed since the last sample"
        case .noElapsedTime:
            "No time elapsed since the last sample"
        case let .coreCountChanged(previous, current):
            "Core count changed from \(previous) to \(current)"
        case let .kernelCallFailed(call, code):
            "\(call) failed with code \(code)"
        case let .readFailed(resource, code):
            "\(resource) could not be read (code \(code))"
        case let .permissionDenied(resource):
            "Permission denied for \(resource)"
        case let .notProvided(resource):
            "\(resource) is not provided by this system"
        case .volumeDisconnected:
            "Volume is no longer mounted"
        case let .unrecognizedPressureLevel(level):
            "Unrecognized memory pressure level \(level)"
        case .inconsistentMemoryAccounting:
            "Memory counters are inconsistent"
        case .inconsistentStorageCounters:
            "Volume capacity counters are inconsistent"
        case .timedOut:
            "Sampling timed out"
        case let .unsupported(reason), let .permissionRestricted(reason):
            reason
        }
    }
}

public enum MetricReading<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case unavailable(MetricIssue)

    public var availableValue: Value? {
        if case let .available(value) = self { value } else { nil }
    }
}

extension MetricReading: Codable where Value: Codable {}
