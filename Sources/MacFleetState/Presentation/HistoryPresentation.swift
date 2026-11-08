import Foundation
import MacFleetKit

extension HistoryRange {
    public var title: String {
        switch self {
        case .hour: "Last hour"
        case .day: "Last day"
        case .week: "Last week"
        }
    }

    public var pickerTitle: String {
        switch self {
        case .hour: "Hour"
        case .day: "Day"
        case .week: "Week"
        }
    }
}

/// Chart data for one history range. Built on the main actor from a `HistorySeries`, which the store computes off it.
public struct HistoryPresentation: Equatable, Sendable {
    public let caption: String
    public let hasData: Bool
    public let charts: [ChartPresentation]

    public init(series: HistorySeries) {
        let style: Date.FormatStyle = series.range == .week
            ? .dateTime.month(.abbreviated).day().hour().minute()
            : .dateTime.hour().minute()
        caption = "\(series.range.title), from \(series.start.formatted(style))"
        hasData = series.samples > 0
        charts = [
            Self.percentChart(title: "CPU history", role: .cpu, name: "CPU", samples: series.cpu),
            Self.percentChart(title: "Memory history", role: .memory, name: "Memory", samples: series.memory),
            Self.networkChart(download: series.download, upload: series.upload),
            Self.diskChart(series.volumes),
        ]
    }

    private static func percentChart(title: String, role: ChartRole, name: String, samples: [Double?]) -> ChartPresentation {
        ChartPresentation(
            title: title,
            series: [ChartSeries(role: role, name: name, samples: samples)],
            ceiling: 1,
            spokenSummary: ChartSummary.describe(name, samples: samples, format: SpokenFormatting.percent)
        )
    }

    private static func networkChart(download: [Double?], upload: [Double?]) -> ChartPresentation {
        let peak = (download + upload).compactMap { $0 }.max() ?? 0
        return ChartPresentation(
            title: "Network history",
            series: [
                ChartSeries(role: .download, name: "Download", samples: download),
                ChartSeries(role: .upload, name: "Upload", samples: upload),
            ],
            ceiling: max(peak * 1.15, 128_000),
            spokenSummary: [
                ChartSummary.describe("Download", samples: download, format: SpokenFormatting.rate),
                ChartSummary.describe("Upload", samples: upload, format: SpokenFormatting.rate),
            ].joined(separator: " ")
        )
    }

    /// The root volume when it is monitored, otherwise the first monitored volume.
    private static func diskChart(_ volumes: [HistorySeries.Volume]) -> ChartPresentation {
        let disk = volumes.first { $0.mountPoint == "/" } ?? volumes.first
        return ChartPresentation(
            title: "Disk history",
            series: [ChartSeries(role: .disk, name: disk?.mountPoint ?? "Disk", samples: disk?.utilization ?? [])],
            ceiling: 1,
            spokenSummary: disk.map { ChartSummary.describe("Disk \($0.mountPoint)", samples: $0.utilization, format: SpokenFormatting.percent) }
                ?? "Disk: no data yet."
        )
    }
}

/// What the history section shows: the chosen range, its content, and any storage notice.
public struct HistoryCardPresentation: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case loading
        case loaded(HistoryPresentation)
        case unavailable(String)
    }

    public let range: HistoryRange
    public let content: Content
    public let notice: String?

    public init(range: HistoryRange, content: Content, notice: String?) {
        self.range = range
        self.content = content
        self.notice = notice
    }
}
