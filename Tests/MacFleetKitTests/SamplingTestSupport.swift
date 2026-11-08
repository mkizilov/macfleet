import Foundation
import os
@testable import MacFleetKit

/// A scheduler whose virtual time moves only when a test advances it. The engine's loop waits on it, so the
/// tests see exact wait durations and control exactly when each wait ends. State sits behind a lock so that a
/// cancelled sleep is removed synchronously, and a test never observes a sleeper that is already cancelled.
final class ManualScheduler: Sendable {
    private struct Sleeper {
        let deadline: Double
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State: Sendable {
        var now = 0.0
        var sleepers: [UUID: Sleeper] = [:]
        var waiters: [CheckedContinuation<Void, Never>] = []
        var requested: [Double] = []
    }

    private enum Registration {
        case cancelled
        case registered([CheckedContinuation<Void, Never>])
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var scheduler: SamplingEngine.Scheduler {
        { duration in try await self.sleep(duration) }
    }

    var requested: [Double] {
        state.withLock { $0.requested }
    }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        let seconds = duration.totalSeconds
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registration = state.withLock { state -> Registration in
                    if Task.isCancelled {
                        return .cancelled
                    }
                    state.requested.append(seconds)
                    state.sleepers[id] = Sleeper(deadline: state.now + seconds, continuation: continuation)
                    let waiting = state.waiters
                    state.waiters = []
                    return .registered(waiting)
                }
                switch registration {
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case let .registered(waiting):
                    for waiter in waiting {
                        waiter.resume()
                    }
                }
            }
        } onCancel: {
            let sleeper = self.state.withLock { $0.sleepers.removeValue(forKey: id) }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: Double) {
        let due = state.withLock { state -> [Sleeper] in
            state.now += seconds
            let ready = state.sleepers.filter { $0.value.deadline <= state.now + 1e-9 }
            for id in ready.keys {
                state.sleepers.removeValue(forKey: id)
            }
            return Array(ready.values)
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Returns once the loop is waiting for time to pass.
    func waitUntilSleeping() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if !state.sleepers.isEmpty {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }
}

/// A system source that counts calls, tracks overlap, and can fail a fixed number of times first.
actor RecordingSystemProvider: SystemMetricsProviding {
    private(set) var calls = 0
    private(set) var resets = 0
    private(set) var peakConcurrency = 0
    private(set) var selections: [MonitoringSelection] = []
    private var active = 0
    private var failuresRemaining: Int
    private let yields: Int

    init(failures: Int = 0, yields: Int = 0) {
        failuresRemaining = failures
        self.yields = yields
    }

    func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        calls += 1
        active += 1
        peakConcurrency = max(peakConcurrency, active)
        defer { active -= 1 }
        selections.append(selection)
        for _ in 0..<yields {
            await Task.yield()
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw MetricsError.loadAverageUnavailable
        }
        return MockSystemMetricsProvider.sampleSnapshot
    }

    func resetBaselines() async {
        resets += 1
    }
}

/// Shared, thread-safe clock the tests move by hand.
final class ClockBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: TimeInterval(0))

    var now: TimeInterval {
        state.withLock { $0 }
    }

    func set(_ value: TimeInterval) {
        state.withLock { $0 = value }
    }
}
