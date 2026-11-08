import Testing
@testable import MacFleetKit

private func totals(_ received: UInt64, _ sent: UInt64) -> NetworkTotals {
    NetworkTotals(bytesReceived: received, bytesSent: sent)
}

@Suite("Network rate calculation")
struct NetworkRateCalculatorTests {
    @Test func rateIsDeltaOverElapsedSeconds() throws {
        let rate = try NetworkRateCalculator.rate(previous: totals(1_000, 500), current: totals(3_000, 1_500), elapsed: 2)
        #expect(rate == NetworkRate(receivedPerSecond: 1_000, sentPerSecond: 500))
    }

    @Test func sixtyFourBitCountersAboveThirtyTwoBitsAreExact() throws {
        let previous = totals(5_000_000_000, 0)
        let current = totals(9_000_000_000, 4_294_967_296)
        let rate = try NetworkRateCalculator.rate(previous: previous, current: current, elapsed: 4)
        #expect(rate.receivedPerSecond == 1_000_000_000)
        #expect(rate.sentPerSecond == 1_073_741_824)
    }

    @Test func unchangedCountersGiveZeroRate() throws {
        let sample = totals(42, 7)
        let rate = try NetworkRateCalculator.rate(previous: sample, current: sample, elapsed: 1)
        #expect(rate == NetworkRate(receivedPerSecond: 0, sentPerSecond: 0))
    }

    @Test func zeroElapsedTimeIsAnError() {
        #expect(throws: MetricIssue.noElapsedTime) {
            try NetworkRateCalculator.rate(previous: totals(1, 1), current: totals(2, 2), elapsed: 0)
        }
    }

    @Test func backwardsReceiveCounterIsAReset() {
        #expect(throws: MetricIssue.counterReset) {
            try NetworkRateCalculator.rate(previous: totals(100, 0), current: totals(50, 0), elapsed: 1)
        }
    }

    @Test func backwardsSendCounterIsAReset() {
        #expect(throws: MetricIssue.counterReset) {
            try NetworkRateCalculator.rate(previous: totals(0, 100), current: totals(0, 99), elapsed: 1)
        }
    }
}

@Suite("Network rate tracker")
struct NetworkRateTrackerTests {
    private func available(_ received: UInt64, _ sent: UInt64) -> MetricReading<NetworkTotals> {
        .available(totals(received, sent))
    }

    @Test func firstSampleHasNoBaseline() {
        var tracker = NetworkRateTracker(minimumWindow: 1)
        let readings = tracker.record(at: 0, totals: ["en0": available(1_000, 500)])
        #expect(readings["en0"] == .unavailable(.notSampled))
    }

    @Test func secondSampleComputesRatesOverTheWindow() throws {
        var tracker = NetworkRateTracker(minimumWindow: 1)
        _ = tracker.record(at: 0, totals: ["en0": available(1_000, 500)])
        let readings = tracker.record(at: 2, totals: ["en0": available(3_000, 1_500)])
        let rate = try #require(readings["en0"]?.availableValue)
        #expect(rate == NetworkRate(receivedPerSecond: 1_000, sentPerSecond: 500))
    }

    @Test func shortWindowRepeatsLastRateAndKeepsBaseline() throws {
        var tracker = NetworkRateTracker(minimumWindow: 1)
        _ = tracker.record(at: 0, totals: ["en0": available(0, 0)])
        _ = tracker.record(at: 2, totals: ["en0": available(2_000, 0)])

        let short = tracker.record(at: 2.5, totals: ["en0": available(9_000, 0)])
        #expect(short["en0"]?.availableValue == NetworkRate(receivedPerSecond: 1_000, sentPerSecond: 0))

        let next = tracker.record(at: 4, totals: ["en0": available(4_000, 0)])
        let rate = try #require(next["en0"]?.availableValue)
        #expect(rate.receivedPerSecond == 1_000)
    }

    @Test func newInterfaceWaitsForItsOwnBaseline() throws {
        var tracker = NetworkRateTracker(minimumWindow: 0)
        _ = tracker.record(at: 0, totals: ["en0": available(0, 0)])
        let readings = tracker.record(at: 1, totals: ["en0": available(100, 0), "en1": available(50, 50)])
        #expect(readings["en0"]?.availableValue?.receivedPerSecond == 100)
        #expect(readings["en1"] == .unavailable(.notSampled))
    }

    @Test func interfaceMissingFromASampleStartsOverWhenItReturns() {
        var tracker = NetworkRateTracker(minimumWindow: 0)
        _ = tracker.record(at: 0, totals: ["en0": available(0, 0), "en1": available(0, 0)])
        _ = tracker.record(at: 1, totals: ["en0": available(10, 0)])
        let returned = tracker.record(at: 2, totals: ["en0": available(20, 0), "en1": available(5, 5)])
        #expect(returned["en1"] == .unavailable(.notSampled))
    }

    @Test func counterResetIsReportedThenTrackingRecovers() throws {
        var tracker = NetworkRateTracker(minimumWindow: 0)
        _ = tracker.record(at: 0, totals: ["en0": available(10_000, 0)])
        let reset = tracker.record(at: 1, totals: ["en0": available(100, 0)])
        #expect(reset["en0"] == .unavailable(.counterReset))

        let recovered = tracker.record(at: 2, totals: ["en0": available(600, 0)])
        #expect(recovered["en0"]?.availableValue?.receivedPerSecond == 500)
    }

    @Test func unavailableTotalsPropagateTheirIssue() {
        var tracker = NetworkRateTracker(minimumWindow: 0)
        _ = tracker.record(at: 0, totals: ["en0": available(0, 0)])
        let readings = tracker.record(at: 1, totals: ["en0": .unavailable(.permissionDenied(resource: "counters"))])
        #expect(readings["en0"] == .unavailable(.permissionDenied(resource: "counters")))
    }

    @Test func excludedInterfaceReportsNotMonitored() {
        var tracker = NetworkRateTracker(minimumWindow: 0)
        _ = tracker.record(at: 0, totals: ["lo0": .unavailable(.notMonitored)])
        let readings = tracker.record(at: 1, totals: ["lo0": .unavailable(.notMonitored)])
        #expect(readings["lo0"] == .unavailable(.notMonitored))
    }

    @Test func zeroWindowWithNoTimeElapsedIsReported() {
        var tracker = NetworkRateTracker(minimumWindow: 0)
        _ = tracker.record(at: 5, totals: ["en0": available(0, 0)])
        let readings = tracker.record(at: 5, totals: ["en0": available(10, 0)])
        #expect(readings["en0"] == .unavailable(.noElapsedTime))
    }
}
