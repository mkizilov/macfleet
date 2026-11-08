import Foundation
import MacFleetKit

/// One source in the history's list of Macs. Its sample count is zero when it has no data in the range, which is not
/// the same as a reading of zero.
public struct HistoryChoice: Equatable, Sendable, Identifiable {
    public let id: HistoryHostID
    public let label: String
    public let isSelected: Bool
    public let samples: Int
}

/// The charts for one selected Mac, with the note about its clock when that clock differs.
public struct HostHistorySection: Equatable, Sendable, Identifiable {
    public let id: HistoryHostID
    public let title: String
    public let clockNote: String?
    public let hasData: Bool
    public let charts: [ChartPresentation]
}

/// One row of the side-by-side comparison: a Mac's totals over the range.
public struct ComparisonRow: Equatable, Sendable, Identifiable {
    public let id: HistoryHostID
    public let title: String
    public let samples: Int
    public let cpuAverage: String
    public let cpuPeak: String
    public let memoryAverage: String
    public let downloadAverage: String
    public let diskAverage: String
    public let lastSample: String
    public let clockNote: String?
}

/// Totals across every Mac with data in the range. Each total merges the Macs' own totals, so it is exact, and a Mac with
/// no reading for a metric is left out of that metric rather than counted as zero.
public struct FleetAggregatePresentation: Equatable, Sendable {
    public let coverage: String
    public let lines: [String]
}

/// The retention policy shown for one Mac, with the values the steppers start from.
public struct RetentionPresentation: Equatable, Sendable {
    public let host: HistoryHostID
    public let title: String
    public let rawHours: Int
    public let fiveMinuteDays: Int
    public let hourlyDays: Int
    public let isDefault: Bool
    public let minimumsText: String
}

/// Everything the history window shows. Built when the selection, the range, or the stored data changes.
public struct FleetHistoryPresentation: Equatable, Sendable {
    public let caption: String
    public let range: HistoryRange
    public let choices: [HistoryChoice]
    public let sections: [HostHistorySection]
    public let comparison: [ComparisonRow]
    public let aggregate: FleetAggregatePresentation
    public let retention: RetentionPresentation?
    /// The alert settings of the first selected remote Mac, when one is selected.
    public let alerts: AlertSettingsPresentation?
    public let alertsHost: HistoryHostID?
    public let notice: String?

    public init(
        range: HistoryRange,
        now: Date,
        identities: [HistoryHostIdentity],
        selected: [HistoryHostID],
        series: [HistoryHostID: HistorySeries],
        summaries: [HistoryHostID: HostWindowSummary],
        clocks: [HistoryHostID: HostClockStatus],
        focusRetention: HistoryRetention?,
        alerts: AlertSettingsPresentation?,
        notice: String?
    ) {
        let window = HistorySeries.window(range: range, now: now)
        let labels = Dictionary(identities.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        self.range = range
        caption = "\(range.title), from \(Date(timeIntervalSince1970: window.start).formatted(Self.captionStyle(range)))"
        choices = identities.map { identity in
            HistoryChoice(
                id: identity.id,
                label: identity.label,
                isSelected: selected.contains(identity.id),
                samples: summaries[identity.id]?.samples ?? 0
            )
        }
        sections = selected.map { id in
            let series = series[id]
            return HostHistorySection(
                id: id,
                title: labels[id] ?? id.rawValue,
                clockNote: Self.clockNote(clocks[id] ?? .unknown),
                hasData: (series?.samples ?? 0) > 0,
                charts: series.map { HistoryPresentation(series: $0).charts } ?? []
            )
        }
        comparison = selected.map { id in
            ComparisonRow.make(
                id: id,
                title: labels[id] ?? id.rawValue,
                summary: summaries[id],
                clock: clocks[id] ?? .unknown
            )
        }
        aggregate = FleetAggregatePresentation.make(
            summaries: identities.compactMap { summaries[$0.id] },
            labels: labels
        )
        if let focus = selected.first {
            retention = RetentionPresentation.make(
                host: focus,
                title: labels[focus] ?? focus.rawValue,
                policy: focusRetention
            )
            alertsHost = focus.isLocal ? nil : focus
            self.alerts = focus.isLocal ? nil : alerts
        } else {
            retention = nil
            alertsHost = nil
            self.alerts = nil
        }
        self.notice = notice
    }

    private static func captionStyle(_ range: HistoryRange) -> Date.FormatStyle {
        range == .week
            ? .dateTime.month(.abbreviated).day().hour().minute()
            : .dateTime.hour().minute()
    }

    /// A note only when the clock differs. Placement is by arrival time either way, so the note says what that means.
    public static func clockNote(_ status: HostClockStatus) -> String? {
        guard case let .differs(seconds) = status else { return nil }
        let direction = seconds > 0 ? "ahead of" : "behind"
        return "Its clock is \(duration(abs(seconds))) \(direction) this Mac's. History is placed by arrival time, so it still lines up with the other Macs."
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 120 {
            return "\(minutes) min"
        }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

extension ComparisonRow {
    public static func make(id: HistoryHostID, title: String, summary: HostWindowSummary?, clock: HostClockStatus) -> ComparisonRow {
        let note = FleetHistoryPresentation.clockNote(clock)
        guard let summary, !summary.isEmpty else {
            return ComparisonRow(
                id: id,
                title: title,
                samples: 0,
                cpuAverage: "–",
                cpuPeak: "–",
                memoryAverage: "–",
                downloadAverage: "–",
                diskAverage: "–",
                lastSample: "No data",
                clockNote: note
            )
        }
        return ComparisonRow(
            id: id,
            title: title,
            samples: summary.samples,
            cpuAverage: percent(summary.cpu.mean),
            cpuPeak: percent(summary.cpu.maximum),
            memoryAverage: percent(summary.memory.mean),
            downloadAverage: rate(summary.download.mean),
            diskAverage: percent(summary.disk.mean),
            lastSample: summary.lastSample.map(TimeText.clock) ?? "No data",
            clockNote: note
        )
    }

    static func percent(_ fraction: Double?) -> String {
        fraction.map { UsageValue(fraction: $0).text } ?? "–"
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        bytesPerSecond.map { ByteFormatting.rate(bytesPerSecond: $0) } ?? "–"
    }
}

extension FleetAggregatePresentation {
    public static func make(summaries: [HostWindowSummary], labels: [HistoryHostID: String]) -> FleetAggregatePresentation {
        let reporting = summaries.filter { !$0.isEmpty }
        let coverage = "Data from \(reporting.count) of \(summaries.count) \(summaries.count == 1 ? "Mac" : "Macs") in this range."
        guard !reporting.isEmpty else {
            return FleetAggregatePresentation(coverage: coverage, lines: ["No Mac has data in this range."])
        }

        var cpu = MetricAggregate()
        var memory = MetricAggregate()
        var download = MetricAggregate()
        var disk = MetricAggregate()
        for summary in reporting {
            cpu.merge(summary.cpu)
            memory.merge(summary.memory)
            download.merge(summary.download)
            disk.merge(summary.disk)
        }
        func peakHost(_ metric: (HostWindowSummary) -> MetricAggregate) -> String {
            let peak = reporting.max { (metric($0).maximum ?? -1) < (metric($1).maximum ?? -1) }
            return peak.flatMap { labels[$0.host] } ?? "–"
        }

        var lines: [String] = []
        lines.append(cpu.count == 0
            ? "CPU: no readings in this range."
            : "CPU: \(ComparisonRow.percent(cpu.mean)) average, \(ComparisonRow.percent(cpu.maximum)) peak on \(peakHost { $0.cpu }).")
        lines.append(memory.count == 0
            ? "Memory: no readings in this range."
            : "Memory: \(ComparisonRow.percent(memory.mean)) average, \(ComparisonRow.percent(memory.maximum)) peak on \(peakHost { $0.memory }).")
        lines.append(download.count == 0
            ? "Download: no readings in this range."
            : "Download: \(ComparisonRow.rate(download.mean)) average, across \(reporting.count) reporting \(reporting.count == 1 ? "Mac" : "Macs").")
        lines.append(disk.count == 0
            ? "Disk: no readings in this range."
            : "Disk: \(ComparisonRow.percent(disk.mean)) average utilization across monitored volumes.")
        return FleetAggregatePresentation(coverage: coverage, lines: lines)
    }
}

extension RetentionPresentation {
    public static func make(host: HistoryHostID, title: String, policy: HistoryRetention?) -> RetentionPresentation {
        let effective = policy ?? .default
        return RetentionPresentation(
            host: host,
            title: title,
            rawHours: Int((effective.raw / 3_600).rounded()),
            fiveMinuteDays: Int((effective.fiveMinute / 86_400).rounded()),
            hourlyDays: Int((effective.hourly / 86_400).rounded()),
            isDefault: policy == nil,
            minimumsText: "Minimums: raw \(Int(HistoryRetention.minimumRaw / 3_600)) hours, five-minute \(Int(HistoryRetention.minimumFiveMinute / 86_400)) days, hourly \(Int(HistoryRetention.minimumHourly / 86_400)) days."
        )
    }
}
