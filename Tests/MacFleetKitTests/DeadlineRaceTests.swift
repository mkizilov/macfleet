import Foundation
import Testing
@testable import MacFleetKit

/// Records that abandoned work saw its cancellation.
private actor DeadlineProbe {
    private(set) var sawCancellation = false

    func noteCancellation() {
        sawCancellation = true
    }
}

/// The race behind every collection deadline. A section or a provider that misses its deadline must not hold the caller,
/// even when it ignores cancellation, because AGENTS.md forbids waiting on a provider without a deadline.
@Suite("Deadline race")
struct DeadlineRaceTests {
    @Test func workThatFinishesInTimeReturnsItsValue() async {
        let outcome = await raceAgainstDeadline(.seconds(5)) { 42 }
        #expect(outcome == .finished(42))
    }

    @Test func workThatIgnoresCancellationStillReturnsOnTheDeadline() async {
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await raceAgainstDeadline(.milliseconds(100)) { () -> Int in
            // usleep does not respond to cancellation. The caller must not wait for it.
            usleep(1_500_000)
            return 1
        }
        let elapsed = start.duration(to: clock.now)
        #expect(outcome == .timedOut)
        #expect(elapsed < .seconds(1), "the deadline held the caller for \(elapsed)")
    }

    @Test func timedOutWorkIsCancelled() async throws {
        let probe = DeadlineProbe()
        let outcome = await raceAgainstDeadline(.milliseconds(50)) { () -> Int in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                await probe.noteCancellation()
            }
            return 0
        }
        #expect(outcome == .timedOut)
        for _ in 0..<200 {
            if await probe.sawCancellation {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.sawCancellation)
    }

    @Test func aLateResultNeverReplacesTheTimeout() async {
        let outcome = await raceAgainstDeadline(.milliseconds(30)) { () -> Int in
            try? await Task.sleep(for: .milliseconds(200))
            return 9
        }
        #expect(outcome == .timedOut)
    }
}
