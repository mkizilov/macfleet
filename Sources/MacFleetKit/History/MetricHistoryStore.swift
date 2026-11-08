import Foundation

/// Persistent metric history. The store is the sampling engine's `SnapshotStoring`, so every collection reaches it,
/// and it answers the time-range queries behind the history charts.
///
/// - Downsampling: snapshots closer together than `rawResolution` are skipped. The default keeps one point every
///   10 seconds, so the 2-second popover cadence does not multiply writes.
/// - Batching: points are buffered and written in one transaction when the buffer reaches `batchSize`, when its
///   oldest point is `batchAge` seconds old, and before any read, rollup, suspend, or shutdown.
/// - Aggregation: closed five-minute buckets are rolled up from raw points, and closed hour buckets from
///   five-minute buckets. Each tier records a horizon, the time up to which it is complete. A read takes each span
///   from the coarsest tier that covers it and fills the rest from the next finer tier, so a bucket that has not been
///   rolled up yet is neither missing nor counted twice.
/// - Retention: after each rollup, every tier is pruned to its own retention. Rollup runs before pruning, so no raw
///   point is deleted before it is aggregated.
/// - Recovery: each write is one transaction, so an interrupted write leaves no partial state. A file that fails the
///   integrity check is moved aside with its journal files, and a new store is started. `recoveryNote` reports it.
public actor MetricHistoryStore: SnapshotStoring, HistorySource {
    public struct Configuration: Sendable {
        public var rawResolution: TimeInterval = 10
        public var batchSize = 32
        /// Longest a point waits in memory. Raw points arrive every 10 seconds, so 300 seconds holds about 30 per
        /// transaction, which matches the maintenance schedule. A hard crash can lose up to this much raw history.
        public var batchAge: TimeInterval = 300
        /// Most points kept while writes fail. The oldest are dropped first, and the drop is counted.
        public var maximumPending = 1_000
        public var maintenanceInterval: TimeInterval = 300

        public init() {}
    }

    public struct Statistics: Equatable, Sendable {
        public var acceptedSnapshots = 0
        public var throttledSnapshots = 0
        public var transactions = 0
        public var rowsWritten = 0
        public var droppedPoints = 0
        public var maintenanceRuns = 0
        public var rowsPruned = 0

        public init() {}
    }

    public private(set) var statistics = Statistics()
    /// Failure of the most recent write attempt. The next successful write clears it.
    public private(set) var lastWriteError: String?
    /// Failure of the most recent rollup or prune. The next successful one clears it.
    public private(set) var lastMaintenanceError: String?
    /// Set when a damaged file was moved aside at open.
    public nonisolated let recoveryNote: String?

    private static let schemaVersion = 1

    private let database: SQLiteDatabase
    private let retention: HistoryRetention
    private let configuration: Configuration
    private var pending: [HistoryPoint] = []
    private var lastAccepted: TimeInterval?
    private var lastMaintenance: TimeInterval?
    private var latestSnapshot: SystemSnapshot?

    /// Runs upkeep once at open, so points that expired while the app was closed are pruned before the first read.
    private init(
        database: SQLiteDatabase,
        retention: HistoryRetention,
        configuration: Configuration,
        recoveryNote: String?,
        now: TimeInterval
    ) {
        self.database = database
        self.retention = retention
        self.configuration = configuration
        self.recoveryNote = recoveryNote
        do {
            statistics.rowsPruned += try Self.upkeep(database, retention: retention, now: now)
            statistics.maintenanceRuns += 1
        } catch {
            lastMaintenanceError = describeStorageError(error)
        }
        lastMaintenance = now
    }

    // MARK: Opening

    /// Opens (or creates) the history file at `url`. A file that fails the integrity check is moved aside first.
    public static func open(
        at url: URL,
        retention: HistoryRetention = .default,
        configuration: Configuration = Configuration(),
        now: Date = Date()
    ) throws -> MetricHistoryStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var recoveryNote: String?
        if FileManager.default.fileExists(atPath: url.path), let reason = damageReason(atPath: url.path) {
            recoveryNote = try quarantine(url, reason: reason, now: now)
        }
        let database = try SQLiteDatabase(path: url.path)
        try prepare(database)
        return MetricHistoryStore(
            database: database,
            retention: retention,
            configuration: configuration,
            recoveryNote: recoveryNote,
            now: now.timeIntervalSince1970
        )
    }

    /// A store that keeps everything in memory, for this session only.
    public static func inMemory(
        retention: HistoryRetention = .default,
        configuration: Configuration = Configuration()
    ) throws -> MetricHistoryStore {
        let database = try SQLiteDatabase(path: ":memory:")
        try prepare(database)
        return MetricHistoryStore(
            database: database,
            retention: retention,
            configuration: configuration,
            recoveryNote: nil,
            now: Date().timeIntervalSince1970
        )
    }

    /// Application Support, under `MacFleet/history.sqlite`.
    public static func defaultLocation() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent("MacFleet", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    private static func prepare(_ database: SQLiteDatabase) throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        let version = try database.userVersion()
        if version == 0 {
            try database.transaction {
                try database.execute(schema)
                try database.execute("PRAGMA user_version = \(schemaVersion)")
            }
        } else if version != schemaVersion {
            throw HistoryError.unsupportedSchema(version: version)
        }
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS points (
            tier INTEGER NOT NULL,
            start REAL NOT NULL,
            samples INTEGER NOT NULL,
            cpu_sum REAL NOT NULL, cpu_n INTEGER NOT NULL, cpu_max REAL,
            mem_sum REAL NOT NULL, mem_n INTEGER NOT NULL, mem_max REAL,
            rx_sum REAL NOT NULL, rx_n INTEGER NOT NULL, rx_max REAL,
            tx_sum REAL NOT NULL, tx_n INTEGER NOT NULL, tx_max REAL,
            PRIMARY KEY (tier, start)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS volume_points (
            tier INTEGER NOT NULL,
            start REAL NOT NULL,
            mount TEXT NOT NULL,
            value_sum REAL NOT NULL,
            value_n INTEGER NOT NULL,
            value_max REAL NOT NULL,
            PRIMARY KEY (tier, start, mount)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY NOT NULL,
            value REAL NOT NULL
        ) WITHOUT ROWID;
        """

    /// Whether the file fails the integrity check, and why. Nil means it is healthy.
    private static func damageReason(atPath path: String) -> String? {
        do {
            let database = try SQLiteDatabase(path: path)
            defer { database.close() }
            let status = try database.integrityStatus()
            return status == "ok" ? nil : status
        } catch {
            return describeStorageError(error)
        }
    }

    /// Moves a damaged file, with its journal files, aside so it can be inspected. Nothing is deleted.
    private static func quarantine(_ url: URL, reason: String, now: Date) throws -> String {
        let suffix = "damaged-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(suffix)")
        for journal in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + journal)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.moveItem(at: source, to: URL(fileURLWithPath: target.path + journal))
        }
        return "The history file was damaged (\(reason)) and was moved to \(target.lastPathComponent). A new history file was started."
    }

    // MARK: Writing

    public func save(_ snapshot: SystemSnapshot) async {
        latestSnapshot = snapshot
        let time = snapshot.capturedAt.timeIntervalSince1970
        if let last = lastAccepted, time >= last, time - last < configuration.rawResolution - 0.5 {
            statistics.throttledSnapshots += 1
            return
        }
        lastAccepted = time
        statistics.acceptedSnapshots += 1
        pending.append(HistoryPoint(snapshot: snapshot))
        if pending.count >= configuration.batchSize || time - (pending.first?.start ?? time) >= configuration.batchAge {
            commitPending()
        }
        if let last = lastMaintenance, abs(time - last) < configuration.maintenanceInterval {
            return
        }
        maintain(now: time)
    }

    public func latest() async -> SystemSnapshot? {
        latestSnapshot
    }

    public func flush() async {
        commitPending()
    }

    /// Writes the buffer. A failure keeps the points for the next attempt, up to `maximumPending`.
    private func commitPending() {
        guard !pending.isEmpty else { return }
        do {
            let rows = try writePending()
            statistics.transactions += 1
            statistics.rowsWritten += rows
            pending.removeAll(keepingCapacity: true)
            lastWriteError = nil
        } catch {
            lastWriteError = describeStorageError(error)
            let excess = pending.count - configuration.maximumPending
            if excess > 0 {
                pending.removeFirst(excess)
                statistics.droppedPoints += excess
            }
        }
    }

    private func writePending() throws -> Int {
        let pointStatement = try database.prepare(Self.insertPointSQL)
        let volumeStatement = try database.prepare(Self.insertVolumeSQL)
        return try database.transaction {
            var rows = 0
            for point in pending {
                try insert(point, points: pointStatement, volumes: volumeStatement)
                rows += 1 + point.volumes.count
            }
            return rows
        }
    }

    private func insert(_ point: HistoryPoint, points: SQLiteStatement, volumes: SQLiteStatement) throws {
        try points.reset()
        try points.bind(HistoryTier.raw.rawValue, at: 1)
        try points.bind(point.start, at: 2)
        try points.bind(point.samples, at: 3)
        var index: Int32 = 4
        for aggregate in [point.cpu, point.memory, point.download, point.upload] {
            try points.bind(aggregate.sum, at: index)
            try points.bind(aggregate.count, at: index + 1)
            try points.bind(aggregate.maximum, at: index + 2)
            index += 3
        }
        _ = try points.step()

        for (mountPoint, aggregate) in point.volumes {
            try volumes.reset()
            try volumes.bind(HistoryTier.raw.rawValue, at: 1)
            try volumes.bind(point.start, at: 2)
            try volumes.bind(mountPoint, at: 3)
            try volumes.bind(aggregate.sum, at: 4)
            try volumes.bind(aggregate.count, at: 5)
            try volumes.bind(aggregate.maximum, at: 6)
            _ = try volumes.step()
        }
    }

    private static let insertPointSQL = """
        INSERT OR REPLACE INTO points
            (tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
        """

    private static let insertVolumeSQL = """
        INSERT OR REPLACE INTO volume_points (tier, start, mount, value_sum, value_n, value_max)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        """

    // MARK: Reading

    /// Points of `tier` that start within [from, to). Where `tier` has not rolled up yet, the finer tiers supply the
    /// points, so the result is complete for the whole span.
    public func points(in tier: HistoryTier, from: Date, to: Date) throws -> [HistoryPoint] {
        commitPending()
        return try collect(tier, from: from.timeIntervalSince1970, to: to.timeIntervalSince1970)
    }

    public func series(range: HistoryRange, now: Date) async throws -> HistorySeries {
        commitPending()
        let window = HistorySeries.window(range: range, now: now)
        let points = try collect(range.tier, from: window.start, to: window.end)
        return HistorySeries.build(range: range, start: window.start, end: window.end, points: points)
    }

    public func notice() async -> String? {
        if let recoveryNote {
            return recoveryNote
        }
        if let lastWriteError {
            return "History is not being saved: \(lastWriteError)"
        }
        return lastMaintenanceError.map { "History upkeep failed: \($0)" }
    }

    private func collect(_ tier: HistoryTier, from: TimeInterval, to: TimeInterval) throws -> [HistoryPoint] {
        guard from < to else { return [] }
        let horizon = try Self.horizon(tier, in: database)
        var result: [HistoryPoint] = []
        let coveredEnd = min(to, horizon)
        if from < coveredEnd {
            result += try storedPoints(tier: tier, from: from, to: coveredEnd)
        }
        if horizon < to, let finer = tier.source {
            result += try collect(finer, from: max(from, horizon), to: to)
        }
        return result
    }

    private func storedPoints(tier: HistoryTier, from: TimeInterval, to: TimeInterval) throws -> [HistoryPoint] {
        let points = try database.prepare(Self.selectPointsSQL)
        try Self.bindRange(points, tier: tier, from: from, to: to)
        var result: [HistoryPoint] = []
        var positions: [TimeInterval: Int] = [:]
        while try points.step() {
            positions[points.double(at: 0)] = result.count
            result.append(HistoryPoint(
                start: points.double(at: 0),
                samples: points.int(at: 1),
                cpu: Self.aggregate(points, at: 2),
                memory: Self.aggregate(points, at: 5),
                download: Self.aggregate(points, at: 8),
                upload: Self.aggregate(points, at: 11)
            ))
        }

        let volumes = try database.prepare(Self.selectVolumesSQL)
        try Self.bindRange(volumes, tier: tier, from: from, to: to)
        while try volumes.step() {
            let start = volumes.double(at: 0)
            guard let position = positions[start] else {
                throw HistoryError.inconsistent("a volume row has no matching point at \(start)")
            }
            result[position].volumes[volumes.text(at: 1)] = Self.aggregate(volumes, at: 2)
        }
        return result
    }

    private static func bindRange(_ statement: SQLiteStatement, tier: HistoryTier, from: TimeInterval, to: TimeInterval) throws {
        try statement.bind(tier.rawValue, at: 1)
        try statement.bind(from, at: 2)
        try statement.bind(to, at: 3)
    }

    private static func aggregate(_ statement: SQLiteStatement, at column: Int32) -> MetricAggregate {
        MetricAggregate(
            sum: statement.double(at: column),
            count: statement.int(at: column + 1),
            maximum: statement.optionalDouble(at: column + 2)
        )
    }

    private static let selectPointsSQL = """
        SELECT start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max
        FROM points WHERE tier = ?1 AND start >= ?2 AND start < ?3
        ORDER BY start
        """

    private static let selectVolumesSQL = """
        SELECT start, mount, value_sum, value_n, value_max
        FROM volume_points WHERE tier = ?1 AND start >= ?2 AND start < ?3
        ORDER BY start, mount
        """

    // MARK: Maintenance

    /// Rolls up closed buckets, then prunes. Failures are recorded rather than thrown. A failed run leaves the horizons
    /// where they were, so the next run retries the same span. Pending points are written first, so a rollup never
    /// passes a point that is still in memory.
    func maintain(now: TimeInterval) {
        lastMaintenance = now
        commitPending()
        guard pending.isEmpty else {
            lastMaintenanceError = "rollup skipped while writes fail: \(lastWriteError ?? "unknown error")"
            return
        }
        do {
            statistics.rowsPruned += try Self.upkeep(database, retention: retention, now: now)
            statistics.maintenanceRuns += 1
            lastMaintenanceError = nil
        } catch {
            lastMaintenanceError = describeStorageError(error)
        }
    }

    /// One transaction: rollup first, then prune, so the rollup and the prune can never disagree.
    private static func upkeep(_ database: SQLiteDatabase, retention: HistoryRetention, now: TimeInterval) throws -> Int {
        try database.transaction {
            let fiveMinuteHorizon = try horizon(.fiveMinute, in: database)
            let fiveMinuteWidth = Double(HistoryTier.fiveMinute.width)
            let fiveMinuteEnd = floor(now / fiveMinuteWidth) * fiveMinuteWidth
            var fiveMinuteComplete = fiveMinuteHorizon
            if fiveMinuteEnd > fiveMinuteHorizon {
                try rollUp(.raw, into: .fiveMinute, from: fiveMinuteHorizon, to: fiveMinuteEnd, in: database)
                try setHorizon(.fiveMinute, to: fiveMinuteEnd, in: database)
                fiveMinuteComplete = fiveMinuteEnd
            }

            let hourlyHorizon = try horizon(.hourly, in: database)
            let hourlyWidth = Double(HistoryTier.hourly.width)
            let hourlyEnd = floor(min(fiveMinuteComplete, now) / hourlyWidth) * hourlyWidth
            if hourlyEnd > hourlyHorizon {
                try rollUp(.fiveMinute, into: .hourly, from: hourlyHorizon, to: hourlyEnd, in: database)
                try setHorizon(.hourly, to: hourlyEnd, in: database)
            }

            var pruned = 0
            for tier in HistoryTier.allCases {
                pruned += try prune(tier, before: now - retention.retention(for: tier), in: database)
            }
            return pruned
        }
    }

    /// Time up to which `tier` is complete. Raw points are always complete.
    private static func horizon(_ tier: HistoryTier, in database: SQLiteDatabase) throws -> TimeInterval {
        guard tier != .raw else { return .infinity }
        let statement = try database.prepare("SELECT value FROM meta WHERE key = ?1")
        try statement.bind(tier.horizonKey, at: 1)
        return try statement.step() ? statement.double(at: 0) : 0
    }

    private static func setHorizon(_ tier: HistoryTier, to value: TimeInterval, in database: SQLiteDatabase) throws {
        let statement = try database.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)")
        try statement.bind(tier.horizonKey, at: 1)
        try statement.bind(value, at: 2)
        _ = try statement.step()
    }

    /// Aggregates the source tier's buckets in [start, end) into the target tier. Each bucket is keyed by the
    /// target's width, so repeated runs over the same span produce the same rows.
    private static func rollUp(
        _ source: HistoryTier,
        into target: HistoryTier,
        from start: TimeInterval,
        to end: TimeInterval,
        in database: SQLiteDatabase
    ) throws {
        let width = target.width
        let bucket = "CAST(start / \(width) AS INTEGER) * \(width)"
        let points = try database.prepare("""
            INSERT OR REPLACE INTO points
                (tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max)
            SELECT \(target.rawValue), \(bucket), SUM(samples),
                SUM(cpu_sum), SUM(cpu_n), MAX(cpu_max),
                SUM(mem_sum), SUM(mem_n), MAX(mem_max),
                SUM(rx_sum), SUM(rx_n), MAX(rx_max),
                SUM(tx_sum), SUM(tx_n), MAX(tx_max)
            FROM points WHERE tier = \(source.rawValue) AND start >= ?1 AND start < ?2
            GROUP BY \(bucket)
            """)
        try points.bind(start, at: 1)
        try points.bind(end, at: 2)
        _ = try points.step()

        let volumes = try database.prepare("""
            INSERT OR REPLACE INTO volume_points (tier, start, mount, value_sum, value_n, value_max)
            SELECT \(target.rawValue), \(bucket), mount, SUM(value_sum), SUM(value_n), MAX(value_max)
            FROM volume_points WHERE tier = \(source.rawValue) AND start >= ?1 AND start < ?2
            GROUP BY \(bucket), mount
            """)
        try volumes.bind(start, at: 1)
        try volumes.bind(end, at: 2)
        _ = try volumes.step()
    }

    private static func prune(_ tier: HistoryTier, before cutoff: TimeInterval, in database: SQLiteDatabase) throws -> Int {
        let points = try database.prepare("DELETE FROM points WHERE tier = ?1 AND start < ?2")
        try points.bind(tier.rawValue, at: 1)
        try points.bind(cutoff, at: 2)
        _ = try points.step()
        let removed = database.changes

        let volumes = try database.prepare("DELETE FROM volume_points WHERE tier = ?1 AND start < ?2")
        try volumes.bind(tier.rawValue, at: 1)
        try volumes.bind(cutoff, at: 2)
        _ = try volumes.step()
        return removed + database.changes
    }

    // MARK: Inspection and test seams

    /// Rows stored for `tier`: points and volume rows.
    func rowCount(_ tier: HistoryTier) throws -> (points: Int, volumes: Int) {
        let points = try database.prepare("SELECT COUNT(*) FROM points WHERE tier = ?1")
        try points.bind(tier.rawValue, at: 1)
        _ = try points.step()
        let volumes = try database.prepare("SELECT COUNT(*) FROM volume_points WHERE tier = ?1")
        try volumes.bind(tier.rawValue, at: 1)
        _ = try volumes.step()
        return (points.int(at: 0), volumes.int(at: 0))
    }

    /// The query plan for reading `tier`, one line per step.
    func queryPlan(for tier: HistoryTier) throws -> [String] {
        let statement = try database.prepare("EXPLAIN QUERY PLAN " + Self.selectPointsSQL)
        try Self.bindRange(statement, tier: tier, from: 0, to: 1)
        var details: [String] = []
        while try statement.step() {
            details.append(statement.text(at: 3))
        }
        return details
    }

    /// Makes writes fail (`PRAGMA query_only`), so failure handling can be exercised.
    func setWritesEnabled(_ enabled: Bool) throws {
        try database.execute("PRAGMA query_only = \(enabled ? "OFF" : "ON")")
    }
}
