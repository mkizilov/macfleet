import Foundation

/// Enumerates the GPUs Metal reports. Throws a `MetricIssue` when enumeration is refused or fails.
public protocol GPUInventorySource: Sendable {
    func devices() throws(MetricIssue) -> [GPUDescription]
}

/// One hardware measurement with a declared capability. A source that is not `supported` is never read, so a
/// measurement this Mac cannot report is never turned into a number.
public protocol HardwareMetricSource<Value>: Sendable {
    associatedtype Value: Equatable & Sendable

    var capability: MetricCapability { get }
    func read() throws(MetricIssue) -> Value
}

/// The system thermal state from `ProcessInfo`.
public struct ProcessThermalSource: HardwareMetricSource {
    public let capability = MetricCapability.supported

    public init() {}

    public func read() throws(MetricIssue) -> ThermalState {
        guard let state = ThermalState(ProcessInfo.processInfo.thermalState) else {
            throw .unsupported(reason: "macOS reported a thermal state this version of MacFleet does not recognize.")
        }
        return state
    }
}

/// A measurement with no public API on this Mac. It declares itself unavailable and is never read.
public struct UnavailableMetricSource<Value: Equatable & Sendable>: HardwareMetricSource {
    public let capability: MetricCapability
    private let reason: String

    public init(reason: String) {
        self.reason = reason
        capability = .unavailable(reason: reason)
    }

    public func read() throws(MetricIssue) -> Value {
        throw .unsupported(reason: reason)
    }
}
