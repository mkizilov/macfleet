import Foundation

/// Everything one collection needs. The engine creates one per collection, so every section of a snapshot
/// shares the same timestamps and selection.
public struct SampleContext: Equatable, Sendable {
    /// Wall-clock time, for display.
    public let wallClock: Date
    /// Awake monotonic seconds, for rates. See `MonotonicTime`.
    public let monotonicSeconds: TimeInterval
    public let selection: MonitoringSelection

    public init(wallClock: Date, monotonicSeconds: TimeInterval, selection: MonitoringSelection) {
        self.wallClock = wallClock
        self.monotonicSeconds = monotonicSeconds
        self.selection = selection
    }
}

/// One independent section of a snapshot. Providers never throw: a failure becomes an explicit
/// `.unavailable` reading that affects only this section.
public protocol MetricProvider<Output>: Sendable {
    associatedtype Output: Equatable & Sendable

    func sample(_ context: SampleContext) async -> MetricReading<Output>

    /// Forget any rate baseline, for example after the system wakes. Stateless providers do nothing.
    func resetBaselines() async
}

extension MetricProvider {
    public func resetBaselines() async {}
}

/// Runs a read that can fail with a `MetricIssue`, returning the outcome as a reading.
func metricReading<Value: Equatable & Sendable>(
    _ read: () throws(MetricIssue) -> Value
) -> MetricReading<Value> {
    do throws(MetricIssue) {
        return .available(try read())
    } catch {
        return .unavailable(error)
    }
}
