import Foundation
import Testing
@testable import MacFleetKit

@Suite("Metric aggregates")
struct MetricAggregateTests {
    @Test func emptyAggregateHasNoMeanOrMaximum() {
        #expect(MetricAggregate().mean == nil)
        #expect(MetricAggregate().maximum == nil)
    }

    @Test func gapsAddNothing() {
        #expect(MetricAggregate(value: nil) == MetricAggregate())
    }

    @Test func mergeKeepsTheSumCountAndMaximum() {
        var aggregate = MetricAggregate(value: 0.2)
        aggregate.merge(MetricAggregate(value: 0.6))
        aggregate.merge(MetricAggregate(value: nil))
        #expect(aggregate.count == 2)
        #expect(closeEnough(aggregate.sum, 0.8))
        #expect(closeEnough(aggregate.mean ?? -1, 0.4))
        #expect(aggregate.maximum == 0.6)
    }

    @Test func mergeIsOrderIndependent() {
        let values: [Double?] = [0.1, 0.9, nil, 0.4]
        var forward = MetricAggregate()
        for value in values {
            forward.merge(MetricAggregate(value: value))
        }
        var backward = MetricAggregate()
        for value in values.reversed() {
            backward.merge(MetricAggregate(value: value))
        }
        #expect(sameAggregate(forward, backward))
    }
}

@Suite("History points from snapshots")
struct HistoryPointConversionTests {
    @Test func convertsEachMetric() {
        let point = HistoryPoint(snapshot: makeSnapshot(at: 100, cpu: 0.25, memory: 0.5, download: 1_000, upload: 100))
        #expect(point.start == 100)
        #expect(point.samples == 1)
        #expect(point.cpu.mean == 0.25)
        #expect(point.memory.mean == 0.5)
        #expect(point.download.mean == 1_000)
        #expect(point.upload.mean == 100)
    }

    @Test func onlyBrowsableVolumesAreStored() {
        let point = HistoryPoint(snapshot: makeSnapshot(at: 100, disk: 0.6))
        #expect(Set(point.volumes.keys) == ["/"])
        #expect(closeEnough(point.volumes["/"]?.mean ?? -1, 0.6))
    }

    @Test func aPartialNetworkSumIsAGapNotAnUnderstatedTotal() {
        let network: MetricReading<[NetworkInterfaceMetrics]> = .available([
            NetworkInterfaceMetrics(name: "en0", isUp: true, isLoopback: false, ipv4Addresses: [],
                totals: .unavailable(.notSampled), rates: .available(NetworkRate(receivedPerSecond: 10, sentPerSecond: 1))),
            NetworkInterfaceMetrics(name: "utun3", isUp: true, isLoopback: false, ipv4Addresses: [],
                totals: .unavailable(.notSampled), rates: .unavailable(.counterReset)),
        ])
        let point = HistoryPoint(snapshot: makeSnapshot(at: 100, network: network))
        #expect(point.download.count == 0)
        #expect(point.upload.count == 0)
    }

    @Test func unavailableReadingsAreGapsNotZeros() {
        let point = HistoryPoint(snapshot: makeSnapshot(at: 100, cpuReading: .unavailable(.noElapsedTicks)))
        #expect(point.cpu.count == 0)
        #expect(point.cpu.mean == nil)
    }
}

@Suite("History ranges and windows")
struct HistoryRangeTests {
    @Test func slotsCoverExactlyTheRange() {
        for range in HistoryRange.allCases {
            #expect(closeEnough(range.slotWidth * Double(range.slotCount), range.duration))
        }
    }

    @Test func windowEndsAfterNowOnAnEpochBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_123.5)
        for range in HistoryRange.allCases {
            let window = HistorySeries.window(range: range, now: now)
            #expect(window.end > now.timeIntervalSince1970)
            #expect(closeEnough(window.end - window.start, range.duration))
            #expect(window.end.truncatingRemainder(dividingBy: range.slotWidth) == 0)
        }
    }

    @Test func eachRangeReadsTheTierThatStoresIt() {
        #expect(HistoryRange.hour.tier == .raw)
        #expect(HistoryRange.day.tier == .fiveMinute)
        #expect(HistoryRange.week.tier == .hourly)
    }

    @Test func defaultRetentionCoversEveryChart() {
        let retention = HistoryRetention.default
        #expect(retention.raw >= HistoryRange.hour.duration + HistoryRange.hour.slotWidth)
        #expect(retention.fiveMinute >= HistoryRange.day.duration + HistoryRange.day.slotWidth)
        #expect(retention.hourly >= HistoryRange.week.duration + HistoryRange.week.slotWidth)
    }
}

@Suite("Retention validation")
struct HistoryRetentionTests {
    @Test func minimumsAreAccepted() throws {
        let retention = try HistoryRetention(
            raw: HistoryRetention.minimumRaw,
            fiveMinute: HistoryRetention.minimumFiveMinute,
            hourly: HistoryRetention.minimumHourly
        )
        #expect(retention.hourly == HistoryRetention.minimumHourly)
    }

    @Test func rawBelowItsMinimumIsRejected() {
        #expect(throws: HistoryError.retentionBelowMinimum(tier: "raw", minimum: HistoryRetention.minimumRaw)) {
            try HistoryRetention(raw: 60, fiveMinute: HistoryRetention.minimumFiveMinute, hourly: HistoryRetention.minimumHourly)
        }
    }

    @Test func fiveMinuteBelowItsMinimumIsRejected() {
        #expect(throws: HistoryError.retentionBelowMinimum(tier: "five-minute", minimum: HistoryRetention.minimumFiveMinute)) {
            try HistoryRetention(raw: HistoryRetention.minimumRaw, fiveMinute: 3_600, hourly: HistoryRetention.minimumHourly)
        }
    }

    @Test func hourlyBelowItsMinimumIsRejected() {
        #expect(throws: HistoryError.retentionBelowMinimum(tier: "hourly", minimum: HistoryRetention.minimumHourly)) {
            try HistoryRetention(raw: HistoryRetention.minimumRaw, fiveMinute: HistoryRetention.minimumFiveMinute, hourly: 86_400)
        }
    }

    @Test func errorsHaveReadableDescriptions() {
        let errors: [HistoryError] = [
            .retentionBelowMinimum(tier: "raw", minimum: 7_200),
            .unsupportedSchema(version: 9),
            .sqlite("disk full"),
            .inconsistent("volume without point"),
        ]
        for error in errors {
            #expect((error.errorDescription ?? "").isEmpty == false)
        }
    }
}

@Suite("History series construction")
struct HistorySeriesBuildTests {
    private let range = HistoryRange.hour
    private var window: (start: TimeInterval, end: TimeInterval) {
        HistorySeries.window(range: range, now: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func pointsLandInTheSlotThatContainsThem() {
        let (start, end) = window
        let points = [
            HistoryPoint(start: start + 5, samples: 1, cpu: MetricAggregate(value: 0.2)),
            HistoryPoint(start: start + 35, samples: 1, cpu: MetricAggregate(value: 0.6)),
            HistoryPoint(start: start + 65, samples: 1, cpu: MetricAggregate(value: 0.9)),
            HistoryPoint(start: start - 1, samples: 1, cpu: MetricAggregate(value: 1)),
            HistoryPoint(start: end + 1, samples: 1, cpu: MetricAggregate(value: 1)),
        ]
        let series = HistorySeries.build(range: range, start: start, end: end, points: points)

        #expect(series.cpu.count == range.slotCount)
        #expect(closeEnough(series.cpu[0] ?? -1, 0.4))
        #expect(series.cpu[1] == 0.9)
        #expect(series.cpu[2] == nil)
        #expect(series.samples == 3)
    }

    @Test func volumesAreSortedAndAlignedToSlots() {
        let (start, end) = window
        let points = [
            HistoryPoint(start: start + 5, samples: 1, volumes: ["/Volumes/Backup": MetricAggregate(value: 0.3)]),
            HistoryPoint(start: start + 5, samples: 1, volumes: ["/": MetricAggregate(value: 0.7)]),
        ]
        let series = HistorySeries.build(range: range, start: start, end: end, points: points)

        #expect(series.volumes.map(\.mountPoint) == ["/", "/Volumes/Backup"])
        #expect(series.volumes[0].utilization[0] == 0.7)
        #expect(series.volumes[1].utilization[0] == 0.3)
        #expect(series.volumes[1].utilization[1] == nil)
    }

    @Test func emptyInputIsAllGaps() {
        let (start, end) = window
        let series = HistorySeries.build(range: range, start: start, end: end, points: [])
        #expect(series.samples == 0)
        #expect(series.cpu.allSatisfy { $0 == nil })
        #expect(series.volumes.isEmpty)
    }

    @Test func mergingPointsIntoOneSlotEqualsMergingTheirAggregates() {
        var merged = HistoryPoint(start: 0)
        merged.merge(HistoryPoint(snapshot: makeSnapshot(at: 0, cpu: 0.1)))
        merged.merge(HistoryPoint(snapshot: makeSnapshot(at: 10, cpu: 0.5)))
        #expect(merged.samples == 2)
        #expect(closeEnough(merged.cpu.mean ?? -1, 0.3))
        #expect(merged.cpu.maximum == 0.5)
    }
}
