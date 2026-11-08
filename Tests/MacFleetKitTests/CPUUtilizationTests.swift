import Testing
@testable import MacFleetKit

private func ticks(user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0) -> CPUTicks {
    CPUTicks(user: user, system: system, idle: idle, nice: nice)
}

@Suite("CPU utilization calculation")
struct CPUUtilizationCalculatorTests {
    @Test func busyShareOfElapsedTicks() throws {
        let value = try CPUUtilizationCalculator.utilization(
            previous: ticks(),
            current: ticks(user: 30, system: 10, idle: 60)
        )
        #expect(abs(value - 0.4) < 1e-12)
    }

    @Test func niceTicksCountAsBusy() throws {
        let value = try CPUUtilizationCalculator.utilization(
            previous: ticks(),
            current: ticks(idle: 75, nice: 25)
        )
        #expect(abs(value - 0.25) < 1e-12)
    }

    @Test func onlyIdleTicksGiveZero() throws {
        let value = try CPUUtilizationCalculator.utilization(previous: ticks(), current: ticks(idle: 100))
        #expect(value == 0)
    }

    @Test func onlyBusyTicksGiveOne() throws {
        let value = try CPUUtilizationCalculator.utilization(previous: ticks(), current: ticks(user: 100))
        #expect(value == 1)
    }

    @Test func deltasUseOnlyTheWindowNotCumulativeTotals() throws {
        let previous = ticks(user: 9_000, system: 1_000, idle: 90_000)
        let current = ticks(user: 9_030, system: 1_010, idle: 90_060)
        let value = try CPUUtilizationCalculator.utilization(previous: previous, current: current)
        #expect(abs(value - 0.4) < 1e-12)
    }

    @Test func counterRolloverIsHandled() throws {
        let previous = ticks(user: UInt32.max - 9, idle: UInt32.max - 19)
        let current = ticks(user: 10, idle: 60)
        let value = try CPUUtilizationCalculator.utilization(previous: previous, current: current)
        #expect(abs(value - 0.2) < 1e-12)
    }

    @Test func rolloverFromMaximumToZeroIsOneTickEach() throws {
        let previous = ticks(user: UInt32.max, idle: UInt32.max)
        let current = ticks(user: 0, idle: 0)
        let value = try CPUUtilizationCalculator.utilization(previous: previous, current: current)
        #expect(abs(value - 0.5) < 1e-12)
    }

    @Test func backwardsCounterIsReportedAsReset() {
        #expect(throws: MetricIssue.counterReset) {
            try CPUUtilizationCalculator.utilization(previous: ticks(user: 100), current: ticks(user: 50))
        }
    }

    @Test func unchangedCountersReportNoElapsedTicks() {
        let sample = ticks(user: 5, system: 5, idle: 5)
        #expect(throws: MetricIssue.noElapsedTicks) {
            try CPUUtilizationCalculator.utilization(previous: sample, current: sample)
        }
    }

    @Test func perCoreUtilizationIsComputedPerCore() throws {
        let values = try CPUUtilizationCalculator.utilization(
            previous: [ticks(), ticks()],
            current: [ticks(user: 50, idle: 50), ticks(user: 25, idle: 75)]
        )
        #expect(values.count == 2)
        #expect(abs(values[0] - 0.5) < 1e-12)
        #expect(abs(values[1] - 0.25) < 1e-12)
    }

    @Test func changedCoreCountIsAnError() {
        #expect(throws: MetricIssue.coreCountChanged(previous: 2, current: 3)) {
            try CPUUtilizationCalculator.utilization(
                previous: [ticks(), ticks()],
                current: [ticks(), ticks(), ticks()]
            )
        }
    }

    @Test func oneCoreWithoutElapsedTicksFailsThePerCoreReading() {
        let still = ticks(user: 1, idle: 1)
        #expect(throws: MetricIssue.noElapsedTicks) {
            try CPUUtilizationCalculator.utilization(
                previous: [ticks(), still],
                current: [ticks(user: 1), still]
            )
        }
    }
}

@Suite("CPU utilization tracker")
struct CPUUtilizationTrackerTests {
    private let idleTicks = ticks()

    @Test func firstReadingHasNoBaseline() {
        var tracker = CPUUtilizationTracker(minimumWindow: 1)
        let reading = tracker.record(at: 0, total: .available(ticks(user: 10)), perCore: .available([]))
        #expect(reading == .unavailable(.notSampled))
    }

    @Test func secondReadingComputesUtilizationOverTheWindow() throws {
        var tracker = CPUUtilizationTracker(minimumWindow: 1)
        _ = tracker.record(at: 0, total: .available(ticks()), perCore: .available([ticks()]))
        let reading = tracker.record(
            at: 2,
            total: .available(ticks(user: 30, idle: 70)),
            perCore: .available([ticks(user: 30, idle: 70)])
        )
        let value = try #require(reading.availableValue)
        #expect(abs(value.total - 0.3) < 1e-12)
        #expect(value.perCore.availableValue?.count == 1)
    }

    @Test func shortWindowRepeatsLastReadingAndKeepsBaseline() throws {
        var tracker = CPUUtilizationTracker(minimumWindow: 1)
        let start = ticks(user: 100, idle: 100)
        let middle = ticks(user: 101, idle: 103)
        let end = ticks(user: 160, idle: 140)

        _ = tracker.record(at: 0, total: .available(start), perCore: .available([start]))
        let shortReading = tracker.record(at: 0.5, total: .available(middle), perCore: .available([middle]))
        #expect(shortReading == .unavailable(.notSampled))

        let reading = tracker.record(at: 1.5, total: .available(end), perCore: .available([end]))
        let expected = try CPUUtilizationCalculator.utilization(previous: start, current: end)
        let value = try #require(reading.availableValue)
        #expect(abs(value.total - expected) < 1e-12)
    }

    @Test func counterResetIsReportedThenTrackingRecovers() throws {
        var tracker = CPUUtilizationTracker(minimumWindow: 1)
        _ = tracker.record(at: 0, total: .available(ticks(user: 500)), perCore: .available([]))
        let reset = tracker.record(at: 2, total: .available(ticks(user: 10, idle: 0)), perCore: .available([]))
        #expect(reset == .unavailable(.counterReset))

        let recovered = tracker.record(
            at: 4,
            total: .available(ticks(user: 40, idle: 60)),
            perCore: .available([])
        )
        let value = try #require(recovered.availableValue)
        #expect(abs(value.total - 1.0 / 3.0) < 1e-12)
    }

    @Test func totalFailurePropagatesWithoutMovingBaseline() throws {
        var tracker = CPUUtilizationTracker(minimumWindow: 0)
        _ = tracker.record(at: 0, total: .available(ticks()), perCore: .available([]))
        let failed = tracker.record(
            at: 1,
            total: .unavailable(.kernelCallFailed(call: "host_statistics", code: 5)),
            perCore: .available([])
        )
        #expect(failed == .unavailable(.kernelCallFailed(call: "host_statistics", code: 5)))

        let recovered = tracker.record(at: 2, total: .available(ticks(user: 50, idle: 50)), perCore: .available([]))
        let value = try #require(recovered.availableValue)
        #expect(abs(value.total - 0.5) < 1e-12)
    }

    @Test func emptyWindowKeepsBaselineSoNextReadingSpansTheFullInterval() throws {
        var tracker = CPUUtilizationTracker(minimumWindow: 1)
        let start = ticks(user: 100, idle: 100)
        let end = ticks(user: 160, idle: 140)

        _ = tracker.record(at: 0, total: .available(start), perCore: .available([start]))
        let empty = tracker.record(at: 1.2, total: .available(start), perCore: .available([start]))
        #expect(empty == .unavailable(.noElapsedTicks))

        let reading = tracker.record(at: 2.4, total: .available(end), perCore: .available([end]))
        let expected = try CPUUtilizationCalculator.utilization(previous: start, current: end)
        let value = try #require(reading.availableValue)
        #expect(abs(value.total - expected) < 1e-12)
    }

    @Test func perCoreFailureKeepsTheTotal() throws {
        var tracker = CPUUtilizationTracker(minimumWindow: 0)
        _ = tracker.record(at: 0, total: .available(idleTicks), perCore: .available([idleTicks]))
        let reading = tracker.record(
            at: 1,
            total: .available(ticks(user: 20, idle: 80)),
            perCore: .unavailable(.kernelCallFailed(call: "host_processor_info", code: 4))
        )
        let value = try #require(reading.availableValue)
        #expect(abs(value.total - 0.2) < 1e-12)
        #expect(value.perCore == .unavailable(.kernelCallFailed(call: "host_processor_info", code: 4)))
    }
}
