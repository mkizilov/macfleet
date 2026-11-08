import Foundation

/// Monotonic time that does not advance while the system sleeps. Rates are computed on this clock, so a
/// measurement window never averages across a sleep.
public enum MonotonicTime {
    private static let origin = SuspendingClock().now

    /// Seconds of awake time since first use.
    public static func awakeSeconds() -> TimeInterval {
        origin.duration(to: SuspendingClock().now).totalSeconds
    }
}

extension Duration {
    var totalSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    static func fromSeconds(_ seconds: Double) -> Duration {
        .milliseconds(Int64((seconds * 1_000).rounded()))
    }
}

/// How often a consumer wants fresh samples. Clamped so no consumer can spin the CPU or wait for hours.
public struct SamplingInterval: Equatable, Comparable, Sendable {
    public static let minimumSeconds = 0.5
    public static let maximumSeconds = 3_600.0
    /// Popover open.
    public static let interactive = SamplingInterval(seconds: 2)
    /// Menu bar only, popover closed.
    public static let background = SamplingInterval(seconds: 10)

    public let seconds: Double

    public init(seconds: Double) {
        let finite = seconds.isFinite ? seconds : Self.minimumSeconds
        self.seconds = min(max(finite, Self.minimumSeconds), Self.maximumSeconds)
    }

    public init(duration: Duration) {
        self.init(seconds: duration.totalSeconds)
    }

    public var duration: Duration {
        .fromSeconds(seconds)
    }

    public static func < (lhs: SamplingInterval, rhs: SamplingInterval) -> Bool {
        lhs.seconds < rhs.seconds
    }
}
