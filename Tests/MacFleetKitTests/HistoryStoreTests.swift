import Foundation
import Testing
@testable import MacFleetKit

private let origin: TimeInterval = 1_700_000_100

private func openStore(
    _ directory: URL,
    name: String = "history.sqlite",
    retention: HistoryRetention = .default,
    configuration: MetricHistoryStore.Configuration = MetricHistoryStore.Configuration(),
    now: TimeInterval = origin
) throws -> MetricHistoryStore {
    try MetricHistoryStore.open(
        at: directory.appendingPathComponent(name),
        retention: retention,
        configuration: configuration,
        now: Date(timeIntervalSince1970: now)
    )
}

/// Batching, upkeep, and the clock are all driven by the test, so nothing happens unless the test asks for it.
private func quietConfiguration(batchSize: Int = 1_000) -> MetricHistoryStore.Configuration {
    var configuration = MetricHistoryStore.Configuration()
    configuration.batchSize = batchSize
    configuration.batchAge = 1_000_000
    configuration.maintenanceInterval = 1_000_000_000
    return configuration
}

private func fileNames(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
}

@Suite("History store: writing and batching")
struct HistoryStoreWritingTests {
    @Test func downsamplesToOnePointPerResolutionAndBatchesWrites() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration(batchSize: 4))
            for index in 0..<50 {
                await store.save(makeSnapshot(at: origin + Double(index) * 2))
            }

            let before = await store.statistics
            #expect(before.acceptedSnapshots == 10)
            #expect(before.throttledSnapshots == 40)
            #expect(before.transactions == 2)
            #expect(before.rowsWritten == 16)

            let series = try await store.series(range: .hour, now: Date(timeIntervalSince1970: origin + 100))
            #expect(series.samples == 10)
            let after = await store.statistics
            #expect(after.transactions == 3)
            #expect(after.rowsWritten == 20)
        }
    }

    @Test func aPartialBatchIsWrittenWhenItsOldestPointAges() async throws {
        try await withScratchDirectory { directory in
            var configuration = quietConfiguration()
            configuration.batchAge = 30
            let store = try openStore(directory, configuration: configuration)
            for index in 0..<4 {
                await store.save(makeSnapshot(at: origin + Double(index) * 10))
            }
            let statistics = await store.statistics
            #expect(statistics.transactions == 1)
            #expect(statistics.rowsWritten == 8)
        }
    }

    /// Regression pin. With a 30-second batch age, 10-second points were written four at a time (180 transactions in
    /// two hours). The default must batch by size or by the 300-second age, whichever comes first.
    @Test func defaultBatchingWritesFarLessOftenThanEveryFewPoints() async throws {
        try await withScratchDirectory { directory in
            var configuration = MetricHistoryStore.Configuration()
            configuration.maintenanceInterval = 1_000_000_000
            let store = try openStore(directory, configuration: configuration)
            for index in 0..<720 {
                await store.save(makeSnapshot(at: origin + Double(index) * 10))
            }
            let transactions = await store.statistics.transactions
            #expect((20...26).contains(transactions))
        }
    }

    @Test func rowsCarryTheirVolumesInTheSameTransaction() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration())
            for index in 0..<6 {
                await store.save(makeSnapshot(at: origin + Double(index) * 10))
            }
            await store.flush()
            let counts = try await store.rowCount(.raw)
            #expect(counts.points == 6)
            #expect(counts.volumes == 6)
        }
    }

    @Test func persistedPointsSurviveReopening() async throws {
        try await withScratchDirectory { directory in
            var store: MetricHistoryStore? = try openStore(directory, configuration: quietConfiguration())
            for index in 0..<20 {
                await store?.save(makeSnapshot(at: origin + Double(index) * 10))
            }
            await store?.flush()
            store = nil

            let reopened = try openStore(directory, configuration: quietConfiguration())
            let series = try await reopened.series(range: .hour, now: Date(timeIntervalSince1970: origin + 300))
            #expect(series.samples == 20)
            #expect(reopened.recoveryNote == nil)
        }
    }

    @Test func aFailedWriteIsSurfacedAndPendingPointsStayBounded() async throws {
        try await withScratchDirectory { directory in
            var configuration = quietConfiguration(batchSize: 1)
            configuration.maximumPending = 5
            let store = try openStore(directory, configuration: configuration)

            try await store.setWritesEnabled(false)
            for index in 0..<10 {
                await store.save(makeSnapshot(at: origin + Double(index) * 10))
            }
            let failing = await store.statistics
            #expect(failing.droppedPoints == 5)
            #expect(await store.lastWriteError != nil)
            #expect(await store.notice() != nil)

            try await store.setWritesEnabled(true)
            await store.flush()
            #expect(await store.lastWriteError == nil)
            #expect(try await store.rowCount(.raw).points == 5)
        }
    }

    @Test func concurrentReadersNeverSeeAnErrorOrLoseAWrite() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration(batchSize: 16))
            try await withThrowingTaskGroup(of: Int.self) { group in
                group.addTask {
                    for index in 0..<300 {
                        await store.save(makeSnapshot(at: origin + Double(index) * 10))
                    }
                    return 0
                }
                for _ in 0..<4 {
                    group.addTask {
                        var reads = 0
                        for _ in 0..<50 {
                            _ = try await store.series(range: .hour, now: Date(timeIntervalSince1970: origin + 3_000))
                            reads += 1
                        }
                        return reads
                    }
                }
                for try await _ in group {}
            }
            await store.flush()
            #expect(await store.statistics.acceptedSnapshots == 300)
            #expect(try await store.rowCount(.raw).points == 300)
        }
    }
}

@Suite("History store: rollup and aggregation")
struct HistoryStoreAggregationTests {
    @Test func fiveMinuteRollupMatchesDirectAggregationOfRawPoints() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration())
            var expected: [TimeInterval: HistoryPoint] = [:]
            let count = 1_080
            for index in 0..<count {
                let snapshot = variedSnapshot(index, origin: origin)
                await store.save(snapshot)
                let point = HistoryPoint(snapshot: snapshot)
                let bucket = floor(point.start / 300) * 300
                expected[bucket, default: HistoryPoint(start: bucket)].merge(point)
            }

            let now = origin + Double(count) * 10
            await store.maintain(now: now)
            // A bucket is rolled up once it has been closed for the grace period.
            let horizon = floor((now - MetricHistoryStore.closeGrace) / 300) * 300
            let stored = try await store.points(
                in: .fiveMinute,
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: horizon)
            )
            let wanted = expected.filter { $0.key < horizon }

            #expect(stored.count == wanted.count)
            #expect(stored.count > 30)
            #expect(stored.allSatisfy { point in wanted[point.start].map { sameHistoryPoint(point, $0) } ?? false })
        }
    }

    @Test func hourlyRollupMatchesDirectAggregationOfRawPoints() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration())
            var expected: [TimeInterval: HistoryPoint] = [:]
            let count = 1_080
            for index in 0..<count {
                let snapshot = variedSnapshot(index, origin: origin)
                await store.save(snapshot)
                let point = HistoryPoint(snapshot: snapshot)
                let bucket = floor(point.start / 3_600) * 3_600
                expected[bucket, default: HistoryPoint(start: bucket)].merge(point)
            }

            let now = origin + Double(count) * 10
            await store.maintain(now: now)
            let fiveMinuteHorizon = floor(now / 300) * 300
            let hourlyHorizon = floor(fiveMinuteHorizon / 3_600) * 3_600
            let stored = try await store.points(
                in: .hourly,
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: hourlyHorizon)
            )
            let wanted = expected.filter { $0.key < hourlyHorizon }

            #expect(stored.count == wanted.count)
            #expect(!stored.isEmpty)
            #expect(stored.allSatisfy { point in wanted[point.start].map { sameHistoryPoint(point, $0) } ?? false })
        }
    }

    /// Only part of the history is rolled up. Reads must combine the rolled part with the raw tail, without a gap
    /// and without counting any point twice.
    @Test func partlyRolledHistoryIsCountedOnceAcrossTiers() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration())
            for index in 0..<240 {
                await store.save(makeSnapshot(at: origin + Double(index) * 10))
            }
            await store.maintain(now: origin + 1_200)

            let now = Date(timeIntervalSince1970: origin + 2_400)
            #expect(try await store.series(range: .hour, now: now).samples == 240)
            #expect(try await store.series(range: .day, now: now).samples == 240)
            #expect(try await store.rowCount(.fiveMinute).points > 0)
            #expect(try await store.points(in: .raw, from: .distantPast, to: .distantFuture).count == 240)
        }
    }

    @Test func volumeRollupsCarryTheirMountPoints() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration())
            for index in 0..<60 {
                await store.save(makeSnapshot(at: origin + Double(index) * 10, disk: 0.5 + Double(index) * 0.001))
            }
            await store.maintain(now: origin + 600)
            let rolled = try await store.points(in: .fiveMinute, from: .distantPast, to: Date(timeIntervalSince1970: origin + 300))
            #expect(!rolled.isEmpty)
            #expect(rolled.allSatisfy { Set($0.volumes.keys) == ["/"] })
        }
    }
}

@Suite("History store: retention and cleanup")
struct HistoryStoreRetentionTests {
    /// Nine days of 10-minute points, with the smallest retention each tier allows.
    @Test func eachTierIsPrunedToItsOwnRetentionAfterRollup() async throws {
        try await withScratchDirectory { directory in
            let retention = try HistoryRetention(
                raw: HistoryRetention.minimumRaw,
                fiveMinute: HistoryRetention.minimumFiveMinute,
                hourly: HistoryRetention.minimumHourly
            )
            let store = try openStore(directory, retention: retention, configuration: quietConfiguration(batchSize: 1_000))
            let spacing: TimeInterval = 600
            let count = Int(9 * 86_400 / spacing)
            for index in 0..<count {
                await store.save(makeSnapshot(at: origin + Double(index) * spacing))
            }
            let end = origin + Double(count) * spacing
            await store.maintain(now: end)

            let raw = try await store.points(in: .raw, from: .distantPast, to: .distantFuture)
            #expect(raw.count == 12)
            #expect(raw.allSatisfy { $0.start >= end - HistoryRetention.minimumRaw })

            let fiveMinuteCutoff = end - HistoryRetention.minimumFiveMinute
            let expiredFiveMinute = try await store.points(in: .fiveMinute, from: .distantPast, to: Date(timeIntervalSince1970: fiveMinuteCutoff))
            #expect(expiredFiveMinute.isEmpty)
            let keptFiveMinute = try await store.points(in: .fiveMinute, from: Date(timeIntervalSince1970: fiveMinuteCutoff), to: Date(timeIntervalSince1970: end))
            #expect(!keptFiveMinute.isEmpty)

            let hourlyCutoff = end - HistoryRetention.minimumHourly
            let expiredHourly = try await store.points(in: .hourly, from: .distantPast, to: Date(timeIntervalSince1970: hourlyCutoff))
            #expect(expiredHourly.isEmpty)
            let keptHourly = try await store.points(in: .hourly, from: Date(timeIntervalSince1970: hourlyCutoff), to: Date(timeIntervalSince1970: fiveMinuteCutoff))
            #expect(!keptHourly.isEmpty)
            #expect(await store.statistics.rowsPruned > 0)
        }
    }

    @Test func pointsThatExpiredWhileClosedArePrunedAtOpen() async throws {
        try await withScratchDirectory { directory in
            var store: MetricHistoryStore? = try openStore(directory, configuration: quietConfiguration())
            for index in 0..<50 {
                await store?.save(makeSnapshot(at: origin + Double(index) * 10))
            }
            await store?.flush()
            store = nil

            // Reopen six hours later with the smallest raw retention, so every point is older than the window.
            let laterOpen = origin + 3 * HistoryRetention.minimumRaw
            let shortRetention = try HistoryRetention(
                raw: HistoryRetention.minimumRaw,
                fiveMinute: HistoryRetention.minimumFiveMinute,
                hourly: HistoryRetention.minimumHourly
            )
            let reopened = try openStore(directory, retention: shortRetention, configuration: quietConfiguration(), now: laterOpen)
            // The newest five-minute bucket stays open until the next sample closes it, so its points are kept. Every point
            // before it is past retention and rolled up, so it is pruned.
            let newest = origin + 490
            let openStart = floor((newest - MetricHistoryStore.closeGrace) / 300) * 300
            let remaining = try await reopened.points(in: .raw, from: .distantPast, to: .distantFuture).map(\.start)
            #expect(remaining == (0..<50).map { origin + Double($0) * 10 }.filter { $0 >= openStart })
            #expect(!remaining.isEmpty)
        }
    }
}

@Suite("History store: queries")
struct HistoryStoreQueryTests {
    @Test func rangeQueriesUseTheTimeIndexNotAFullScan() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration())
            for tier in HistoryTier.allCases {
                let plan = try await store.queryPlan(for: tier)
                #expect(plan.contains { $0.contains("SEARCH points USING PRIMARY KEY") })
                #expect(!plan.contains { $0.hasPrefix("SCAN") })
            }
        }
    }

    @Test func weekSeriesIsBuiltFromHourlyRowsAndMatchesTheRawPointsInItsWindow() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration())
            let spacing: TimeInterval = 600
            let count = Int(9 * 86_400 / spacing)
            var generated: [TimeInterval] = []
            for index in 0..<count {
                let time = origin + Double(index) * spacing
                generated.append(time)
                await store.save(makeSnapshot(at: time))
            }
            let end = origin + Double(count) * spacing
            await store.maintain(now: end)

            let series = try await store.series(range: .week, now: Date(timeIntervalSince1970: end))
            let window = HistorySeries.window(range: .week, now: Date(timeIntervalSince1970: end))
            let expected = generated.filter { $0 >= window.start && $0 < window.end }.count

            #expect(series.cpu.count == 168)
            #expect(series.cpu.allSatisfy { $0 != nil })
            #expect(series.samples == expected)
        }
    }

    @Test func aDayAtFiveMinuteResolutionHasOneSlotPerBucket() async throws {
        try await withScratchDirectory { directory in
            let store = try openStore(directory, configuration: quietConfiguration())
            for index in 0..<720 {
                await store.save(makeSnapshot(at: origin + Double(index) * 10))
            }
            let series = try await store.series(range: .day, now: Date(timeIntervalSince1970: origin + 7_200))
            #expect(series.cpu.count == 288)
            #expect(series.samples == 720)
        }
    }
}

@Suite("History store: recovery")
struct HistoryStoreRecoveryTests {
    @Test func aDamagedFileIsMovedAsideAndAFreshStoreStarts() async throws {
        try await withScratchDirectory { directory in
            let file = directory.appendingPathComponent("history.sqlite")
            try Data(repeating: 0x42, count: 4_096).write(to: file)

            let store = try openStore(directory)
            let note = try #require(store.recoveryNote)
            #expect(note.contains("damaged"))
            #expect(await store.notice() == note)
            #expect(try fileNames(in: directory).filter { $0.hasPrefix("history.sqlite.damaged-") }.count == 1)

            await store.save(makeSnapshot(at: origin))
            await store.flush()
            #expect(try await store.rowCount(.raw).points == 1)
        }
    }

    @Test func aTruncatedFileIsTreatedAsDamaged() async throws {
        try await withScratchDirectory { directory in
            try Data([0x53, 0x51]).write(to: directory.appendingPathComponent("history.sqlite"))
            let store = try openStore(directory)
            #expect(store.recoveryNote != nil)
            #expect(try await store.rowCount(.raw).points == 0)
        }
    }

    /// A write that never reached COMMIT must leave nothing behind. Closing the connection with the transaction open
    /// is the same situation as a crash in the middle of a write.
    @Test func anUncommittedWriteIsRolledBackWhenTheConnectionCloses() async throws {
        try await withScratchDirectory { directory in
            var store: MetricHistoryStore? = try openStore(directory, configuration: quietConfiguration())
            await store?.save(makeSnapshot(at: origin))
            await store?.flush()
            store = nil

            let file = directory.appendingPathComponent("history.sqlite")
            let connection = try SQLiteDatabase(path: file.path)
            try connection.execute("BEGIN IMMEDIATE")
            try connection.execute("""
                INSERT INTO points (host, tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max)
                VALUES ('local', 0, \(origin + 10), 1, 0.5, 1, 0.5, 0, 0, NULL, 0, 0, NULL, 0, 0, NULL)
                """)
            connection.close()

            let reopened = try openStore(directory, configuration: quietConfiguration())
            #expect(reopened.recoveryNote == nil)
            #expect(try await reopened.rowCount(.raw).points == 1)
            #expect(try await reopened.points(in: .raw, from: .distantPast, to: .distantFuture).map(\.start) == [origin])
        }
    }
}

@Suite("History store and the sampling engine")
struct HistoryStoreEngineTests {
    @Test func shutdownWritesPointsTheStoreWasHoldingBack() async throws {
        let store = try MetricHistoryStore.inMemory(configuration: quietConfiguration())
        let engine = SamplingEngine(provider: MockSystemMetricsProvider(), store: store)
        _ = await engine.collectNow()
        #expect(await store.statistics.transactions == 0)

        await engine.shutdown()
        #expect(await store.statistics.transactions == 1)
        #expect(try await store.rowCount(.raw).points == 1)
    }

    @Test func sleepWritesPointsBeforeTheMachineSleeps() async throws {
        let store = try MetricHistoryStore.inMemory(configuration: quietConfiguration())
        let engine = SamplingEngine(provider: MockSystemMetricsProvider(), store: store)
        _ = await engine.collectNow()

        await engine.suspend()
        #expect(await store.statistics.transactions == 1)
        await engine.shutdown()
    }
}
