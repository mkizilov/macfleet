import Foundation
import Testing
@testable import MacFleetKit

private let hostOrigin: TimeInterval = 1_700_000_000
private let alpha = HistoryHostID(rawValue: "host-alpha")
private let beta = HistoryHostID(rawValue: "host-beta")

/// Quiet by default: no timed maintenance runs, so each test decides when rollup and pruning happen.
private func hostConfiguration(batchSize: Int = 1_000) -> MetricHistoryStore.Configuration {
    var configuration = MetricHistoryStore.Configuration()
    configuration.batchSize = batchSize
    configuration.batchAge = 1_000_000
    configuration.maintenanceInterval = 1_000_000_000
    return configuration
}

private func openHostStore(
    _ directory: URL,
    retention: HistoryRetention = .default,
    configuration: MetricHistoryStore.Configuration = hostConfiguration()
) throws -> MetricHistoryStore {
    try MetricHistoryStore.open(
        at: directory.appendingPathComponent("history.sqlite"),
        retention: retention,
        configuration: configuration,
        now: Date(timeIntervalSince1970: hostOrigin)
    )
}

/// A remote snapshot with exact readings. `capturedAt` is the host's own clock, which the store must not trust for placement.
private func hostSample(
    hostTime: TimeInterval,
    cpu: Double? = 0.2,
    memory: Double = 0.5,
    download: Double = 1_000,
    upload: Double = 100,
    disk: Double = 0.6
) -> RemoteSnapshot {
    let total: UInt64 = 10_000
    let capacity: UInt64 = 1_000_000
    return RemoteSnapshot(
        capturedAt: Date(timeIntervalSince1970: hostTime),
        cpuTotal: cpu.map { .available($0) } ?? .unavailable(.notSampled),
        memory: .available(MemoryUsage(
            totalBytes: total,
            usedBytes: UInt64((memory * Double(total)).rounded()),
            availableBytes: total - UInt64((memory * Double(total)).rounded())
        )),
        memoryPressure: .available(.normal),
        storage: .available([VolumeMetrics(
            name: "Macintosh HD",
            mountPoint: "/",
            isRemovable: false,
            isBrowsable: true,
            capacity: .available(DiskCapacity(
                totalBytes: capacity,
                availableBytes: UInt64(((1 - disk) * Double(capacity)).rounded())
            ))
        )]),
        network: .available([NetworkInterfaceMetrics(
            name: "en0",
            isUp: true,
            isLoopback: false,
            ipv4Addresses: [],
            totals: .unavailable(.notSampled),
            rates: .available(NetworkRate(receivedPerSecond: download, sentPerSecond: upload))
        )]),
        thermal: .available(.nominal),
        loadAverage: .available(LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0))
    )
}

/// Feeds a host's snapshots at the given arrival times, each reporting `cpu`, and returns the outcomes.
private func ingest(
    _ store: MetricHistoryStore,
    host: HistoryHostID,
    arrivals: [TimeInterval],
    hostClockOffset: TimeInterval = 0,
    cpu: (Int) -> Double = { _ in 0.2 }
) async -> [HistoryIngestOutcome] {
    var outcomes: [HistoryIngestOutcome] = []
    for (index, arrival) in arrivals.enumerated() {
        outcomes.append(await store.ingest(
            hostSample(hostTime: arrival + hostClockOffset, cpu: cpu(index)),
            from: host,
            receivedAt: Date(timeIntervalSince1970: arrival)
        ))
    }
    return outcomes
}

private func spaced(_ count: Int, from start: TimeInterval = hostOrigin, by spacing: TimeInterval = 10) -> [TimeInterval] {
    (0..<count).map { start + Double($0) * spacing }
}

@Suite("History: host isolation")
struct HistoryHostIsolationTests {
    @Test func hostsKeepSeparateHistoriesWithTheirOwnValues() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let times = spaced(20)
            _ = await ingest(store, host: alpha, arrivals: times) { _ in 0.10 }
            _ = await ingest(store, host: beta, arrivals: times) { _ in 0.90 }
            await store.flush()

            // A chart slot holds the mean of its readings, so each host's slots show only that host's value.
            let alphaSeries = try await store.series(host: alpha, range: .hour, now: Date(timeIntervalSince1970: hostOrigin + 200))
            let betaSeries = try await store.series(host: beta, range: .hour, now: Date(timeIntervalSince1970: hostOrigin + 200))
            let observedAlpha = alphaSeries.cpu.compactMap { $0 }
            let observedBeta = betaSeries.cpu.compactMap { $0 }
            #expect(alphaSeries.samples == 20 && betaSeries.samples == 20)
            #expect(!observedAlpha.isEmpty && observedAlpha.allSatisfy { closeEnough($0, 0.10) })
            #expect(!observedBeta.isEmpty && observedBeta.allSatisfy { closeEnough($0, 0.90) })
            #expect(try await store.rowCount(.raw, host: alpha).points == 20)
            #expect(try await store.rowCount(.raw, host: beta).points == 20)
        }
    }

    @Test func theLocalMacAndARemoteMacDoNotShareRows() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            for index in 0..<5 {
                await store.save(makeSnapshot(at: hostOrigin + Double(index) * 10, cpu: 0.3))
            }
            _ = await ingest(store, host: alpha, arrivals: spaced(5)) { _ in 0.7 }
            await store.flush()

            #expect(try await store.rowCount(.raw).points == 5)
            #expect(try await store.rowCount(.raw, host: alpha).points == 5)
            let local = try await store.series(range: .hour, now: Date(timeIntervalSince1970: hostOrigin + 60))
            #expect(local.cpu.compactMap { $0 }.allSatisfy { closeEnough($0, 0.3) })
        }
    }

    @Test func aPlanForARemoteHostUsesTheKeyNotAScan() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            for tier in HistoryTier.allCases {
                let plan = try await store.queryPlan(for: tier, host: alpha)
                #expect(plan.contains { $0.contains("SEARCH points USING PRIMARY KEY") })
                #expect(!plan.contains { $0.hasPrefix("SCAN") })
            }
        }
    }
}

@Suite("History: timestamps and clock differences")
struct HistoryClockTests {
    @Test func aFastHostClockIsPlacedByArrivalAndFlaggedAsDiffering() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let times = spaced(12)
            _ = await ingest(store, host: alpha, arrivals: times, hostClockOffset: 3_600)
            await store.flush()

            let stored = try await store.points(host: alpha, in: .raw, from: .distantPast, to: .distantFuture).map(\.start)
            #expect(stored == times, "points keep the arrival times, not the host's clock")
            #expect(await store.clockStatus(host: alpha) == .differs(seconds: 3_600))
        }
    }

    @Test func aHostWithAnAccurateClockIsAligned() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            _ = await ingest(store, host: alpha, arrivals: spaced(4), hostClockOffset: 1.5)
            await store.flush()
            #expect(await store.clockStatus(host: alpha) == .aligned)
            #expect(HostClockStatus.classify(offset: -59) == .aligned)
            #expect(HostClockStatus.classify(offset: -61) == .differs(seconds: -61))
        }
    }

    @Test func hostsWithOppositeClockErrorsShareOneTimeline() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let times = spaced(30, by: 10)
            _ = await ingest(store, host: alpha, arrivals: times, hostClockOffset: 7_200)
            _ = await ingest(store, host: beta, arrivals: times, hostClockOffset: -7_200)
            await store.flush()

            let window = Date(timeIntervalSince1970: hostOrigin + 400)
            let first = try await store.series(host: alpha, range: .hour, now: window)
            let second = try await store.series(host: beta, range: .hour, now: window)
            #expect(first.start == second.start && first.end == second.end)
            #expect(first.cpu.map { $0 != nil } == second.cpu.map { $0 != nil }, "the same slots hold data for both hosts")
            #expect(await store.clockStatus(host: alpha) == .differs(seconds: 7_200))
            #expect(await store.clockStatus(host: beta) == .differs(seconds: -7_200))
        }
    }

    @Test func aHostClockThatStepsBackwardDoesNotMoveItsSamples() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let times = spaced(10)
            _ = await ingest(store, host: alpha, arrivals: times) { _ in 0.2 }
            // The host's clock is corrected back by two hours. Its next samples report earlier times.
            for (index, arrival) in spaced(5, from: hostOrigin + 100).enumerated() {
                let outcome = await store.ingest(
                    hostSample(hostTime: arrival - 7_200 + Double(index)),
                    from: alpha,
                    receivedAt: Date(timeIntervalSince1970: arrival)
                )
                #expect(outcome == .accepted)
            }
            await store.flush()

            #expect(try await store.points(host: alpha, in: .raw, from: .distantPast, to: .distantFuture).map(\.start) == times + spaced(5, from: hostOrigin + 100))
            #expect(await store.statistics.clockSteps >= 1)
        }
    }

    @Test func aHostSendingTheSameSampleTwiceStoresItOnce() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let snapshot = hostSample(hostTime: hostOrigin)
            #expect(await store.ingest(snapshot, from: alpha, receivedAt: Date(timeIntervalSince1970: hostOrigin)) == .accepted)
            #expect(await store.ingest(snapshot, from: alpha, receivedAt: Date(timeIntervalSince1970: hostOrigin + 10)) == .duplicate)
            await store.flush()
            #expect(try await store.rowCount(.raw, host: alpha).points == 1)
            #expect(await store.statistics.duplicateSnapshots == 1)
        }
    }

    @Test func thisMacsClockStepBackIsRefusedNotStoredOutOfOrder() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            _ = await ingest(store, host: alpha, arrivals: [hostOrigin, hostOrigin + 20])
            let back = await store.ingest(
                hostSample(hostTime: hostOrigin - 600),
                from: alpha,
                receivedAt: Date(timeIntervalSince1970: hostOrigin - 600)
            )
            #expect(back == .clockRegressed)
            await store.flush()
            let stored = try await store.points(host: alpha, in: .raw, from: .distantPast, to: .distantFuture).map(\.start)
            #expect(stored == [hostOrigin, hostOrigin + 20])
            #expect(await store.statistics.clockRegressions == 1)
        }
    }

    @Test func aSmallBackwardJitterIsThrottledNotCountedAsARegression() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            _ = await ingest(store, host: alpha, arrivals: [hostOrigin, hostOrigin + 10])
            let jitter = await store.ingest(
                hostSample(hostTime: hostOrigin + 8),
                from: alpha,
                receivedAt: Date(timeIntervalSince1970: hostOrigin + 8)
            )
            #expect(jitter == .throttled)
            #expect(await store.statistics.clockRegressions == 0)
        }
    }

    @Test func aClockIsUnknownUntilTheHostReportsAndThisMacIsAlwaysAligned() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            #expect(await store.clockStatus(host: alpha) == .unknown)
            #expect(await store.clockStatus(host: .local) == .aligned)
        }
    }

    @Test func aClockRecordSurvivesARestart() async throws {
        try await withScratchDirectory { directory in
            var store: MetricHistoryStore? = try openHostStore(directory)
            _ = await ingest(store!, host: alpha, arrivals: spaced(3), hostClockOffset: 3_600)
            await store?.flush()
            store = nil

            let reopened = try openHostStore(directory)
            #expect(await reopened.clockStatus(host: alpha) == .differs(seconds: 3_600))
            #expect(try await reopened.rowCount(.raw, host: alpha).points == 3)
        }
    }
}

@Suite("History: schema migration")
struct HistoryMigrationTests {
    /// The version 1 layout, written exactly as the previous build wrote it.
    private static let versionOneSchema = """
        CREATE TABLE points (
            tier INTEGER NOT NULL, start REAL NOT NULL, samples INTEGER NOT NULL,
            cpu_sum REAL NOT NULL, cpu_n INTEGER NOT NULL, cpu_max REAL,
            mem_sum REAL NOT NULL, mem_n INTEGER NOT NULL, mem_max REAL,
            rx_sum REAL NOT NULL, rx_n INTEGER NOT NULL, rx_max REAL,
            tx_sum REAL NOT NULL, tx_n INTEGER NOT NULL, tx_max REAL,
            PRIMARY KEY (tier, start)
        ) WITHOUT ROWID;
        CREATE TABLE volume_points (
            tier INTEGER NOT NULL, start REAL NOT NULL, mount TEXT NOT NULL,
            value_sum REAL NOT NULL, value_n INTEGER NOT NULL, value_max REAL NOT NULL,
            PRIMARY KEY (tier, start, mount)
        ) WITHOUT ROWID;
        CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value REAL NOT NULL) WITHOUT ROWID;
        """

    @Test func aVersionOneFileKeepsEveryRowUnderTheLocalMac() async throws {
        try await withScratchDirectory { directory in
            let file = directory.appendingPathComponent("history.sqlite")
            let legacy = try SQLiteDatabase(path: file.path)
            try legacy.execute(Self.versionOneSchema)
            for index in 0..<6 {
                try legacy.execute("""
                    INSERT INTO points (tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max)
                    VALUES (0, \(hostOrigin + Double(index) * 10), 1, 0.5, 1, 0.5, 0.5, 1, 0.5, 100, 1, 100, 10, 1, 10)
                    """)
            }
            try legacy.execute("INSERT INTO volume_points (tier, start, mount, value_sum, value_n, value_max) VALUES (0, \(hostOrigin), '/', 0.6, 1, 0.6)")
            try legacy.execute("INSERT INTO meta (key, value) VALUES ('horizon.1', 0), ('horizon.2', 0)")
            try legacy.execute("PRAGMA user_version = 1")
            legacy.close()

            let store = try openHostStore(directory)
            #expect(store.recoveryNote == nil)
            #expect(try await store.rowCount(.raw).points == 6)
            #expect(try await store.rowCount(.raw).volumes == 1)
            #expect(try await store.storedHosts().contains(.local))
            let series = try await store.series(range: .hour, now: Date(timeIntervalSince1970: hostOrigin + 60))
            #expect(series.samples == 6)

            await store.save(makeSnapshot(at: hostOrigin + 100))
            await store.flush()
            #expect(try await store.rowCount(.raw).points == 7)
        }
    }

    @Test func aVersionTwoFileOpensWithoutChange() async throws {
        try await withScratchDirectory { directory in
            var store: MetricHistoryStore? = try openHostStore(directory)
            _ = await ingest(store!, host: alpha, arrivals: spaced(4))
            await store?.flush()
            store = nil
            let reopened = try openHostStore(directory)
            #expect(try await reopened.rowCount(.raw, host: alpha).points == 4)
            #expect(reopened.recoveryNote == nil)
        }
    }
}

@Suite("History: retention and removal per host")
struct HistoryRetentionPerHostTests {
    @Test func eachHostIsPrunedToItsOwnRetention() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            // Samples end now, because a retention change prunes against this Mac's real clock.
            let now = Date().timeIntervalSince1970
            let times = (0..<36).map { now - 6 * 3_600 + Double($0) * 600 }
            _ = await ingest(store, host: alpha, arrivals: times)
            _ = await ingest(store, host: beta, arrivals: times)
            await store.flush()

            let shortRaw = try HistoryRetention(raw: 2 * 3_600, fiveMinute: 2 * 86_400, hourly: 8 * 86_400)
            try await store.setRetention(shortRaw, for: beta)
            #expect(try await store.rowCount(.raw, host: alpha).points == 36)
            let betaRaw = try await store.points(host: beta, in: .raw, from: .distantPast, to: .distantFuture)
            #expect(betaRaw.allSatisfy { $0.start >= now - 2 * 3_600 - 1 })
            #expect(betaRaw.count >= 11 && betaRaw.count <= 13)
            #expect(try await store.retention(for: beta) == shortRaw)
            #expect(try await store.retention(for: alpha) == nil)
        }
    }

    @Test func aRetentionChangeTakesEffectWhenItIsSet() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            // Six hours of samples that end now, so a two-hour raw retention keeps the last two hours only.
            let now = Date().timeIntervalSince1970
            let times = (0..<36).map { now - 6 * 3_600 + Double($0) * 600 }
            _ = await ingest(store, host: alpha, arrivals: times)
            await store.flush()
            let before = try await store.rowCount(.raw, host: alpha).points
            #expect(before == 36)

            try await store.setRetention(try HistoryRetention(raw: 2 * 3_600, fiveMinute: 2 * 86_400, hourly: 8 * 86_400), for: alpha)
            let after = try await store.rowCount(.raw, host: alpha).points
            #expect(after < before)
            #expect(after >= 11 && after <= 13)
        }
    }

    @Test func aRetentionBelowTheMinimumIsRefusedAndDefaultsCanBeRestored() async throws {
        #expect(throws: HistoryError.self) {
            try HistoryRetention(raw: 60, fiveMinute: 2 * 86_400, hourly: 8 * 86_400)
        }
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            try await store.setRetention(try HistoryRetention(raw: 3 * 3_600, fiveMinute: 3 * 86_400, hourly: 9 * 86_400), for: alpha)
            try await store.setRetention(nil, for: alpha)
            #expect(try await store.retention(for: alpha) == nil)
        }
    }

    @Test func removingAHostDeletesOnlyItsHistory() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let times = spaced(20)
            _ = await ingest(store, host: alpha, arrivals: times) { _ in 0.1 }
            _ = await ingest(store, host: beta, arrivals: times) { _ in 0.9 }
            await store.flush()

            // 20 points, 20 volume rows, and the host's own row.
            let removed = try await store.removeHistory(for: alpha)
            #expect(removed == 41)
            #expect(try await store.rowCount(.raw, host: alpha).points == 0)
            #expect(try await store.storedHosts().contains(alpha) == false)
            let alphaAfter = try await store.series(host: alpha, range: .hour, now: Date(timeIntervalSince1970: hostOrigin + 200))
            #expect(alphaAfter.samples == 0)
            let betaAfter = try await store.series(host: beta, range: .hour, now: Date(timeIntervalSince1970: hostOrigin + 200))
            #expect(betaAfter.cpu.compactMap { $0 }.allSatisfy { closeEnough($0, 0.9) })
            #expect(betaAfter.samples == 20)
        }
    }

    @Test func aRemovedHostCanBeRecordedAgainFromScratch() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            _ = await ingest(store, host: alpha, arrivals: spaced(5))
            await store.flush()
            _ = try await store.removeHistory(for: alpha)
            let outcomes = await ingest(store, host: alpha, arrivals: spaced(5))
            #expect(outcomes.allSatisfy { $0 == .accepted })
            await store.flush()
            #expect(try await store.rowCount(.raw, host: alpha).points == 5)
        }
    }

    @Test func removingTheLocalHistoryLeavesRemoteHistoriesAlone() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            await store.save(makeSnapshot(at: hostOrigin))
            _ = await ingest(store, host: alpha, arrivals: spaced(3))
            await store.flush()
            _ = try await store.removeHistory(for: .local)
            #expect(try await store.rowCount(.raw).points == 0)
            #expect(try await store.rowCount(.raw, host: alpha).points == 3)
        }
    }
}

@Suite("History: concurrent ingestion")
struct HistoryConcurrencyTests {
    @Test func manyHostsWritingAtOnceLoseNothingAndMixNothing() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory, configuration: hostConfiguration(batchSize: 32))
            let hosts = (0..<6).map { HistoryHostID(rawValue: "concurrent-\($0)") }
            let perHost = 150

            await withTaskGroup(of: Void.self) { group in
                for (index, host) in hosts.enumerated() {
                    group.addTask {
                        // Each host's value is its index, so any row that landed under the wrong host shows up.
                        _ = await ingest(store, host: host, arrivals: spaced(perHost)) { _ in Double(index) / 10 + 0.01 }
                    }
                }
            }
            await store.flush()

            #expect(await store.statistics.acceptedSnapshots == hosts.count * perHost)
            #expect(await store.statistics.transactions > 1)
            for (index, host) in hosts.enumerated() {
                #expect(try await store.rowCount(.raw, host: host).points == perHost)
                let summary = try await store.summary(host: host, from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 10_000))
                #expect(summary.samples == perHost)
                #expect(closeEnough(summary.cpu.mean ?? -1, Double(index) / 10 + 0.01))
                #expect(summary.cpu.count == perHost)
            }
        }
    }

    @Test func readersSeeOnlyWhatIsCommittedWhileWritersRun() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory, configuration: hostConfiguration(batchSize: 8))
            let host = HistoryHostID(rawValue: "live")
            let window = (from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 100_000))

            let writer = Task {
                _ = await ingest(store, host: host, arrivals: spaced(200))
                await store.flush()
            }
            var previous = 0
            var reads = 0
            while !writer.isCancelled {
                let count = try await store.summary(host: host, from: window.from, to: window.to).samples
                #expect(count >= previous, "a committed count never goes back")
                previous = count
                reads += 1
                if reads > 500 { break }
                if count == 200 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            await writer.value
            #expect(try await store.summary(host: host, from: window.from, to: window.to).samples == 200)
        }
    }
}

@Suite("History: aggregation, downsampling, and export")
struct HistoryAggregationTests {
    @Test func aSummaryMatchesTheReadingsItWasBuiltFrom() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let values = (0..<100).map { fraction($0, salt: 13) }
            _ = await ingest(store, host: alpha, arrivals: spaced(100)) { values[$0] }
            await store.flush()

            let summary = try await store.summary(host: alpha, from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 2_000))
            #expect(summary.samples == 100)
            #expect(summary.cpu.count == 100)
            #expect(closeEnough(summary.cpu.sum, values.reduce(0, +)))
            #expect(closeEnough(summary.cpu.maximum ?? -1, values.max() ?? -2))
            #expect(summary.disk.count == 100, "one monitored volume per sample")
            #expect(summary.lastSample == Date(timeIntervalSince1970: hostOrigin + 990))
        }
    }

    @Test func aSummaryIsExactAfterRollupMovesItToCoarserTiers() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let values = (0..<720).map { fraction($0, salt: 17) }
            _ = await ingest(store, host: alpha, arrivals: spaced(720, by: 10)) { values[$0] }
            await store.flush()

            let window = (from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 7_200))
            let beforeRollup = try await store.summary(host: alpha, from: window.from, to: window.to)
            await store.maintain(now: hostOrigin + 7_500)
            #expect(try await store.rowCount(.fiveMinute, host: alpha).points > 0)
            #expect(try await store.rowCount(.hourly, host: alpha).points > 0)
            let afterRollup = try await store.summary(host: alpha, from: window.from, to: window.to)

            #expect(afterRollup.samples == beforeRollup.samples)
            #expect(closeEnough(afterRollup.cpu.sum, beforeRollup.cpu.sum))
            #expect(afterRollup.cpu.count == beforeRollup.cpu.count)
            #expect(closeEnough(afterRollup.cpu.maximum ?? -1, beforeRollup.cpu.maximum ?? -2))
            #expect(afterRollup.lastSample == beforeRollup.lastSample)
        }
    }

    @Test func rollupOfOneHostNeverTouchesAnother() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            _ = await ingest(store, host: alpha, arrivals: spaced(720)) { _ in 0.25 }
            _ = await ingest(store, host: beta, arrivals: spaced(30, by: 10)) { _ in 0.75 }
            await store.flush()
            await store.maintain(now: hostOrigin + 7_500)

            let betaSummary = try await store.summary(host: beta, from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 7_200))
            #expect(betaSummary.samples == 30)
            #expect(closeEnough(betaSummary.cpu.mean ?? -1, 0.75))
            let alphaSummary = try await store.summary(host: alpha, from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 7_200))
            #expect(alphaSummary.samples == 720)
            #expect(closeEnough(alphaSummary.cpu.mean ?? -1, 0.25))
        }
    }

    @Test func aGapIsNotCountedAsAReadingInTheSummary() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            // Even snapshots have a CPU reading; odd ones report it unavailable, and so does the last one.
            for index in 0..<10 {
                let cpu: Double? = index % 2 == 0 ? 0.4 : nil
                _ = await store.ingest(
                    hostSample(hostTime: hostOrigin + Double(index) * 10, cpu: cpu),
                    from: alpha,
                    receivedAt: Date(timeIntervalSince1970: hostOrigin + Double(index) * 10)
                )
            }
            _ = await store.ingest(hostSample(hostTime: hostOrigin + 500, cpu: nil), from: alpha, receivedAt: Date(timeIntervalSince1970: hostOrigin + 500))
            await store.flush()
            let summary = try await store.summary(host: alpha, from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 1_000))
            #expect(summary.samples == 11)
            #expect(summary.cpu.count == 5)
            #expect(closeEnough(summary.cpu.mean ?? -1, 0.4))
        }
    }

    @Test func aTierIsChosenByTheSpanAndTheBudget() {
        #expect(HistoryResolution.tier(span: 3_600, maximumPoints: 500) == .raw)
        #expect(HistoryResolution.tier(span: 86_400, maximumPoints: 500) == .fiveMinute)
        #expect(HistoryResolution.tier(span: 86_400, maximumPoints: 100) == .hourly)
        #expect(HistoryResolution.tier(span: 30 * 86_400, maximumPoints: 500) == .hourly)
    }

    @Test func aLongExportUsesACoarserTierAndStaysWithinTheBudget() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            let count = 2 * 86_400 / 600
            _ = await ingest(store, host: alpha, arrivals: spaced(count, by: 600)) { fraction($0, salt: 3) }
            await store.flush()
            await store.maintain(now: hostOrigin + 2 * 86_400 + 60)

            let rows = try await store.exportRows(
                hosts: [alpha],
                from: Date(timeIntervalSince1970: hostOrigin),
                to: Date(timeIntervalSince1970: hostOrigin + 2 * 86_400),
                maximumPoints: 60
            )
            // Hourly buckets carry the span and stay within the budget. Finer rows can appear only at the two ends: the
            // partial hour the span starts in, and the last hour, which is not rolled up until its grace period passes.
            let hourlyCPU = rows.filter { $0.metric == "cpu" && $0.resolution == .hourly }
            #expect(hourlyCPU.count <= 60)
            #expect(hourlyCPU.count >= 40)
            let end = hostOrigin + 2 * 86_400
            #expect(rows.filter { $0.resolution != .hourly }.allSatisfy { row in
                row.time < Date(timeIntervalSince1970: hostOrigin + 3_600) || row.time >= Date(timeIntervalSince1970: end - 7_200)
            })
        }
    }

    @Test func exportRowsSeparateHostsAndMetricsAndCarryTheVolumeMetric() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            _ = await ingest(store, host: alpha, arrivals: spaced(6)) { _ in 0.1 }
            _ = await ingest(store, host: beta, arrivals: spaced(6)) { _ in 0.8 }
            await store.flush()

            let rows = try await store.exportRows(
                hosts: [alpha, beta],
                from: Date(timeIntervalSince1970: hostOrigin),
                to: Date(timeIntervalSince1970: hostOrigin + 60),
                maximumPoints: 1_000
            )
            #expect(Set(rows.map(\.metric)) == ["cpu", "memory", "download_bytes_per_second", "upload_bytes_per_second", "disk:/"])
            let alphaCPU = rows.filter { $0.host == alpha && $0.metric == "cpu" }
            let betaCPU = rows.filter { $0.host == beta && $0.metric == "cpu" }
            #expect(alphaCPU.count == 6 && alphaCPU.allSatisfy { closeEnough($0.mean ?? -1, 0.1) })
            #expect(betaCPU.count == 6 && betaCPU.allSatisfy { closeEnough($0.mean ?? -1, 0.8) })
        }
    }
}

@Suite("History: CSV export")
struct HistoryCSVTests {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func rowsRenderWithUTCTimesAndALabelledHost() {
        let rows = [HistoryExportRow(
            time: time,
            resolution: .raw,
            host: alpha,
            metric: "cpu",
            mean: 0.25,
            maximum: 0.5,
            observations: 2,
            snapshots: 2
        )]
        let csv = HistoryCSV.render(rows, labels: [alpha: "Studio"])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == Substring(HistoryCSV.header))
        #expect(lines[1] == "2023-11-14T22:13:20Z,raw,host-alpha,Studio,cpu,0.25,0.5,2,2")
        #expect(csv.hasSuffix("\n"))
    }

    @Test func aGapIsAnEmptyValueNotZero() {
        let rows = [HistoryExportRow(
            time: time,
            resolution: .fiveMinute,
            host: alpha,
            metric: "cpu",
            mean: nil,
            maximum: nil,
            observations: 0,
            snapshots: 30
        )]
        let line = HistoryCSV.render(rows, labels: [:]).split(separator: "\n")[1]
        #expect(line == "2023-11-14T22:13:20Z,five-minute,host-alpha,host-alpha,cpu,,,0,30")
    }

    @Test func fieldsWithCommasQuotesOrLineBreaksAreQuoted() {
        #expect(HistoryCSV.field("Studio, the second") == "\"Studio, the second\"")
        #expect(HistoryCSV.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(HistoryCSV.field("two\nlines") == "\"two\nlines\"")
        #expect(HistoryCSV.field("plain") == "plain")
    }

    @Test func aLabelWithACommaCannotShiftTheColumns() {
        let rows = [HistoryExportRow(time: time, resolution: .hourly, host: alpha, metric: "disk:/", mean: 0.5, maximum: 0.6, observations: 1, snapshots: 1)]
        let line = HistoryCSV.render(rows, labels: [alpha: "Mac, office"]).split(separator: "\n")[1]
        #expect(line.split(separator: ",", omittingEmptySubsequences: false).count == 9 + 1, "one quoted comma adds one field separator inside quotes")
        #expect(line.contains("\"Mac, office\""))
    }
}

@Suite("History: closed buckets, late samples, and exported resolution")
struct HistoryClosedBucketTests {
    @Test func aSampleTimedBeforeAnotherRollupStillCountsInItsBucket() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            _ = await ingest(store, host: beta, arrivals: spaced(41))
            await store.flush()
            // This Mac rolls up at origin+1000 while beta's sample timed at origin+950 has not been stored yet.
            await store.maintain(now: hostOrigin + 1_000)
            let late = await store.ingest(
                hostSample(hostTime: hostOrigin + 950),
                from: beta,
                receivedAt: Date(timeIntervalSince1970: hostOrigin + 950)
            )
            #expect(late == .accepted)
            await store.flush()

            // 10 points from 0 to 90, 31 from the five-minute buckets covering 100 to 400, and the late one.
            let summary = try await store.summary(host: beta, from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 2_000))
            #expect(summary.samples == 42)
        }
    }

    @Test func aHostRunningAheadDoesNotCloseAnotherHostsOpenBuckets() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            // Beta is stored up to origin+400. Alpha runs to origin+5000, and this Mac rolls up at that point.
            _ = await ingest(store, host: beta, arrivals: spaced(41))
            _ = await ingest(store, host: alpha, arrivals: spaced(501))
            await store.flush()
            await store.maintain(now: hostOrigin + 5_000)
            // Beta's next samples are earlier than alpha's newest, and they must still be stored in their buckets.
            _ = await ingest(store, host: beta, arrivals: spaced(60, from: hostOrigin + 410))
            await store.flush()
            await store.maintain(now: hostOrigin + 5_000)

            let summary = try await store.summary(host: beta, from: Date(timeIntervalSince1970: hostOrigin), to: Date(timeIntervalSince1970: hostOrigin + 6_000))
            #expect(summary.samples == 101)
            #expect(closeEnough(summary.cpu.mean ?? -1, 0.2))
        }
    }

    @Test func exportRowsCarryTheResolutionTheirTimeComesFrom() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            _ = await ingest(store, host: alpha, arrivals: spaced(101))
            await store.flush()
            await store.maintain(now: hostOrigin + 1_000)
            // A one-point budget asks for hourly rows, but only five-minute and raw data cover this span.
            let rows = try await store.exportRows(
                hosts: [alpha],
                from: Date(timeIntervalSince1970: hostOrigin),
                to: Date(timeIntervalSince1970: hostOrigin + 1_000),
                maximumPoints: 1
            )
            #expect(rows.contains { $0.resolution == .fiveMinute })
            #expect(rows.contains { $0.resolution == .raw })
            #expect(!rows.contains { $0.resolution == .hourly })
            for row in rows {
                let width = row.resolution == .raw ? 10 : Double(row.resolution.width)
                #expect(row.time.timeIntervalSince1970.truncatingRemainder(dividingBy: width) == 0, "\(row.resolution) row at \(row.time) is off its grid")
            }
        }
    }

    @Test func aClockThatMovedBackIsReportedUntilItCatchesUp() async throws {
        try await withScratchDirectory { directory in
            let store = try openHostStore(directory)
            await store.save(makeSnapshot(at: hostOrigin + 100))
            await store.save(makeSnapshot(at: hostOrigin + 50))
            #expect(await store.notice()?.contains("clock moved back") == true)
            await store.save(makeSnapshot(at: hostOrigin + 200))
            #expect(await store.notice() == nil)
        }
    }
}
