import Foundation

/// Identifies one process across samples. The start time tells a process apart from a later process that reuses its
/// PID. A process whose start time is not read is identified by PID alone.
public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startMicroseconds: UInt64?

    public init(pid: Int32, startMicroseconds: UInt64?) {
        self.pid = pid
        self.startMicroseconds = startMicroseconds
    }
}

/// Cumulative counters for a process that macOS let this app read.
public struct ProcessCounters: Equatable, Sendable {
    /// Start time in microseconds since 1970. Nil when macOS does not show it.
    public let startMicroseconds: UInt64?
    /// User plus system CPU time since the process started, in nanoseconds.
    public let cpuNanoseconds: UInt64
    /// Physical memory footprint, the figure Activity Monitor shows as Memory.
    public let footprintBytes: UInt64

    public init(startMicroseconds: UInt64?, cpuNanoseconds: UInt64, footprintBytes: UInt64) {
        self.startMicroseconds = startMicroseconds
        self.cpuNanoseconds = cpuNanoseconds
        self.footprintBytes = footprintBytes
    }
}

/// One process as a source found it in a listing. The outcome says what macOS allowed this app to read.
public struct ProcessListing: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case readable(ProcessCounters)
        /// macOS refused the details, typically because the process belongs to another user or is protected.
        case denied
        /// The process exited after it was listed and before it was read.
        case gone
    }

    public let pid: Int32
    /// The executable's file name, when its path could be read. Names are readable even where details are not.
    public let name: String?
    public let outcome: Outcome

    public init(pid: Int32, name: String?, outcome: Outcome) {
        self.pid = pid
        self.name = name
        self.outcome = outcome
    }
}

/// One process as shown. Each value is a reading, so a process that macOS does not let us read shows why.
public struct ProcessRecord: Equatable, Identifiable, Sendable {
    public let id: ProcessIdentity
    public let name: MetricReading<String>
    public let startDate: MetricReading<Date>
    /// Percent of one CPU core, as Activity Monitor reports it. Above 100 for multithreaded work.
    public let cpuPercent: MetricReading<Double>
    public let footprintBytes: MetricReading<UInt64>

    public init(
        id: ProcessIdentity,
        name: MetricReading<String>,
        startDate: MetricReading<Date>,
        cpuPercent: MetricReading<Double>,
        footprintBytes: MetricReading<UInt64>
    ) {
        self.id = id
        self.name = name
        self.startDate = startDate
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }

    public var pid: Int32 {
        id.pid
    }

    /// Whether macOS let this app read the process's details. Denied and vanished processes are not readable.
    public var isReadable: Bool {
        footprintBytes.availableValue != nil
    }
}

/// One listing of every process, or the reason the listing itself failed.
public struct ProcessSnapshot: Equatable, Sendable {
    public let capturedAt: Date
    public let records: MetricReading<[ProcessRecord]>

    public init(capturedAt: Date, records: MetricReading<[ProcessRecord]>) {
        self.capturedAt = capturedAt
        self.records = records
    }
}

public enum ProcessSortKey: CaseIterable, Sendable {
    case cpu
    case memory
}
