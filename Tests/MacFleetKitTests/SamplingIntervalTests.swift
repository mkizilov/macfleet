import Foundation
import Testing
@testable import MacFleetKit

@Suite("Awake monotonic time")
struct MonotonicTimeTests {
    @Test func neverGoesBackwardsAndAdvancesWithRealTime() async throws {
        let first = MonotonicTime.awakeSeconds()
        try await Task.sleep(for: .milliseconds(20))
        let second = MonotonicTime.awakeSeconds()
        #expect(second >= first + 0.015)
    }

    @Test func durationsConvertToSecondsAndBack() {
        #expect(Duration.fromSeconds(2.5).totalSeconds == 2.5)
        #expect(Duration.milliseconds(1_250).totalSeconds == 1.25)
    }
}

@Suite("Sampling interval")
struct SamplingIntervalValueTests {
    @Test func intervalRoundTripsThroughDuration() {
        #expect(SamplingInterval(duration: .seconds(10)).seconds == 10)
        #expect(SamplingInterval(seconds: 2).duration == .seconds(2))
    }

    @Test func presetsMatchTheDocumentedCadences() {
        #expect(SamplingInterval.interactive.seconds == 2)
        #expect(SamplingInterval.background.seconds == 10)
    }
}
