import Foundation

public enum MetricIssue: Error, Codable, Equatable, Sendable {
    case notSampled
    case counterReset
    case noElapsedTicks
    case coreCountChanged(previous: Int, current: Int)
    case kernelCallFailed(call: String, code: Int32)
    case unrecognizedPressureLevel(Int32)
    case inconsistentMemoryAccounting
}

extension MetricIssue: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSampled:
            "Waiting for a second sample"
        case .counterReset:
            "CPU counters moved backwards; waiting for the next sample"
        case .noElapsedTicks:
            "No CPU time elapsed since the last sample"
        case let .coreCountChanged(previous, current):
            "Core count changed from \(previous) to \(current)"
        case let .kernelCallFailed(call, code):
            "\(call) failed with code \(code)"
        case let .unrecognizedPressureLevel(level):
            "Unrecognized memory pressure level \(level)"
        case .inconsistentMemoryAccounting:
            "Memory counters are inconsistent"
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
