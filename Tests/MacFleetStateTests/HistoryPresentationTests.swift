import Foundation
import MacFleetKit
import Testing
@testable import MacFleetState

private let referenceNow = Date(timeIntervalSince1970: 1_767_225_600)

private func point(_ start: TimeInterval, cpu: Double? = nil, disk: [String: Double] = [:]) -> HistoryPoint {
    HistoryPoint(
        start: start,
        samples: 1,
        cpu: MetricAggregate(value: cpu),
        volumes: disk.mapValues { MetricAggregate(value: $0) }
    )
}

@Suite("History presentation")
struct HistoryPresentationTests {
    @Test func showsFourNamedChartsAndACaption() {
        let presentation = HistoryPresentation(series: MockHistorySource.makeSeries(range: .hour, now: referenceNow))
        #expect(presentation.charts.map(\.title) == ["CPU history", "Memory history", "Network history", "Disk history"])
        #expect(presentation.hasData)
        #expect(presentation.caption.hasPrefix("Last hour, from"))
    }

    @Test func percentChartsHaveACeilingOfOne() {
        let presentation = HistoryPresentation(series: MockHistorySource.makeSeries(range: .day, now: referenceNow))
        #expect(presentation.charts[0].ceiling == 1)
        #expect(presentation.charts[1].ceiling == 1)
        #expect(presentation.charts[3].ceiling == 1)
    }

    @Test func networkCeilingLeavesHeadroomAboveThePeakAndHasAFloor() {
        let series = MockHistorySource.makeSeries(range: .week, now: referenceNow)
        let peak = (series.download + series.upload).compactMap { $0 }.max() ?? 0
        let network = HistoryPresentation(series: series).charts[2]
        #expect(network.ceiling >= peak)
        #expect(network.ceiling >= 128_000)
    }

    @Test func anEmptySeriesSaysItHasNoData() {
        let window = HistorySeries.window(range: .day, now: referenceNow)
        let empty = HistorySeries.build(range: .day, start: window.start, end: window.end, points: [])
        let presentation = HistoryPresentation(series: empty)
        #expect(!presentation.hasData)
        #expect(presentation.charts[3].spokenSummary == "Disk: no data yet.")
        #expect(presentation.charts[0].spokenSummary.hasSuffix("no data yet."))
    }

    @Test func theDiskChartShowsTheRootVolumeWhenItIsPresent() {
        let window = HistorySeries.window(range: .hour, now: referenceNow)
        let series = HistorySeries.build(
            range: .hour,
            start: window.start,
            end: window.end,
            points: [point(window.start + 5, disk: ["/Volumes/Backup": 0.3, "/": 0.7])]
        )
        let disk = HistoryPresentation(series: series).charts[3]
        #expect(disk.series.first?.name == "/")
        #expect(disk.series.first?.samples.first == 0.7)
    }

    @Test func spokenSummariesGiveTheLatestAndPeakValues() {
        let window = HistorySeries.window(range: .hour, now: referenceNow)
        let series = HistorySeries.build(
            range: .hour,
            start: window.start,
            end: window.end,
            points: [point(window.start + 5, cpu: 0.2), point(window.start + 65, cpu: 0.7), point(window.start + 125, cpu: 0.4)]
        )
        let summary = HistoryPresentation(series: series).charts[0].spokenSummary
        #expect(summary == "CPU: latest 40 percent, peak 70 percent over 3 samples.")
    }
}

@Suite("History range labels")
struct HistoryRangeLabelTests {
    @Test func everyRangeHasItsOwnTitles() {
        #expect(HistoryRange.hour.title == "Last hour")
        #expect(HistoryRange.day.title == "Last day")
        #expect(HistoryRange.week.title == "Last week")
        #expect(HistoryRange.allCases.map(\.pickerTitle) == ["Hour", "Day", "Week"])
    }
}
