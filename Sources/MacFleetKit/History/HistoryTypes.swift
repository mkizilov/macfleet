import Foundation

/// Storage resolution. Raw points are downsampled snapshots. Each coarser tier is rolled up from the tier below.
public enum HistoryTier: Int, CaseIterable, Sendable {
    case raw = 0
    case fiveMinute = 1
    case hourly = 2

    /// Bucket width in seconds. Raw points are not bucketed.
    var width: Int {
        switch self {
        case .raw: 0
        case .fiveMinute: 300
        case .hourly: 3_600
        }
    }

    /// The tier this one is rolled up from.
    var source: HistoryTier? {
        switch self {
        case .raw: nil
        case .fiveMinute: .raw
        case .hourly: .fiveMinute
        }
    }

    var horizonKey: String {
        "horizon.\(rawValue)"
    }
}

/// Sum, count, and maximum of the non-missing values in a span. Two aggregates merge exactly, which is what
/// lets coarser tiers be built from finer ones.
public struct MetricAggregate: Equatable, Sendable {
    public var sum: Double
    public var count: Int
    public var maximum: Double?

    public init(sum: Double = 0, count: Int = 0, maximum: Double? = nil) {
        self.sum = sum
        self.count = count
        self.maximum = maximum
    }

    /// One reading. A nil reading is a gap and adds nothing.
    public init(value: Double?) {
        if let value {
            self.init(sum: value, count: 1, maximum: value)
        } else {
            self.init()
        }
    }

    public var mean: Double? {
        count > 0 ? sum / Double(count) : nil
    }

    public mutating func merge(_ other: MetricAggregate) {
        sum += other.sum
        count += other.count
        if let otherMaximum = other.maximum {
            maximum = Swift.max(maximum ?? otherMaximum, otherMaximum)
        }
    }
}

/// One stored point: a snapshot at raw resolution, or the merged span of one bucket at a coarser tier.
public struct HistoryPoint: Equatable, Sendable {
    /// Unix time in seconds at which the point's span begins.
    public let start: TimeInterval
    /// Snapshots represented by this point.
    public var samples: Int
    public var cpu: MetricAggregate
    public var memory: MetricAggregate
    public var download: MetricAggregate
    public var upload: MetricAggregate
    /// Utilization of each browsable, monitored volume, keyed by mount point.
    public var volumes: [String: MetricAggregate]

    public init(
        start: TimeInterval,
        samples: Int = 0,
        cpu: MetricAggregate = MetricAggregate(),
        memory: MetricAggregate = MetricAggregate(),
        download: MetricAggregate = MetricAggregate(),
        upload: MetricAggregate = MetricAggregate(),
        volumes: [String: MetricAggregate] = [:]
    ) {
        self.start = start
        self.samples = samples
        self.cpu = cpu
        self.memory = memory
        self.download = download
        self.upload = upload
        self.volumes = volumes
    }

    public init(snapshot: SystemSnapshot) {
        let rate = AggregateNetworkRate.rate(snapshot.network)
        let disks = (snapshot.volumes.availableValue ?? [])
            .filter(\.isBrowsable)
            .compactMap { volume in
                volume.capacity.availableValue.map { (volume.mountPoint, MetricAggregate(value: $0.utilization)) }
            }
        self.init(
            start: snapshot.capturedAt.timeIntervalSince1970,
            samples: 1,
            cpu: MetricAggregate(value: snapshot.cpu.availableValue?.total),
            memory: MetricAggregate(value: snapshot.memory.availableValue?.usedFraction),
            download: MetricAggregate(value: rate?.receivedPerSecond),
            upload: MetricAggregate(value: rate?.sentPerSecond),
            volumes: Dictionary(disks, uniquingKeysWith: { first, _ in first })
        )
    }

    public mutating func merge(_ other: HistoryPoint) {
        samples += other.samples
        cpu.merge(other.cpu)
        memory.merge(other.memory)
        download.merge(other.download)
        upload.merge(other.upload)
        for (mountPoint, aggregate) in other.volumes {
            volumes[mountPoint, default: MetricAggregate()].merge(aggregate)
        }
    }
}

/// The spans the history charts show. Each span is drawn with a fixed number of slots, and each slot is one
/// bucket of the tier that stores that span.
public enum HistoryRange: CaseIterable, Hashable, Sendable {
    case hour
    case day
    case week

    public var duration: TimeInterval {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 604_800
        }
    }

    public var slotCount: Int {
        switch self {
        case .hour: 60
        case .day: 288
        case .week: 168
        }
    }

    public var slotWidth: TimeInterval {
        duration / Double(slotCount)
    }

    var tier: HistoryTier {
        switch self {
        case .hour: .raw
        case .day: .fiveMinute
        case .week: .hourly
        }
    }
}

/// How long each tier is kept. The minimums cover what the charts read, so pruning never removes data a chart needs.
public struct HistoryRetention: Equatable, Sendable {
    public static let minimumRaw: TimeInterval = 2 * 3_600
    public static let minimumFiveMinute: TimeInterval = 2 * 86_400
    public static let minimumHourly: TimeInterval = 8 * 86_400
    public static let `default` = HistoryRetention(validated: 2 * 86_400, 14 * 86_400, 90 * 86_400)

    public let raw: TimeInterval
    public let fiveMinute: TimeInterval
    public let hourly: TimeInterval

    public init(raw: TimeInterval, fiveMinute: TimeInterval, hourly: TimeInterval) throws {
        guard raw >= Self.minimumRaw else {
            throw HistoryError.retentionBelowMinimum(tier: "raw", minimum: Self.minimumRaw)
        }
        guard fiveMinute >= Self.minimumFiveMinute else {
            throw HistoryError.retentionBelowMinimum(tier: "five-minute", minimum: Self.minimumFiveMinute)
        }
        guard hourly >= Self.minimumHourly else {
            throw HistoryError.retentionBelowMinimum(tier: "hourly", minimum: Self.minimumHourly)
        }
        self.init(validated: raw, fiveMinute, hourly)
    }

    private init(validated raw: TimeInterval, _ fiveMinute: TimeInterval, _ hourly: TimeInterval) {
        self.raw = raw
        self.fiveMinute = fiveMinute
        self.hourly = hourly
    }

    func retention(for tier: HistoryTier) -> TimeInterval {
        switch tier {
        case .raw: raw
        case .fiveMinute: fiveMinute
        case .hourly: hourly
        }
    }
}

public enum HistoryError: LocalizedError, Equatable, Sendable {
    case retentionBelowMinimum(tier: String, minimum: TimeInterval)
    case unsupportedSchema(version: Int)
    case sqlite(String)
    case inconsistent(String)

    public var errorDescription: String? {
        switch self {
        case let .retentionBelowMinimum(tier, minimum):
            "Retention for \(tier) history must be at least \(Int(minimum / 3_600)) hours."
        case let .unsupportedSchema(version):
            "The history file uses schema version \(version), which this build does not understand."
        case let .sqlite(message):
            "History storage failed: \(message)"
        case let .inconsistent(detail):
            "History storage is inconsistent: \(detail)"
        }
    }
}
