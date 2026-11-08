import Foundation

/// Totals across the processes in a snapshot. A total counts only the readings that exist, and says how many did.
public struct ProcessSummary: Equatable, Sendable {
    public let processCount: Int
    public let readableCount: Int
    public let cpuMeasuredCount: Int
    public let totalCPUPercent: Double?
    public let totalFootprintBytes: UInt64?

    public var deniedCount: Int {
        processCount - readableCount
    }
}

/// One app's processes, grouped by executable name.
public struct ProcessGroup: Equatable, Identifiable, Sendable {
    /// Nil for processes whose name could not be read.
    public let name: String?
    public let processCount: Int
    public let readableCount: Int
    public let cpuMeasuredCount: Int
    public let totalCPUPercent: Double?
    public let totalFootprintBytes: UInt64?

    public var id: String {
        name ?? ""
    }

    public var deniedCount: Int {
        processCount - readableCount
    }
}

/// Sorting, search, and totals over process records. Pure functions, so they run the same way on any thread.
public enum ProcessAggregation {
    /// Largest value first. Processes without a reading sort last, and ties break by PID and then start time,
    /// so the order is the same for the same snapshot every time.
    public static func sorted(_ records: [ProcessRecord], by key: ProcessSortKey) -> [ProcessRecord] {
        records.sorted { lhs, rhs in
            switch (value(lhs, key), value(rhs, key)) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return (lhs.pid, lhs.id.startMicroseconds ?? 0) < (rhs.pid, rhs.id.startMicroseconds ?? 0)
            }
        }
    }

    /// Case-insensitive match on the executable name. Surrounding spaces are ignored. A process whose name is
    /// unreadable never matches a search.
    public static func filtered(_ records: [ProcessRecord], nameContaining query: String) -> [ProcessRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return records }
        return records.filter { $0.name.availableValue?.localizedCaseInsensitiveContains(needle) == true }
    }

    public static func summary(_ records: [ProcessRecord]) -> ProcessSummary {
        let cpu = records.compactMap { $0.cpuPercent.availableValue }
        let memory = records.compactMap { $0.footprintBytes.availableValue }
        return ProcessSummary(
            processCount: records.count,
            readableCount: records.filter(\.isReadable).count,
            cpuMeasuredCount: cpu.count,
            totalCPUPercent: cpu.isEmpty ? nil : cpu.reduce(0, +),
            totalFootprintBytes: memory.isEmpty ? nil : memory.reduce(0, +)
        )
    }

    /// Groups by executable name. Groups are ordered by the key, largest first, with unmeasured groups last.
    public static func groups(_ records: [ProcessRecord], by key: ProcessSortKey) -> [ProcessGroup] {
        let grouped = Dictionary(grouping: records) { $0.name.availableValue }
        return grouped.map { name, members in
            let cpu = members.compactMap { $0.cpuPercent.availableValue }
            let memory = members.compactMap { $0.footprintBytes.availableValue }
            return ProcessGroup(
                name: name,
                processCount: members.count,
                readableCount: members.filter(\.isReadable).count,
                cpuMeasuredCount: cpu.count,
                totalCPUPercent: cpu.isEmpty ? nil : cpu.reduce(0, +),
                totalFootprintBytes: memory.isEmpty ? nil : memory.reduce(0, +)
            )
        }
        .sorted { lhs, rhs in
            switch (groupValue(lhs, key), groupValue(rhs, key)) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return (lhs.name ?? "") < (rhs.name ?? "")
            }
        }
    }

    private static func value(_ record: ProcessRecord, _ key: ProcessSortKey) -> Double? {
        switch key {
        case .cpu:
            record.cpuPercent.availableValue
        case .memory:
            record.footprintBytes.availableValue.map(Double.init)
        }
    }

    private static func groupValue(_ group: ProcessGroup, _ key: ProcessSortKey) -> Double? {
        switch key {
        case .cpu:
            group.totalCPUPercent
        case .memory:
            group.totalFootprintBytes.map(Double.init)
        }
    }
}
