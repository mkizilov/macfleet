import Foundation
import MacFleetKit

extension ProcessSortKey {
    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        }
    }
}

/// Whether the list shows each process, or processes grouped by app name.
public enum ProcessListMode: CaseIterable, Sendable {
    case processes
    case apps

    public var title: String {
        switch self {
        case .processes: "Processes"
        case .apps: "By app"
        }
    }
}

/// One process as shown. A value that macOS does not let us read shows the reason instead.
public struct ProcessRowPresentation: Equatable, Sendable, Identifiable {
    public let id: ProcessIdentity
    public let pidText: String
    public let name: Presented<String>
    public let started: Presented<String>
    public let cpu: Presented<String>
    public let memory: Presented<String>
    public let isReadable: Bool
    public let spokenSummary: String

    public init(_ record: ProcessRecord) {
        id = record.id
        pidText = "PID \(record.pid)"
        name = presented(record.name) { $0 }
        started = presented(record.startDate) { $0.formatted(date: .abbreviated, time: .shortened) }
        cpu = presented(record.cpuPercent) { String(format: "%.1f%%", $0) }
        memory = presented(record.footprintBytes) { ByteFormatting.binary(bytes: $0) }
        isReadable = record.isReadable
        spokenSummary = [
            pidText,
            name.text,
            "started \(started.text)",
            "CPU \(cpu.text)",
            "memory \(memory.text)",
        ].joined(separator: ", ")
    }
}

/// One app's processes, with totals over the readings that exist.
public struct ProcessGroupPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let countText: String
    public let cpu: Presented<String>
    public let memory: Presented<String>

    public init(_ group: ProcessGroup) {
        id = group.id
        title = group.name ?? "Name not readable"
        countText = "\(group.processCount) \(group.processCount == 1 ? "process" : "processes"), \(group.readableCount) readable"
        cpu = group.totalCPUPercent.map { .available(String(format: "%.1f%%", $0)) }
            ?? .unavailable(ProcessPresentationText.unmeasured(readableCount: group.readableCount))
        memory = group.totalFootprintBytes.map { .available(ByteFormatting.binary(bytes: $0)) }
            ?? .unavailable(ProcessPresentationText.notPermitted)
    }
}

/// Totals for the processes the list shows.
public struct ProcessSummaryPresentation: Equatable, Sendable {
    public let headline: String
    public let cpuText: String
    public let memoryText: String

    public init(_ summary: ProcessSummary) {
        var headline = "\(summary.processCount) \(summary.processCount == 1 ? "process" : "processes")"
        headline += " · \(summary.readableCount) readable"
        if summary.deniedCount > 0 {
            headline += " · \(summary.deniedCount) not permitted"
        }
        self.headline = headline
        cpuText = summary.totalCPUPercent.map {
            String(format: "%.1f%% of one core across %ld measured", $0, summary.cpuMeasuredCount)
        } ?? ProcessPresentationText.unmeasured(readableCount: summary.readableCount)
        memoryText = summary.totalFootprintBytes.map {
            "\(ByteFormatting.binary(bytes: $0)) across \(summary.readableCount) readable"
        } ?? ProcessPresentationText.notPermitted
    }
}

enum ProcessPresentationText {
    static let notPermitted = "Not permitted by macOS"
    static let notMeasuredYet = "Waiting for a second sample"

    /// A CPU total is missing either because nothing was readable or because no process has a second reading yet.
    static func unmeasured(readableCount: Int) -> String {
        readableCount == 0 ? notPermitted : notMeasuredYet
    }
}

/// Everything the process screen shows for one snapshot, sort, search, and mode. Totals describe the processes the
/// list shows, so a search narrows the summary as well as the rows.
public struct ProcessListPresentation: Equatable, Sendable {
    public let mode: ProcessListMode
    public let sort: ProcessSortKey
    public let summary: ProcessSummaryPresentation?
    /// Why the list is empty or incomplete, when it is.
    public let status: String?
    public let rows: [ProcessRowPresentation]
    public let groups: [ProcessGroupPresentation]

    public init(snapshot: ProcessSnapshot?, sort: ProcessSortKey, searchText: String, mode: ProcessListMode) {
        self.mode = mode
        self.sort = sort
        guard let snapshot else {
            summary = nil
            status = "Waiting for the first process listing."
            rows = []
            groups = []
            return
        }
        guard let records = snapshot.records.availableValue else {
            summary = nil
            status = snapshot.records.errorText
            rows = []
            groups = []
            return
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = ProcessAggregation.filtered(records, nameContaining: query)
        summary = matching.isEmpty ? nil : ProcessSummaryPresentation(ProcessAggregation.summary(matching))
        rows = ProcessAggregation.sorted(matching, by: sort).map(ProcessRowPresentation.init)
        groups = ProcessAggregation.groups(matching, by: sort).map(ProcessGroupPresentation.init)
        status = matching.isEmpty
            ? (query.isEmpty ? "No processes are listed." : "No process name contains “\(query)”.")
            : nil
    }
}

private extension MetricReading {
    var errorText: String? {
        if case let .unavailable(issue) = self {
            issue.errorDescription ?? "Not available"
        } else {
            nil
        }
    }
}

private extension Presented where Value == String {
    var text: String {
        switch self {
        case let .available(value):
            value
        case let .unavailable(reason):
            reason
        }
    }
}
