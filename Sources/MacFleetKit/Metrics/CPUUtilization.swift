import Foundation

/// Cumulative tick counters for one CPU (or all CPUs), as reported by the Mach host APIs.
public struct CPUTicks: Equatable, Sendable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Utilization as fractions in 0...1. `perCore` carries its own reading so one failing
/// per-core call does not hide the total.
public struct CPUUtilization: Codable, Equatable, Sendable {
    public let total: Double
    public let perCore: MetricReading<[Double]>

    public init(total: Double, perCore: MetricReading<[Double]>) {
        self.total = total
        self.perCore = perCore
    }
}

enum CPUUtilizationCalculator {
    /// Counters are 32-bit and wrap. A delta of 2^31 or more cannot come from a normal sampling
    /// interval, so it means the counter moved backwards rather than wrapped.
    private static let resetThreshold: UInt32 = 1 << 31

    static func utilization(previous: CPUTicks, current: CPUTicks) throws(MetricIssue) -> Double {
        let busy = try delta(current.user, previous.user)
            + delta(current.system, previous.system)
            + delta(current.nice, previous.nice)
        let idle = try delta(current.idle, previous.idle)
        let total = busy + idle
        guard total > 0 else { throw .noElapsedTicks }
        return Double(busy) / Double(total)
    }

    static func utilization(previous: [CPUTicks], current: [CPUTicks]) throws(MetricIssue) -> [Double] {
        guard previous.count == current.count else {
            throw .coreCountChanged(previous: previous.count, current: current.count)
        }
        var result: [Double] = []
        result.reserveCapacity(current.count)
        for (before, now) in zip(previous, current) {
            result.append(try utilization(previous: before, current: now))
        }
        return result
    }

    private static func delta(_ current: UInt32, _ previous: UInt32) throws(MetricIssue) -> UInt64 {
        let difference = current &- previous
        guard difference < resetThreshold else { throw .counterReset }
        return UInt64(difference)
    }
}

/// Turns cumulative counters into utilization over the window since the previous accepted reading.
struct CPUUtilizationTracker: Sendable {
    private struct Baseline: Sendable {
        let timestamp: TimeInterval
        let total: CPUTicks
        let perCore: MetricReading<[CPUTicks]>
    }

    private let minimumWindow: TimeInterval
    private var baseline: Baseline?
    private var lastReading: MetricReading<CPUUtilization> = .unavailable(.notSampled)

    init(minimumWindow: TimeInterval) {
        self.minimumWindow = minimumWindow
    }

    /// Readings closer than `minimumWindow` repeat the last result and leave the baseline in place,
    /// so a short window never produces a percentage from only a few ticks. The kernel publishes CPU
    /// ticks in batches about once a second, so a window can see none; that reading reports
    /// `.noElapsedTicks` and keeps the baseline, letting the next reading span the full interval.
    mutating func record(
        at timestamp: TimeInterval,
        total: MetricReading<CPUTicks>,
        perCore: MetricReading<[CPUTicks]>
    ) -> MetricReading<CPUUtilization> {
        let current: CPUTicks
        switch total {
        case let .available(ticks):
            current = ticks
        case let .unavailable(issue):
            return .unavailable(issue)
        }
        guard let previous = baseline else {
            baseline = Baseline(timestamp: timestamp, total: current, perCore: perCore)
            return lastReading
        }
        guard timestamp - previous.timestamp >= minimumWindow else { return lastReading }
        let reading = Self.reading(from: previous, total: current, perCore: perCore)
        if case .unavailable(.noElapsedTicks) = reading {
            return reading
        }
        baseline = Baseline(timestamp: timestamp, total: current, perCore: perCore)
        lastReading = reading
        return lastReading
    }

    private static func reading(
        from previous: Baseline,
        total: CPUTicks,
        perCore: MetricReading<[CPUTicks]>
    ) -> MetricReading<CPUUtilization> {
        do throws(MetricIssue) {
            let overall = try CPUUtilizationCalculator.utilization(previous: previous.total, current: total)
            let cores = coreReading(previous: previous.perCore, current: perCore)
            return .available(CPUUtilization(total: overall, perCore: cores))
        } catch {
            return .unavailable(error)
        }
    }

    private static func coreReading(
        previous: MetricReading<[CPUTicks]>,
        current: MetricReading<[CPUTicks]>
    ) -> MetricReading<[Double]> {
        switch (previous, current) {
        case let (.available(before), .available(now)):
            do throws(MetricIssue) {
                return .available(try CPUUtilizationCalculator.utilization(previous: before, current: now))
            } catch {
                return .unavailable(error)
            }
        case let (.unavailable(issue), _), let (_, .unavailable(issue)):
            return .unavailable(issue)
        }
    }
}
