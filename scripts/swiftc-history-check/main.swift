import Darwin
import Foundation
@testable import MacFleetKit

// Checks what the history store promises when a process dies in the middle of writing, and measures its cost.
//
//   history-check crash <directory> [trials]   SIGKILLs writer processes at random moments and checks each file.
//   history-check writer <file> <batches|upkeep>
//                                              writes points until killed; started by `crash`.
//   history-check benchmark <directory>        seven days at a 2-second cadence through the real store.
//
// Two write patterns are exercised, because each has a different atomicity property to check:
//   batches: rollups are off, so every commit is exactly one full batch. A torn transaction would leave a
//            partial batch, which breaks whole-batch alignment.
//   upkeep:  rollups and pruning run during the writes. Every five-minute bucket must hold exactly the samples
//            its raw points carry, counted once, whether it was rolled up or still raw.
// In both, the file must hold every batch the writer confirmed, plus at most one batch it committed without
// printing, and nothing partial.

let origin: TimeInterval = 1_700_000_000
let batchSize = 256
/// Long enough that nothing is pruned during a crash trial, so the file's contents can be checked exactly.
let longRetention = try HistoryRetention(raw: 30 * 86_400, fiveMinute: 60 * 86_400, hourly: 90 * 86_400)

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

func median(_ durations: [Duration]) -> Duration {
    durations.sorted()[durations.count / 2]
}

func residentMegabytes() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

func fileSize(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
}

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

func writerConfiguration(mode: String) -> MetricHistoryStore.Configuration {
    var configuration = MetricHistoryStore.Configuration()
    configuration.batchSize = batchSize
    configuration.batchAge = 1_000_000
    if mode == "batches" {
        configuration.maintenanceInterval = 1_000_000_000
    }
    return configuration
}

func runWriter(path: String, mode: String) async throws {
    let store = try MetricHistoryStore.open(
        at: URL(fileURLWithPath: path),
        retention: longRetention,
        configuration: writerConfiguration(mode: mode),
        now: Date(timeIntervalSince1970: origin)
    )
    var timeline = SimulatedMetricsTimeline(seed: 1)
    var index = 0
    var reported = 0
    while true {
        let snapshot = timeline.nextSnapshot(
            selection: .default,
            capturedAt: Date(timeIntervalSince1970: origin + Double(index) * 10)
        )
        await store.save(snapshot)
        index += 1
        let committed = (await store.statistics).rowsWritten / 3
        if committed != reported {
            reported = committed
            print("committed \(committed)")
            fflush(stdout)
        }
    }
}

/// Opens the file a killed writer left behind and checks it against what the writer confirmed.
func verify(path: String, mode: String, confirmed: Int) async throws -> (ok: Bool, detail: String) {
    let store = try MetricHistoryStore.open(
        at: URL(fileURLWithPath: path),
        retention: longRetention,
        configuration: MetricHistoryStore.Configuration(),
        now: Date(timeIntervalSince1970: origin)
    )
    if let note = store.recoveryNote {
        return (false, "file was damaged after the kill: \(note)")
    }
    let points = try await store.points(in: .raw, from: .distantPast, to: .distantFuture)
    let durable = points.count
    let contiguous = points.enumerated().allSatisfy { index, point in
        abs(point.start - (origin + Double(index) * 10)) < 1e-6
    }
    let volumesConsistent = points.allSatisfy { $0.volumes.count == 2 }
    let keepsConfirmed = durable >= confirmed
    let atMostOneUnconfirmed = durable <= confirmed + batchSize

    var shape = true
    var shapeDetail = ""
    if mode == "batches" {
        shape = durable % batchSize == 0
        shapeDetail = "wholeBatches=\(shape)"
    } else {
        let combined = try await store.points(in: .fiveMinute, from: .distantPast, to: .distantFuture)
        var counted: [TimeInterval: Int] = [:]
        for point in combined {
            counted[floor(point.start / 300) * 300, default: 0] += point.samples
        }
        var expected: [TimeInterval: Int] = [:]
        for point in points {
            expected[floor(point.start / 300) * 300, default: 0] += 1
        }
        shape = counted == expected
        shapeDetail = "rollupsCountEachPointOnce=\(shape)"
    }

    let ok = contiguous && volumesConsistent && keepsConfirmed && atMostOneUnconfirmed && shape
    return (ok, "confirmed=\(confirmed) durable=\(durable) contiguous=\(contiguous) volumes=\(volumesConsistent) \(shapeDetail)")
}

func runCrashTrials(directory: String, trials: Int) async throws -> Bool {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    var allOK = true
    for mode in ["batches", "upkeep"] {
        var confirmedCounts: [Int] = []
        var modeOK = true
        for trial in 1...trials {
            let file = root.appendingPathComponent("\(mode)-\(trial).sqlite")
            let log = root.appendingPathComponent("\(mode)-\(trial).log")
            // Created with open(2), not FileManager: Foundation's atomic file creation is denied by the sandbox.
            let descriptor = open(log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard descriptor >= 0 else {
                throw HarnessError(description: "could not create \(log.path) (errno \(errno))")
            }

            let child = Process()
            child.executableURL = executable
            child.arguments = ["writer", file.path, mode]
            child.standardOutput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try child.run()
            usleep(UInt32(Double.random(in: 0.3...1.5) * 1_000_000))
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()

            let lines = try String(contentsOf: log, encoding: .utf8)
            let confirmed = lines.split(separator: "\n").compactMap { Int($0.dropFirst("committed ".count)) }.max() ?? 0
            let result = try await verify(path: file.path, mode: mode, confirmed: confirmed)
            print("\(mode) trial \(trial): \(result.ok ? "ok" : "FAILED") \(result.detail)")
            modeOK = modeOK && result.ok
            confirmedCounts.append(confirmed)

            for path in [file.path, file.path + "-wal", file.path + "-shm", log.path] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        print("\(mode): \(trials) kill trials, all consistent: \(modeOK), confirmed points per trial: min \(confirmedCounts.min() ?? 0), max \(confirmedCounts.max() ?? 0)")
        allOK = allOK && modeOK
    }
    return allOK
}

func runBenchmark(directory: String) async throws {
    let file = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("benchmark.sqlite")
    let clock = ContinuousClock()
    let cadence: TimeInterval = 2
    let count = Int(7 * 86_400 / cadence)
    let memoryBefore = residentMegabytes()

    var store: MetricHistoryStore? = try MetricHistoryStore.open(at: file, now: Date(timeIntervalSince1970: origin))
    var timeline = SimulatedMetricsTimeline(seed: 42)
    var generation = Duration.zero
    var saving = Duration.zero
    var slowestSave = Duration.zero
    for index in 0..<count {
        let capturedAt = Date(timeIntervalSince1970: origin + Double(index) * cadence)
        let generationStart = clock.now
        let snapshot = timeline.nextSnapshot(selection: .default, capturedAt: capturedAt)
        generation += generationStart.duration(to: clock.now)
        let saveStart = clock.now
        await store?.save(snapshot)
        let elapsed = saveStart.duration(to: clock.now)
        saving += elapsed
        slowestSave = max(slowestSave, elapsed)
    }
    guard let open = store else { return }
    let statistics = await open.statistics
    let end = Date(timeIntervalSince1970: origin + Double(count) * cadence)
    let memoryAfterWrites = residentMegabytes()

    print("snapshots offered: \(count) over 7 days at a \(Int(cadence))-second cadence")
    print("accepted (one per 10 s): \(statistics.acceptedSnapshots), throttled: \(statistics.throttledSnapshots)")
    print("transactions: \(statistics.transactions), rows written: \(statistics.rowsWritten), rows pruned: \(statistics.rowsPruned), maintenance runs: \(statistics.maintenanceRuns), dropped: \(statistics.droppedPoints)")
    print(String(format: "time in save(): total %.1f ms, mean %.1f us, slowest %.2f ms (generating snapshots took %.1f ms)",
                 milliseconds(saving), milliseconds(saving) * 1_000 / Double(count), milliseconds(slowestSave), milliseconds(generation)))

    for tier in HistoryTier.allCases {
        let rows = try await open.rowCount(tier)
        print("stored \(tier): \(rows.points) points, \(rows.volumes) volume rows")
    }

    var medians: [String] = []
    for range in HistoryRange.allCases {
        var samples: [Duration] = []
        for _ in 0..<20 {
            let start = clock.now
            _ = try await open.series(range: range, now: end)
            samples.append(start.duration(to: clock.now))
        }
        medians.append(String(format: "%@ %.2f ms", "\(range)", milliseconds(median(samples))))
    }
    print("series query, median of 20: " + medians.joined(separator: ", "))

    store = nil
    let reopenStart = clock.now
    let reopened = try MetricHistoryStore.open(at: file, now: end)
    let reopenTime = reopenStart.duration(to: clock.now)
    print(String(format: "reopen (integrity check and upkeep): %.2f ms, recovery note: %@", milliseconds(reopenTime), reopened.recoveryNote ?? "none"))
    print(String(format: "file sizes: database %.2f MB, write-ahead log %.2f MB", Double(fileSize(file.path)) / 1_048_576, Double(fileSize(file.path + "-wal")) / 1_048_576))
    print(String(format: "resident memory: before %.1f MB, after writes %.1f MB", memoryBefore, memoryAfterWrites))
    try await runFleetBenchmark(directory: directory)
}

/// Stages rows in a transaction and kills itself before COMMIT. The kill is the process's last act, so the file must
/// hold only what was committed before it.
func runTornWriter(path: String) async throws {
    var store: MetricHistoryStore? = try MetricHistoryStore.open(
        at: URL(fileURLWithPath: path),
        retention: longRetention,
        configuration: writerConfiguration(mode: "batches"),
        now: Date(timeIntervalSince1970: origin)
    )
    var timeline = SimulatedMetricsTimeline(seed: 1)
    for index in 0..<300 {
        await store?.save(timeline.nextSnapshot(selection: .default, capturedAt: Date(timeIntervalSince1970: origin + Double(index) * 10)))
    }
    await store?.flush()
    store = nil

    let connection = try SQLiteDatabase(path: path)
    try connection.execute("BEGIN IMMEDIATE")
    for index in 0..<500 {
        try connection.execute("""
            INSERT INTO points (host, tier, start, samples, cpu_sum, cpu_n, cpu_max, mem_sum, mem_n, mem_max, rx_sum, rx_n, rx_max, tx_sum, tx_n, tx_max)
            VALUES ('local', 0, \(origin + 100_000 + Double(index) * 10), 1, 0.5, 1, 0.5, 0, 0, NULL, 0, 0, NULL, 0, 0, NULL)
            """)
    }
    kill(getpid(), SIGKILL)
}

func runTornTrials(directory: String, trials: Int) async throws -> Bool {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    var allOK = true
    for trial in 1...trials {
        let file = root.appendingPathComponent("torn-\(trial).sqlite")
        let child = Process()
        child.executableURL = executable
        child.arguments = ["writer", file.path, "torn"]
        try child.run()
        child.waitUntilExit()
        let killedAsPlanned = child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL

        let store = try MetricHistoryStore.open(
            at: file,
            retention: longRetention,
            configuration: MetricHistoryStore.Configuration(),
            now: Date(timeIntervalSince1970: origin)
        )
        let points = try await store.points(in: .raw, from: .distantPast, to: .distantFuture)
        let uncommittedVisible = points.contains { $0.start >= origin + 100_000 }
        let ok = killedAsPlanned && points.count == 300 && !uncommittedVisible && store.recoveryNote == nil
        print("torn trial \(trial): \(ok ? "ok" : "FAILED") killedBeforeCommit=\(killedAsPlanned) committed=300 found=\(points.count) uncommittedRowsVisible=\(uncommittedVisible)")
        allOK = allOK && ok

        for path in [file.path, file.path + "-wal", file.path + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
    return allOK
}

/// A remote Mac's snapshot with one constant CPU reading, so each Mac's mean shows whether it holds only its own rows.
func remoteSample(cpu: Double) -> RemoteSnapshot {
    RemoteSnapshot(
        capturedAt: Date(timeIntervalSince1970: origin),
        cpuTotal: .available(cpu),
        memory: .available(MemoryUsage(totalBytes: 10_000, usedBytes: 5_000, availableBytes: 5_000)),
        memoryPressure: .available(.normal),
        storage: .available([VolumeMetrics(
            name: "Macintosh HD",
            mountPoint: "/",
            isRemovable: false,
            isBrowsable: true,
            capacity: .available(DiskCapacity(totalBytes: 1_000_000, availableBytes: 400_000))
        )]),
        network: .available([NetworkInterfaceMetrics(
            name: "en0",
            isUp: true,
            isLoopback: false,
            ipv4Addresses: ["100.70.1.2"],
            totals: .unavailable(.notSampled),
            rates: .available(NetworkRate(receivedPerSecond: 1_000, sentPerSecond: 100))
        )]),
        thermal: .available(.nominal),
        loadAverage: .available(LoadAverage(oneMinute: 1, fiveMinutes: 1, fifteenMinutes: 1))
    )
}

/// Three remote Macs ingest at once, each at a two-second cadence for seven days, through the real store. Each Mac
/// reports its own constant CPU reading, so a row that landed under the wrong Mac shows in that Mac's mean. The run
/// fails if any Mac's readings are mixed or its stored count differs from the count the store should accept.
func runFleetBenchmark(directory: String) async throws {
    let file = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("fleet-benchmark.sqlite")
    let clock = ContinuousClock()
    let cadence: TimeInterval = 2
    let count = Int(7 * 86_400 / cadence)
    let end = Date(timeIntervalSince1970: origin + Double(count) * cadence)
    let fleet = try MetricHistoryStore.open(at: file, now: Date(timeIntervalSince1970: origin))
    let hosts = (0..<3).map { HistoryHostID(rawValue: "bench-\($0)") }
    let readings = [0.2, 0.4, 0.6]
    let acceptedPerHost = count / 5
    // Totals are exact for windows that start and end on five-minute boundaries, so the benchmark queries one.
    let windowStart = ceil(origin / 300) * 300
    let windowEnd = floor(end.timeIntervalSince1970 / 300) * 300
    // The store keeps one snapshot per 10 seconds (its raw resolution), so accepted times are 10 seconds apart.
    let expectedInWindow = (0..<acceptedPerHost).filter { index in
        let time = origin + Double(index) * 10
        return time >= windowStart && time < windowEnd
    }.count

    let ingestStart = clock.now
    await withTaskGroup(of: Void.self) { group in
        for (index, host) in hosts.enumerated() {
            let template = remoteSample(cpu: readings[index])
            group.addTask {
                for step in 0..<count {
                    let received = Date(timeIntervalSince1970: origin + Double(step) * cadence)
                    _ = await fleet.ingest(template.withCapturedAt(received), from: host, receivedAt: received)
                }
            }
        }
    }
    await fleet.flush()
    let ingesting = ingestStart.duration(to: clock.now)
    let statistics = await fleet.statistics
    let calls = hosts.count * count

    print("fleet: \(hosts.count) Macs ingesting at once, \(count) snapshots each at a \(Int(cadence))-second cadence over 7 days")
    print(String(format: "ingest calls %d in %.1f s (%.1f us per call); accepted %d, throttled %d, duplicates %d, clock regressions %d",
                 calls, milliseconds(ingesting) / 1_000, milliseconds(ingesting) * 1_000 / Double(calls),
                 statistics.acceptedSnapshots, statistics.throttledSnapshots, statistics.duplicateSnapshots, statistics.clockRegressions))
    guard statistics.acceptedSnapshots == hosts.count * acceptedPerHost else {
        throw HarnessError(description: "accepted \(statistics.acceptedSnapshots), expected \(hosts.count * acceptedPerHost)")
    }

    var mixed: [String] = []
    for (index, host) in hosts.enumerated() {
        let summary = try await fleet.summary(host: host, from: Date(timeIntervalSince1970: windowStart), to: Date(timeIntervalSince1970: windowEnd))
        let own = summary.samples == expectedInWindow && summary.cpu.count == expectedInWindow
            && abs((summary.cpu.mean ?? -1) - readings[index]) < 1e-9
        if !own {
            mixed.append("\(host.rawValue) (\(summary.samples) of \(expectedInWindow) snapshots, mean \(summary.cpu.mean ?? -1), own reading \(readings[index]))")
        }
        print(String(format: "%@: %d snapshots stored, mean CPU %.3f (its own reading %.1f), only its own rows: %@",
                     host.rawValue, summary.samples, summary.cpu.mean ?? -1, readings[index], own ? "true" : "false"))
    }
    guard mixed.isEmpty else {
        let writes = await fleet.lastWriteError ?? "none"
        throw HarnessError(description: "stored readings do not match each Mac's own readings: \(mixed.joined(separator: "; ")); dropped \(statistics.droppedPoints), last write error \(writes)")
    }

    var summaryTimes: [Duration] = []
    var seriesTimes: [Duration] = []
    for host in hosts {
        for _ in 0..<20 {
            let summaryStart = clock.now
            _ = try await fleet.summary(host: host, from: Date(timeIntervalSince1970: windowStart), to: Date(timeIntervalSince1970: windowEnd))
            summaryTimes.append(summaryStart.duration(to: clock.now))
            let seriesStart = clock.now
            _ = try await fleet.series(host: host, range: .week, now: end)
            seriesTimes.append(seriesStart.duration(to: clock.now))
        }
    }
    print(String(format: "per-Mac 7-day summary, median of 60: %.2f ms; week chart, median of 60: %.2f ms",
                 milliseconds(median(summaryTimes)), milliseconds(median(seriesTimes))))

    let exportStart = clock.now
    let rows = try await fleet.exportRows(
        hosts: hosts,
        from: Date(timeIntervalSince1970: windowStart),
        to: Date(timeIntervalSince1970: windowEnd),
        maximumPoints: 1_000
    )
    let exporting = exportStart.duration(to: clock.now)
    let tiers = Set(rows.map(\.resolution.label)).sorted().joined(separator: ", ")
    print(String(format: "export of 7 days for 3 Macs, budget 1000 points: %d rows in %.1f ms, tiers used: %@",
                 rows.count, milliseconds(exporting), tiers))
    print(String(format: "file size %.2f MB, write-ahead log %.2f MB",
                 Double(fileSize(file.path)) / 1_048_576, Double(fileSize(file.path + "-wal")) / 1_048_576))
}

let arguments = CommandLine.arguments
let usage = "usage: history-check crash <directory> [trials] | writer <file> <batches|upkeep> | benchmark <directory>"
switch arguments.count >= 2 ? arguments[1] : "" {
case "writer" where arguments.count == 4 && arguments[3] == "torn":
    try await runTornWriter(path: arguments[2])
case "writer" where arguments.count == 4 && ["batches", "upkeep"].contains(arguments[3]):
    try await runWriter(path: arguments[2], mode: arguments[3])
case "crash" where arguments.count >= 3:
    let trials = arguments.count >= 4 ? Int(arguments[3]) ?? 20 : 20
    let killed = try await runCrashTrials(directory: arguments[2], trials: trials)
    let torn = try await runTornTrials(directory: arguments[2], trials: 5)
    exit(killed && torn ? 0 : 1)
case "benchmark" where arguments.count == 3:
    try await runBenchmark(directory: arguments[2])
default:
    print(usage)
    exit(64)
}
