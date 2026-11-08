import Foundation

/// Persistent metric history for every monitored computer. The store is the sampling engine's `SnapshotStoring`, so
/// every local collection reaches it. Remote Macs reach it through `ingest`. It answers the time-range queries behind
/// the history charts, the comparisons, the summaries, and the exports.
///
/// - Hosts: every row is keyed by a `HistoryHostID`, and rollup, retention, horizons, and clock state are kept per host.
///   Metrics from different hosts never share a row, a bucket, or a horizon.
/// - Clock: a remote sample is placed by the time this Mac received it, not by the host's clock. The host's offset is
///   recorded and reported when it is large, so comparisons stay aligned. A sample that arrives after this Mac's clock
///   moved back past the last one is dropped and counted, rather than stored out of order.
/// - Downsampling: snapshots closer together than `rawResolution` are skipped. The default keeps one point every
///   10 seconds, so the 2-second popover cadence does not multiply writes.
/// - Batching: points from all hosts are buffered and written in one transaction when the buffer reaches `batchSize`,
///   when its oldest point is `batchAge` seconds old, and before any read, rollup, suspend, or shutdown.
/// - Aggregation: closed five-minute buckets are rolled up from raw points, and closed hour buckets from five-minute
///   buckets. Each host and tier records a horizon, the time up to which it is complete. A read takes each span from the
///   coarsest tier that covers it and fills the rest from the next finer tier, so a bucket that has not been rolled up
///   yet is neither missing nor counted twice.
/// - Retention: after each rollup, every host's tiers are pruned to that host's retention, or to the default. Rollup runs
///   before pruning, so no raw point is deleted before it is aggregated.
/// - Recovery: each write is one transaction, so an interrupted write leaves no partial state. A file that fails the
///   integrity check is moved aside with its journal files, and a new store is started. `recoveryNote` reports it.
public actor MetricHistoryStore: SnapshotStoring, HistorySource, FleetHistoryStoring {
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
        public var duplicateSnapshots = 0
        public var clockRegressions = 0
        /// Changes of more than 30 seconds between two readings of a host's clock.
        public var clockSteps = 0
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

    /// A local clock step back by more than this loses the samples that follow it. Smaller steps are treated as jitter.
    static let clockRegressionTolerance: TimeInterval = 5
    /// A change of more than this between two readings of a host's clock is counted as a step.
    static let clockStepThreshold: TimeInterval = 30
    /// A bucket is rolled up only this long after it ends. Samples are timed when they are received and stored a moment
    /// later, so a sample timed just before a rollup can still arrive after it. The grace keeps it in its bucket.
    static let closeGrace: TimeInterval = 120
    static let schemaVersion = 2

    private let database: SQLiteDatabase
    private let retention: HistoryRetention
    private let configuration: Configuration
    private var pending: [PendingPoint] = []
    private var lastAccepted: [String: TimeInterval] = [:]
    private var lastHostTime: [String: TimeInterval] = [:]
    private var clocks: [String: ClockRecord] = [:]
    private var unsavedClocks: Set<String> = []
    private var lastMaintenance: TimeInterval?
    private var latestSnapshot: SystemSnapshot?
    /// True while this Mac's clock is behind the last recorded sample, so new samples are held.
    private var clockHeld = false

    private struct PendingPoint {
        let host: String
        let point: HistoryPoint
    }

    private struct ClockRecord {
        /// The host's clock minus this Mac's clock, in seconds, at the last accepted sample.
        var offset: Double
        var observed: TimeInterval
    }

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
            clocks = try Self.loadClocks(database)
        } catch {
            lastMaintenanceError = describeStorageError(error)
        }
        do {
            statistics.rowsPruned += try Self.upkeep(database, defaults: retention, now: now)
            statistics.maintenanceRuns += 1
        } catch {
            lastMaintenanceError = describeStorageError(error)
        }
        lastMaintenance = now
    }

    // MARK: Opening

    /// Opens (or creates) the history file at `url`. A file that fails the integrity check is moved aside first. A
    /// version 1 file is migrated: its rows become the local Mac's.
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
        switch version {
        case 0:
            try database.transaction {
                try database.execute(schema)
                try database.execute("PRAGMA user_version = \(schemaVersion)")
            }
        case 1:
            try database.transaction {
                try database.execute(migrationFromVersionOne)
                try database.execute("PRAGMA user_version = \(schemaVersion)")
            }
        case schemaVersion:
            break
        default:
            throw HistoryError.unsupportedSchema(version: version)
        }
        try database.transaction {
            try database.execute("INSERT OR IGNORE INTO hosts (host) VALUES ('\(HistoryHostID.local.rawValue)')")
        }
    }

    private static let schema = """
        CREATE TABLE IF NOT EXISTS hosts (
            host TEXT PRIMARY KEY NOT NULL,
            horizon_five REAL NOT NULL DEFAULT 0,
            horizon_hour REAL NOT NULL DEFAULT 0,
            raw_retention REAL,
            five_retention REAL,
            hourly_retention REAL,
            clock_offset REAL,
            clock_observed REAL
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS points (
            host TEXT NOT NULL,
            tier INTEGER NOT NULL,
            start REAL NOT NULL,
            samples INTEGER NOT NULL,
            cpu_sum REAL NOT NULL, cpu_n INTEGER NOT NULL, cpu_max REAL,
            mem_sum REAL NOT NULL, mem_n INTEGER NOT NULL, mem_max REAL,
            rx_sum REAL NOT NULL, rx_n INTEGER NOT NULL, rx_max REAL,
            tx_sum REAL NOT NULL, tx_n INTEGER NOT NULL, tx_max REAL,
            PRIMARY KEY (host, tier, start)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS volume_points (
            host TEXT NOT NULL,
            tier INTEGER NOT NULL,
            start REAL NOT NULL,
            mount TEXT NOT NULL,
            value_sum REAL NOT NULL,
            value_n INTEGER NOT NULL,
            value_max REAL NOT NULL,
            PRIMARY KEY (host, tier, start, mount)
        ) WITHOUT ROWID;
        """

    /// Version 1 kept one history, for the local Mac, with global horizons. Its rows move under the local host, and its
    /// horizons become that host's. Nothing is dropped.
    private static let migrationFromVersionOne = """
        ALTER TABLE points RENAME TO points_v1;
        ALTER TABLE volume_points RENAME TO volume_points_v1;
        \(schema);
        INSERT INTO points
            (host, tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max)
            SELECT 'local', tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max
            FROM points_v1;
        INSERT INTO volume_points (host, tier, start, mount, value_sum, value_n, value_max)
            SELECT 'local', tier, start, mount, value_sum, value_n, value_max FROM volume_points_v1;
        INSERT OR REPLACE INTO hosts (host, horizon_five, horizon_hour)
            VALUES ('local',
                COALESCE((SELECT value FROM meta WHERE key = 'horizon.1'), 0),
                COALESCE((SELECT value FROM meta WHERE key = 'horizon.2'), 0));
        DROP TABLE points_v1;
        DROP TABLE volume_points_v1;
        DROP TABLE IF EXISTS meta;
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
        let outcome = admit(
            host: HistoryHostID.local.rawValue,
            arrival: time,
            hostTime: nil,
            point: HistoryPoint(snapshot: snapshot)
        )
        if outcome == .accepted {
            maintainIfDue(now: time)
        }
    }

    public func ingest(_ snapshot: RemoteSnapshot, from host: HistoryHostID, receivedAt: Date) async -> HistoryIngestOutcome {
        let arrival = receivedAt.timeIntervalSince1970
        let outcome = admit(
            host: host.rawValue,
            arrival: arrival,
            hostTime: snapshot.capturedAt.timeIntervalSince1970,
            point: HistoryPoint(remote: snapshot, start: arrival)
        )
        if outcome == .accepted {
            maintainIfDue(now: arrival)
        }
        return outcome
    }

    public func latest() async -> SystemSnapshot? {
        latestSnapshot
    }

    public func flush() async {
        commitPending()
    }

    /// Accepts or refuses one point. `arrival` is this Mac's time for the sample, and `hostTime` is the host's own time,
    /// when it has one. Only `arrival` orders and places the point.
    private func admit(host: String, arrival: TimeInterval, hostTime: TimeInterval?, point: @autoclosure () -> HistoryPoint) -> HistoryIngestOutcome {
        if let last = lastAccepted[host], arrival < last - Self.clockRegressionTolerance {
            statistics.clockRegressions += 1
            clockHeld = true
            return .clockRegressed
        }
        if let hostTime, lastHostTime[host] == hostTime {
            statistics.duplicateSnapshots += 1
            return .duplicate
        }
        if let last = lastAccepted[host], arrival - last < configuration.rawResolution - 0.5 {
            statistics.throttledSnapshots += 1
            return .throttled
        }

        lastAccepted[host] = arrival
        if let hostTime {
            lastHostTime[host] = hostTime
            recordClock(host, offset: hostTime - arrival)
        }
        statistics.acceptedSnapshots += 1
        clockHeld = false
        pending.append(PendingPoint(host: host, point: point()))
        if pending.count >= configuration.batchSize || arrival - (pending.first?.point.start ?? arrival) >= configuration.batchAge {
            commitPending()
        }
        return .accepted
    }

    private func recordClock(_ host: String, offset: Double) {
        if let previous = clocks[host], abs(offset - previous.offset) > Self.clockStepThreshold {
            statistics.clockSteps += 1
        }
        clocks[host] = ClockRecord(offset: offset, observed: lastAccepted[host] ?? 0)
        unsavedClocks.insert(host)
    }

    private func maintainIfDue(now: TimeInterval) {
        if let last = lastMaintenance, abs(now - last) < configuration.maintenanceInterval {
            return
        }
        maintain(now: now)
    }

    /// Writes the buffer. A failure keeps the points for the next attempt, up to `maximumPending`.
    private func commitPending() {
        guard !pending.isEmpty else { return }
        do {
            let rows = try writePending()
            statistics.transactions += 1
            statistics.rowsWritten += rows
            pending.removeAll(keepingCapacity: true)
            unsavedClocks.removeAll()
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
        let hostStatement = try database.prepare(Self.ensureHostSQL)
        let clockStatement = try database.prepare(Self.saveClockSQL)
        return try database.transaction {
            for host in Set(pending.map(\.host)) {
                try hostStatement.reset()
                try hostStatement.bind(host, at: 1)
                _ = try hostStatement.step()
            }
            var rows = 0
            for entry in pending {
                try insert(entry, points: pointStatement, volumes: volumeStatement)
                rows += 1 + entry.point.volumes.count
            }
            for host in unsavedClocks {
                guard let record = clocks[host] else { continue }
                try clockStatement.reset()
                try clockStatement.bind(host, at: 1)
                try clockStatement.bind(record.offset, at: 2)
                try clockStatement.bind(record.observed, at: 3)
                _ = try clockStatement.step()
            }
            return rows
        }
    }

    private func insert(_ entry: PendingPoint, points: SQLiteStatement, volumes: SQLiteStatement) throws {
        let point = entry.point
        try points.reset()
        try points.bind(entry.host, at: 1)
        try points.bind(HistoryTier.raw.rawValue, at: 2)
        try points.bind(point.start, at: 3)
        try points.bind(point.samples, at: 4)
        var index: Int32 = 5
        for aggregate in [point.cpu, point.memory, point.download, point.upload] {
            try points.bind(aggregate.sum, at: index)
            try points.bind(aggregate.count, at: index + 1)
            try points.bind(aggregate.maximum, at: index + 2)
            index += 3
        }
        _ = try points.step()

        for (mountPoint, aggregate) in point.volumes {
            try volumes.reset()
            try volumes.bind(entry.host, at: 1)
            try volumes.bind(HistoryTier.raw.rawValue, at: 2)
            try volumes.bind(point.start, at: 3)
            try volumes.bind(mountPoint, at: 4)
            try volumes.bind(aggregate.sum, at: 5)
            try volumes.bind(aggregate.count, at: 6)
            try volumes.bind(aggregate.maximum, at: 7)
            _ = try volumes.step()
        }
    }

    private static let insertPointSQL = """
        INSERT OR REPLACE INTO points
            (host, tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
        """

    private static let insertVolumeSQL = """
        INSERT OR REPLACE INTO volume_points (host, tier, start, mount, value_sum, value_n, value_max)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
        """

    private static let ensureHostSQL = "INSERT OR IGNORE INTO hosts (host) VALUES (?1)"

    private static let saveClockSQL = "UPDATE hosts SET clock_offset = ?2, clock_observed = ?3 WHERE host = ?1"

    // MARK: Reading

    /// Points of `tier` for `host` that start within [from, to). Where `tier` has not rolled up yet, the finer tiers
    /// supply the points, so the result is complete for the whole span.
    public func points(host: HistoryHostID = .local, in tier: HistoryTier, from: Date, to: Date) throws -> [HistoryPoint] {
        commitPending()
        return try collect(host, tier, from: from.timeIntervalSince1970, to: to.timeIntervalSince1970).map(\.point)
    }

    public func series(range: HistoryRange, now: Date) async throws -> HistorySeries {
        try await series(host: .local, range: range, now: now)
    }

    public func series(host: HistoryHostID, range: HistoryRange, now: Date) async throws -> HistorySeries {
        commitPending()
        let window = HistorySeries.window(range: range, now: now)
        let points = try collect(host, range.tier, from: window.start, to: window.end).map(\.point)
        return HistorySeries.build(range: range, start: window.start, end: window.end, points: points)
    }

    /// Totals for one host over [from, to). Whole hourly buckets come from the hourly tier, so the cost does not grow with
    /// the window's length. Partial edges come from the finer tiers, and raw points are pruned once rolled up, so totals are
    /// exact for windows whose ends fall on five-minute boundaries. Other windows are exact only while their edge raw points
    /// are still stored. The app's windows are aligned to their chart slots, so this does not affect them.
    public func summary(host: HistoryHostID, from: Date, to: Date) async throws -> HostWindowSummary {
        commitPending()
        let parts = try summarize(host.rawValue, .hourly, from: from.timeIntervalSince1970, to: to.timeIntervalSince1970)
        return HostWindowSummary(
            host: host,
            from: from,
            to: to,
            samples: parts.samples,
            cpu: parts.cpu,
            memory: parts.memory,
            download: parts.download,
            upload: parts.upload,
            disk: parts.disk,
            lastSample: parts.lastSample.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// One row per host, bucket, and metric. The tier is the finest one that keeps each host within `maximumPoints`. Rows
    /// from a finer tier appear only at the window's ends, where a partial bucket has to be read from it. The same edge rule
    /// as `summary` applies to windows that do not start and end on five-minute boundaries.
    public func exportRows(hosts: [HistoryHostID], from: Date, to: Date, maximumPoints: Int) async throws -> [HistoryExportRow] {
        commitPending()
        let start = from.timeIntervalSince1970
        let end = to.timeIntervalSince1970
        let tier = HistoryResolution.tier(span: end - start, maximumPoints: maximumPoints, rawResolution: configuration.rawResolution)
        var rows: [HistoryExportRow] = []
        for host in hosts {
            for entry in try collect(host, tier, from: start, to: end) {
                let point = entry.point
                let volumes = point.volumes.sorted { $0.key < $1.key }.map { (name: "disk:\($0.key)", aggregate: $0.value) }
                let metrics: [(name: String, aggregate: MetricAggregate)] = [
                    ("cpu", point.cpu),
                    ("memory", point.memory),
                    ("download_bytes_per_second", point.download),
                    ("upload_bytes_per_second", point.upload),
                ] + volumes
                for metric in metrics {
                    rows.append(HistoryExportRow(
                        time: Date(timeIntervalSince1970: point.start),
                        resolution: entry.tier,
                        host: host,
                        metric: metric.name,
                        mean: metric.aggregate.mean,
                        maximum: metric.aggregate.maximum,
                        observations: metric.aggregate.count,
                        snapshots: point.samples
                    ))
                }
            }
        }
        return rows
    }

    public func clockStatus(host: HistoryHostID) async -> HostClockStatus {
        if host.isLocal {
            return .aligned
        }
        guard let record = clocks[host.rawValue] else { return .unknown }
        return HostClockStatus.classify(offset: record.offset)
    }

    public func retention(for host: HistoryHostID) async throws -> HistoryRetention? {
        try Self.policy(host.rawValue, in: database)
    }

    public func setRetention(_ policy: HistoryRetention?, for host: HistoryHostID) async throws {
        commitPending()
        try database.transaction {
            let ensure = try database.prepare(Self.ensureHostSQL)
            try ensure.bind(host.rawValue, at: 1)
            _ = try ensure.step()
            let update = try database.prepare(
                "UPDATE hosts SET raw_retention = ?2, five_retention = ?3, hourly_retention = ?4 WHERE host = ?1"
            )
            try update.bind(host.rawValue, at: 1)
            try update.bind(policy?.raw, at: 2)
            try update.bind(policy?.fiveMinute, at: 3)
            try update.bind(policy?.hourly, at: 4)
            _ = try update.step()
        }
        maintain(now: Date().timeIntervalSince1970)
    }

    public func storedHosts() async throws -> [HistoryHostID] {
        let statement = try database.prepare("SELECT host FROM hosts ORDER BY host")
        var hosts: [HistoryHostID] = []
        while try statement.step() {
            hosts.append(HistoryHostID(rawValue: statement.text(at: 0)))
        }
        return hosts
    }

    public func removeHistory(for host: HistoryHostID) async throws -> Int {
        pending.removeAll { $0.host == host.rawValue }
        unsavedClocks.remove(host.rawValue)
        clocks[host.rawValue] = nil
        lastAccepted[host.rawValue] = nil
        lastHostTime[host.rawValue] = nil
        return try database.transaction {
            var removed = 0
            for sql in ["DELETE FROM points WHERE host = ?1", "DELETE FROM volume_points WHERE host = ?1", "DELETE FROM hosts WHERE host = ?1"] {
                let statement = try database.prepare(sql)
                try statement.bind(host.rawValue, at: 1)
                _ = try statement.step()
                removed += database.changes
            }
            return removed
        }
    }

    public func notice() async -> String? {
        if let recoveryNote {
            return recoveryNote
        }
        if let lastWriteError {
            return "History is not being saved: \(lastWriteError)"
        }
        if clockHeld {
            return "This Mac's clock moved back. New snapshots are held until it passes the last recorded time, so nothing is stored out of order."
        }
        return lastMaintenanceError.map { "History upkeep failed: \($0)" }
    }

    /// Points of `tier` in [from, to). A coarse bucket is taken only when it lies wholly inside the span and is complete.
    /// The partial buckets at either end come from the finer tier, so no bucket is counted twice or cut in half.
    /// A point together with the tier it was read from, so an export labels each row with its real bucket width.
    private struct TaggedPoint {
        let tier: HistoryTier
        let point: HistoryPoint
    }

    private func collect(_ host: HistoryHostID, _ tier: HistoryTier, from: TimeInterval, to: TimeInterval) throws -> [TaggedPoint] {
        guard from < to else { return [] }
        guard let finer = tier.source else {
            return try tagged(tier, storedPoints(host.rawValue, tier, from: from, to: to))
        }
        let whole = try wholeBuckets(host.rawValue, tier, from: from, to: to)
        guard whole.start < whole.end else {
            return try collect(host, finer, from: from, to: to)
        }
        var result = try collect(host, finer, from: from, to: whole.start)
        result += try tagged(tier, storedPoints(host.rawValue, tier, from: whole.start, to: whole.end))
        result += try collect(host, finer, from: whole.end, to: to)
        return result
    }

    private func tagged(_ tier: HistoryTier, _ points: [HistoryPoint]) -> [TaggedPoint] {
        points.map { TaggedPoint(tier: tier, point: $0) }
    }

    /// The span of `tier`'s complete buckets that lie inside [from, to). It may be empty, when start is not before end.
    private func wholeBuckets(_ host: String, _ tier: HistoryTier, from: TimeInterval, to: TimeInterval) throws -> (start: TimeInterval, end: TimeInterval) {
        let width = Double(tier.width)
        let horizon = try Self.horizon(host, tier, in: database)
        return (ceil(from / width) * width, floor(min(to, horizon) / width) * width)
    }

    private func storedPoints(_ host: String, _ tier: HistoryTier, from: TimeInterval, to: TimeInterval) throws -> [HistoryPoint] {
        let points = try database.prepare(Self.selectPointsSQL)
        try Self.bindRange(points, host: host, tier: tier, from: from, to: to)
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
        try Self.bindRange(volumes, host: host, tier: tier, from: from, to: to)
        while try volumes.step() {
            let start = volumes.double(at: 0)
            guard let position = positions[start] else {
                throw HistoryError.inconsistent("a volume row has no matching point at \(start)")
            }
            result[position].volumes[volumes.text(at: 1)] = Self.aggregate(volumes, at: 2)
        }
        return result
    }

    private static func bindRange(
        _ statement: SQLiteStatement,
        host: String,
        tier: HistoryTier,
        from: TimeInterval,
        to: TimeInterval
    ) throws {
        try statement.bind(host, at: 1)
        try statement.bind(tier.rawValue, at: 2)
        try statement.bind(from, at: 3)
        try statement.bind(to, at: 4)
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
        FROM points WHERE host = ?1 AND tier = ?2 AND start >= ?3 AND start < ?4
        ORDER BY start
        """

    private static let selectVolumesSQL = """
        SELECT start, mount, value_sum, value_n, value_max
        FROM volume_points WHERE host = ?1 AND tier = ?2 AND start >= ?3 AND start < ?4
        ORDER BY start, mount
        """

    /// The merged totals of one span, built from every tier that holds part of it.
    private struct SummaryParts {
        var samples = 0
        var cpu = MetricAggregate()
        var memory = MetricAggregate()
        var download = MetricAggregate()
        var upload = MetricAggregate()
        var disk = MetricAggregate()
        var lastSample: TimeInterval?

        mutating func merge(_ other: SummaryParts) {
            samples += other.samples
            cpu.merge(other.cpu)
            memory.merge(other.memory)
            download.merge(other.download)
            upload.merge(other.upload)
            disk.merge(other.disk)
            if let other = other.lastSample {
                lastSample = Swift.max(lastSample ?? other, other)
            }
        }
    }

    /// Totals for [from, to), using the same whole-bucket split as `collect`, so a total is the same at every tier.
    private func summarize(_ host: String, _ tier: HistoryTier, from: TimeInterval, to: TimeInterval) throws -> SummaryParts {
        guard from < to else { return SummaryParts() }
        guard let finer = tier.source else {
            return try storedSummary(host, tier, from: from, to: to)
        }
        let whole = try wholeBuckets(host, tier, from: from, to: to)
        guard whole.start < whole.end else {
            return try summarize(host, finer, from: from, to: to)
        }
        var parts = try summarize(host, finer, from: from, to: whole.start)
        parts.merge(try storedSummary(host, tier, from: whole.start, to: whole.end))
        parts.merge(try summarize(host, finer, from: whole.end, to: to))
        return parts
    }

    private func storedSummary(_ host: String, _ tier: HistoryTier, from: TimeInterval, to: TimeInterval) throws -> SummaryParts {
        let points = try database.prepare("""
            SELECT COALESCE(SUM(samples), 0),
                COALESCE(SUM(cpu_sum), 0), COALESCE(SUM(cpu_n), 0), MAX(cpu_max),
                COALESCE(SUM(mem_sum), 0), COALESCE(SUM(mem_n), 0), MAX(mem_max),
                COALESCE(SUM(rx_sum), 0), COALESCE(SUM(rx_n), 0), MAX(rx_max),
                COALESCE(SUM(tx_sum), 0), COALESCE(SUM(tx_n), 0), MAX(tx_max),
                MAX(start)
            FROM points WHERE host = ?1 AND tier = ?2 AND start >= ?3 AND start < ?4
            """)
        try Self.bindRange(points, host: host, tier: tier, from: from, to: to)
        _ = try points.step()

        let volumes = try database.prepare("""
            SELECT COALESCE(SUM(value_sum), 0), COALESCE(SUM(value_n), 0), MAX(value_max)
            FROM volume_points WHERE host = ?1 AND tier = ?2 AND start >= ?3 AND start < ?4
            """)
        try Self.bindRange(volumes, host: host, tier: tier, from: from, to: to)
        _ = try volumes.step()

        var parts = SummaryParts()
        parts.samples = points.int(at: 0)
        parts.cpu = Self.aggregate(points, at: 1)
        parts.memory = Self.aggregate(points, at: 4)
        parts.download = Self.aggregate(points, at: 7)
        parts.upload = Self.aggregate(points, at: 10)
        parts.disk = MetricAggregate(
            sum: volumes.double(at: 0),
            count: volumes.int(at: 1),
            maximum: volumes.optionalDouble(at: 2)
        )
        parts.lastSample = points.optionalDouble(at: 13)
        return parts
    }

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
            statistics.rowsPruned += try Self.upkeep(database, defaults: retention, now: now)
            statistics.maintenanceRuns += 1
            lastMaintenanceError = nil
        } catch {
            lastMaintenanceError = describeStorageError(error)
        }
    }

    /// One transaction for every host: rollup first, then prune, so the rollup and the prune can never disagree. Each host
    /// is judged by its own newest stored point, so a host that reports ahead of another cannot close the other's buckets.
    /// Pruning also stops at what is already rolled up, so no point is deleted before it has been aggregated. A host with
    /// nothing stored has nothing to roll up or prune.
    private static func upkeep(_ database: SQLiteDatabase, defaults: HistoryRetention, now: TimeInterval) throws -> Int {
        try database.transaction {
            var pruned = 0
            for host in try hostRows(in: database) {
                guard let newest = try newestRawPoint(host.id, in: database) else { continue }
                let hostNow = min(now, newest)
                let fiveMinuteWidth = Double(HistoryTier.fiveMinute.width)
                let fiveMinuteEnd = floor((hostNow - closeGrace) / fiveMinuteWidth) * fiveMinuteWidth
                var fiveMinuteComplete = host.fiveMinuteHorizon
                if fiveMinuteEnd > host.fiveMinuteHorizon {
                    try rollUp(host.id, .raw, into: .fiveMinute, from: host.fiveMinuteHorizon, to: fiveMinuteEnd, in: database)
                    fiveMinuteComplete = fiveMinuteEnd
                }

                let hourlyWidth = Double(HistoryTier.hourly.width)
                let hourlyEnd = floor(min(fiveMinuteComplete, hostNow - closeGrace) / hourlyWidth) * hourlyWidth
                var hourlyComplete = host.hourlyHorizon
                if hourlyEnd > host.hourlyHorizon {
                    try rollUp(host.id, .fiveMinute, into: .hourly, from: host.hourlyHorizon, to: hourlyEnd, in: database)
                    hourlyComplete = hourlyEnd
                }
                try setHorizons(host.id, fiveMinute: fiveMinuteComplete, hourly: hourlyComplete, in: database)

                let policy = host.retention ?? defaults
                pruned += try prune(host.id, .raw, before: min(now - policy.raw, fiveMinuteComplete), in: database)
                pruned += try prune(host.id, .fiveMinute, before: min(now - policy.fiveMinute, hourlyComplete), in: database)
                pruned += try prune(host.id, .hourly, before: now - policy.hourly, in: database)
            }
            return pruned
        }
    }

    /// The start of the host's newest raw point, or nil when it has none. Pending points are committed before upkeep runs.
    private static func newestRawPoint(_ host: String, in database: SQLiteDatabase) throws -> TimeInterval? {
        let statement = try database.prepare("SELECT MAX(start) FROM points WHERE host = ?1 AND tier = \(HistoryTier.raw.rawValue)")
        try statement.bind(host, at: 1)
        _ = try statement.step()
        return statement.optionalDouble(at: 0)
    }

    private struct HostRow {
        let id: String
        let fiveMinuteHorizon: TimeInterval
        let hourlyHorizon: TimeInterval
        let retention: HistoryRetention?
    }

    private static func hostRows(in database: SQLiteDatabase) throws -> [HostRow] {
        let statement = try database.prepare("""
            SELECT host, horizon_five, horizon_hour, raw_retention, five_retention, hourly_retention FROM hosts
            """)
        var rows: [HostRow] = []
        while try statement.step() {
            let policy: HistoryRetention?
            if let raw = statement.optionalDouble(at: 3), let five = statement.optionalDouble(at: 4),
               let hourly = statement.optionalDouble(at: 5) {
                policy = try HistoryRetention(raw: raw, fiveMinute: five, hourly: hourly)
            } else {
                policy = nil
            }
            rows.append(HostRow(
                id: statement.text(at: 0),
                fiveMinuteHorizon: statement.double(at: 1),
                hourlyHorizon: statement.double(at: 2),
                retention: policy
            ))
        }
        return rows
    }

    private static func policy(_ host: String, in database: SQLiteDatabase) throws -> HistoryRetention? {
        let statement = try database.prepare("SELECT raw_retention, five_retention, hourly_retention FROM hosts WHERE host = ?1")
        try statement.bind(host, at: 1)
        guard try statement.step(),
              let raw = statement.optionalDouble(at: 0),
              let five = statement.optionalDouble(at: 1),
              let hourly = statement.optionalDouble(at: 2)
        else {
            return nil
        }
        return try HistoryRetention(raw: raw, fiveMinute: five, hourly: hourly)
    }

    private static func loadClocks(_ database: SQLiteDatabase) throws -> [String: ClockRecord] {
        let statement = try database.prepare("SELECT host, clock_offset, clock_observed FROM hosts WHERE clock_offset IS NOT NULL")
        var clocks: [String: ClockRecord] = [:]
        while try statement.step() {
            clocks[statement.text(at: 0)] = ClockRecord(
                offset: statement.double(at: 1),
                observed: statement.double(at: 2)
            )
        }
        return clocks
    }

    /// Time up to which `host`'s `tier` is complete. Raw points are always complete. A host with no row has nothing
    /// rolled up.
    private static func horizon(_ host: String, _ tier: HistoryTier, in database: SQLiteDatabase) throws -> TimeInterval {
        guard tier != .raw else { return .infinity }
        let statement = try database.prepare("SELECT horizon_five, horizon_hour FROM hosts WHERE host = ?1")
        try statement.bind(host, at: 1)
        guard try statement.step() else { return 0 }
        return tier == .fiveMinute ? statement.double(at: 0) : statement.double(at: 1)
    }

    private static func setHorizons(
        _ host: String,
        fiveMinute: TimeInterval,
        hourly: TimeInterval,
        in database: SQLiteDatabase
    ) throws {
        let statement = try database.prepare("UPDATE hosts SET horizon_five = ?2, horizon_hour = ?3 WHERE host = ?1")
        try statement.bind(host, at: 1)
        try statement.bind(fiveMinute, at: 2)
        try statement.bind(hourly, at: 3)
        _ = try statement.step()
    }

    /// Aggregates the source tier's buckets in [start, end) into the target tier, for one host. Each bucket is keyed by
    /// the target's width, so repeated runs over the same span produce the same rows.
    private static func rollUp(
        _ host: String,
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
                (host, tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max)
            SELECT host, \(target.rawValue), \(bucket), SUM(samples),
                SUM(cpu_sum), SUM(cpu_n), MAX(cpu_max),
                SUM(mem_sum), SUM(mem_n), MAX(mem_max),
                SUM(rx_sum), SUM(rx_n), MAX(rx_max),
                SUM(tx_sum), SUM(tx_n), MAX(tx_max)
            FROM points WHERE host = ?1 AND tier = \(source.rawValue) AND start >= ?2 AND start < ?3
            GROUP BY \(bucket)
            """)
        try points.bind(host, at: 1)
        try points.bind(start, at: 2)
        try points.bind(end, at: 3)
        _ = try points.step()

        let volumes = try database.prepare("""
            INSERT OR REPLACE INTO volume_points (host, tier, start, mount, value_sum, value_n, value_max)
            SELECT host, \(target.rawValue), \(bucket), mount, SUM(value_sum), SUM(value_n), MAX(value_max)
            FROM volume_points WHERE host = ?1 AND tier = \(source.rawValue) AND start >= ?2 AND start < ?3
            GROUP BY \(bucket), mount
            """)
        try volumes.bind(host, at: 1)
        try volumes.bind(start, at: 2)
        try volumes.bind(end, at: 3)
        _ = try volumes.step()
    }

    private static func prune(_ host: String, _ tier: HistoryTier, before cutoff: TimeInterval, in database: SQLiteDatabase) throws -> Int {
        let points = try database.prepare("DELETE FROM points WHERE host = ?1 AND tier = ?2 AND start < ?3")
        try points.bind(host, at: 1)
        try points.bind(tier.rawValue, at: 2)
        try points.bind(cutoff, at: 3)
        _ = try points.step()
        let removed = database.changes

        let volumes = try database.prepare("DELETE FROM volume_points WHERE host = ?1 AND tier = ?2 AND start < ?3")
        try volumes.bind(host, at: 1)
        try volumes.bind(tier.rawValue, at: 2)
        try volumes.bind(cutoff, at: 3)
        _ = try volumes.step()
        return removed + database.changes
    }

    // MARK: Inspection and test seams

    /// Rows stored for `tier` of `host`: points and volume rows.
    func rowCount(_ tier: HistoryTier, host: HistoryHostID = .local) throws -> (points: Int, volumes: Int) {
        let points = try database.prepare("SELECT COUNT(*) FROM points WHERE host = ?1 AND tier = ?2")
        try points.bind(host.rawValue, at: 1)
        try points.bind(tier.rawValue, at: 2)
        _ = try points.step()
        let volumes = try database.prepare("SELECT COUNT(*) FROM volume_points WHERE host = ?1 AND tier = ?2")
        try volumes.bind(host.rawValue, at: 1)
        try volumes.bind(tier.rawValue, at: 2)
        _ = try volumes.step()
        return (points.int(at: 0), volumes.int(at: 0))
    }

    /// The query plan for reading `tier` of a host, one line per step.
    func queryPlan(for tier: HistoryTier, host: HistoryHostID = .local) throws -> [String] {
        let statement = try database.prepare("EXPLAIN QUERY PLAN " + Self.selectPointsSQL)
        try Self.bindRange(statement, host: host.rawValue, tier: tier, from: 0, to: 1)
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
