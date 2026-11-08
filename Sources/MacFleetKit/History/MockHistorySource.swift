import Foundation

/// Realistic history for previews and tests, built from the same simulated timeline as the live dashboard.
/// Nothing here reads storage or the system.
public struct MockHistorySource: HistorySource {
    private let seed: UInt64
    private let failure: HistoryError?

    public init(seed: UInt64 = 42, failure: HistoryError? = nil) {
        self.seed = seed
        self.failure = failure
    }

    public func series(range: HistoryRange, now: Date) async throws -> HistorySeries {
        if let failure {
            throw failure
        }
        return Self.makeSeries(range: range, now: now, seed: seed)
    }

    public func notice() async -> String? {
        nil
    }

    /// One simulated snapshot per slot, so the series has the same shape a real one would.
    public static func makeSeries(range: HistoryRange, now: Date, seed: UInt64 = 42) -> HistorySeries {
        var timeline = SimulatedMetricsTimeline(seed: seed)
        let window = HistorySeries.window(range: range, now: now)
        let points = (0..<range.slotCount).map { index -> HistoryPoint in
            let capturedAt = Date(timeIntervalSince1970: window.start + Double(index) * range.slotWidth)
            return HistoryPoint(snapshot: timeline.nextSnapshot(selection: .default, capturedAt: capturedAt))
        }
        return HistorySeries.build(range: range, start: window.start, end: window.end, points: points)
    }
}
