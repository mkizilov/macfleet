import Foundation

/// What the presentation layer needs from persisted history. Keeping it a protocol lets the state layer use
/// a fake in tests and lets the UI never touch storage directly.
public protocol HistorySource: Sendable {
    /// Chart data for a range, ending at `now`.
    func series(range: HistoryRange, now: Date) async throws -> HistorySeries

    /// A message the user should see about storage, or nil when storage is healthy.
    func notice() async -> String?
}
