import os

/// Scripted process listings for tests and previews. Each call takes the next scripted listing; once one entry is
/// left, that entry repeats. It counts its calls, so tests can prove when sampling happens.
public final class MockProcessInventory: ProcessInventorySource, Sendable {
    private let script: [Result<[ProcessListing], MetricIssue>]
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    public init(_ script: [Result<[ProcessListing], MetricIssue>]) {
        precondition(!script.isEmpty, "a mock process inventory needs at least one scripted listing")
        self.script = script
    }

    public var callCount: Int {
        calls.withLock { $0 }
    }

    public func listing() throws(MetricIssue) -> [ProcessListing] {
        let index = calls.withLock { count -> Int in
            defer { count += 1 }
            return min(count, script.count - 1)
        }
        switch script[index] {
        case let .success(listings):
            return listings
        case let .failure(issue):
            throw issue
        }
    }
}
