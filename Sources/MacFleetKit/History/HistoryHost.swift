import Foundation

/// A stable identifier for one monitored computer. History rows are keyed by it, so two computers never share a row.
/// The local Mac is `local`. A registered remote Mac uses the ID of its record, which survives re-pinning and renaming.
public struct HistoryHostID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let local = HistoryHostID(rawValue: "local")

    public static func remote(_ recordID: UUID) -> HistoryHostID {
        HistoryHostID(rawValue: recordID.uuidString)
    }

    public var isLocal: Bool {
        self == .local
    }

    public var description: String {
        rawValue
    }

    public static func < (lhs: HistoryHostID, rhs: HistoryHostID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A computer's ID with the name the user knows it by.
public struct HistoryHostIdentity: Equatable, Sendable {
    public let id: HistoryHostID
    public let label: String

    public init(id: HistoryHostID, label: String) {
        self.id = id
        self.label = label
    }
}

/// What happened to one snapshot offered to the store.
public enum HistoryIngestOutcome: Equatable, Sendable {
    case accepted
    /// Closer to the previous accepted sample than the raw resolution allows.
    case throttled
    /// The host sent the same sample again.
    case duplicate
    /// This Mac's clock moved back past the last accepted sample. The sample is dropped rather than stored out of order.
    case clockRegressed
}

/// How a remote Mac's clock compares with this Mac's clock. Samples are always placed by the time they arrived, so this
/// only says whether the difference is large enough to tell the user about.
public enum HostClockStatus: Equatable, Sendable {
    case unknown
    case aligned
    /// The host's clock is ahead of this Mac's by `seconds`, or behind it when negative.
    case differs(seconds: Double)

    /// The largest difference still treated as aligned.
    public static let tolerance: TimeInterval = 60

    public static func classify(offset: Double) -> HostClockStatus {
        abs(offset) <= tolerance ? .aligned : .differs(seconds: offset)
    }
}

/// The merged totals of one host over a window. Aggregates merge exactly, so the same window gives the same totals at any
/// tier, and totals across hosts are merges of the per-host totals.
public struct HostWindowSummary: Equatable, Sendable {
    public let host: HistoryHostID
    public let from: Date
    public let to: Date
    /// Snapshots stored in the window.
    public let samples: Int
    public let cpu: MetricAggregate
    public let memory: MetricAggregate
    public let download: MetricAggregate
    public let upload: MetricAggregate
    /// Every monitored volume's utilization, merged.
    public let disk: MetricAggregate
    /// When the newest stored point in the window began, or nil when the window holds none.
    public let lastSample: Date?

    public init(
        host: HistoryHostID,
        from: Date,
        to: Date,
        samples: Int,
        cpu: MetricAggregate,
        memory: MetricAggregate,
        download: MetricAggregate,
        upload: MetricAggregate,
        disk: MetricAggregate,
        lastSample: Date?
    ) {
        self.host = host
        self.from = from
        self.to = to
        self.samples = samples
        self.cpu = cpu
        self.memory = memory
        self.download = download
        self.upload = upload
        self.disk = disk
        self.lastSample = lastSample
    }

    public var isEmpty: Bool {
        samples == 0
    }
}

/// One exported value: a metric of one host in one bucket. A bucket with no reading for the metric has no mean or maximum.
public struct HistoryExportRow: Equatable, Sendable {
    /// Start of the bucket, in UTC.
    public let time: Date
    public let resolution: HistoryTier
    public let host: HistoryHostID
    public let metric: String
    public let mean: Double?
    public let maximum: Double?
    /// Readings behind the mean.
    public let observations: Int
    /// Snapshots behind the bucket.
    public let snapshots: Int

    public init(
        time: Date,
        resolution: HistoryTier,
        host: HistoryHostID,
        metric: String,
        mean: Double?,
        maximum: Double?,
        observations: Int,
        snapshots: Int
    ) {
        self.time = time
        self.resolution = resolution
        self.host = host
        self.metric = metric
        self.mean = mean
        self.maximum = maximum
        self.observations = observations
        self.snapshots = snapshots
    }
}

/// The finest tier that keeps a window within a point budget, so a long window reads fewer rows.
public enum HistoryResolution {
    public static func tier(span: TimeInterval, maximumPoints: Int, rawResolution: TimeInterval = 10) -> HistoryTier {
        let limit = Double(max(maximumPoints, 1))
        if span / rawResolution <= limit {
            return .raw
        }
        if span / Double(HistoryTier.fiveMinute.width) <= limit {
            return .fiveMinute
        }
        return .hourly
    }
}

/// Receives remote snapshots for the history. Each watcher sends its host's snapshots in order, and the store takes them
/// one at a time, so concurrent hosts can write without mixing their rows.
public protocol RemoteHistorySink: Sendable {
    func ingest(_ snapshot: RemoteSnapshot, from host: HistoryHostID, receivedAt: Date) async -> HistoryIngestOutcome
}

/// Everything the multi-host history needs from storage. Each call names the host it concerns.
public protocol FleetHistoryStoring: RemoteHistorySink {
    func series(host: HistoryHostID, range: HistoryRange, now: Date) async throws -> HistorySeries
    func summary(host: HistoryHostID, from: Date, to: Date) async throws -> HostWindowSummary
    func exportRows(hosts: [HistoryHostID], from: Date, to: Date, maximumPoints: Int) async throws -> [HistoryExportRow]
    func clockStatus(host: HistoryHostID) async -> HostClockStatus
    /// The host's own retention, or nil when it uses the store's default.
    func retention(for host: HistoryHostID) async throws -> HistoryRetention?
    /// Sets the host's retention. Nil returns it to the default. Shortening it removes older history at once.
    func setRetention(_ retention: HistoryRetention?, for host: HistoryHostID) async throws
    func storedHosts() async throws -> [HistoryHostID]
    /// Deletes everything stored for the host, and returns how many rows were removed.
    func removeHistory(for host: HistoryHostID) async throws -> Int
}
