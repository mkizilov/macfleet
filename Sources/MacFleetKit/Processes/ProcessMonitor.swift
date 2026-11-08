import Foundation

/// Builds process snapshots and derives CPU percentages from cumulative CPU time.
///
/// - One sample reads the whole listing. The source is synchronous, so a sample runs to completion inside this actor
///   and two samples can never interleave.
/// - CPU percentage is the change in CPU time over the change in awake time, so a sleep does not inflate it.
/// - A process needs two readings before it has a CPU percentage. A window shorter than `minimumWindow` keeps the
///   older reading, so the next sample spans a full window instead of a noisy fraction of one.
/// - A process that is no longer listed loses its baseline, so a later process with the same identity starts over.
public actor ProcessMonitor {
    private struct Baseline: Equatable, Sendable {
        let cpuNanoseconds: UInt64
        let awakeSeconds: TimeInterval
        let percent: Double?
    }

    private let source: any ProcessInventorySource
    private let minimumWindow: TimeInterval
    private let clock: @Sendable () -> (wallClock: Date, awakeSeconds: TimeInterval)
    private var baselines: [ProcessIdentity: Baseline] = [:]

    /// Samples taken. Tests use it to show that sampling stops when the screen closes.
    public private(set) var sampleCount = 0

    public init(
        source: any ProcessInventorySource = DarwinProcessInventory(),
        minimumWindow: TimeInterval = 1,
        clock: @escaping @Sendable () -> (wallClock: Date, awakeSeconds: TimeInterval) = {
            (Date(), MonotonicTime.awakeSeconds())
        }
    ) {
        self.source = source
        self.minimumWindow = minimumWindow
        self.clock = clock
    }

    public func sample() -> ProcessSnapshot {
        sampleCount += 1
        let now = clock()
        let listings: [ProcessListing]
        do throws(MetricIssue) {
            listings = try source.listing()
        } catch {
            return ProcessSnapshot(capturedAt: now.wallClock, records: .unavailable(error))
        }

        var next: [ProcessIdentity: Baseline] = [:]
        var records: [ProcessRecord] = []
        records.reserveCapacity(listings.count)
        for listing in listings {
            switch listing.outcome {
            case .gone:
                continue
            case .denied:
                records.append(Self.deniedRecord(listing))
            case let .readable(counters):
                let identity = ProcessIdentity(pid: listing.pid, startMicroseconds: counters.startMicroseconds)
                let (cpu, baseline) = cpuReading(identity, counters, now)
                next[identity] = baseline
                records.append(ProcessRecord(
                    id: identity,
                    name: Self.name(listing),
                    startDate: Self.startDate(counters),
                    cpuPercent: cpu,
                    footprintBytes: .available(counters.footprintBytes)
                ))
            }
        }
        baselines = next
        return ProcessSnapshot(capturedAt: now.wallClock, records: .available(records))
    }

    private func cpuReading(
        _ identity: ProcessIdentity,
        _ counters: ProcessCounters,
        _ now: (wallClock: Date, awakeSeconds: TimeInterval)
    ) -> (MetricReading<Double>, Baseline) {
        let current = Baseline(cpuNanoseconds: counters.cpuNanoseconds, awakeSeconds: now.awakeSeconds, percent: nil)
        guard let previous = baselines[identity] else {
            return (.unavailable(.notSampled), current)
        }
        guard counters.cpuNanoseconds >= previous.cpuNanoseconds else {
            return (.unavailable(.counterReset), current)
        }
        let elapsed = now.awakeSeconds - previous.awakeSeconds
        guard elapsed >= minimumWindow else {
            if let percent = previous.percent {
                return (.available(percent), previous)
            }
            return (.unavailable(.notSampled), previous)
        }
        let used = Double(counters.cpuNanoseconds - previous.cpuNanoseconds)
        let percent = used / (elapsed * 1_000_000_000) * 100
        return (
            .available(percent),
            Baseline(cpuNanoseconds: counters.cpuNanoseconds, awakeSeconds: now.awakeSeconds, percent: percent)
        )
    }

    static let deniedReason = "macOS does not let MacFleet read this process."
    static let nameReason = "The executable's path is not readable."
    static let startReason = "macOS does not show the start time of this process."

    private static func deniedRecord(_ listing: ProcessListing) -> ProcessRecord {
        ProcessRecord(
            id: ProcessIdentity(pid: listing.pid, startMicroseconds: nil),
            name: name(listing),
            startDate: .unavailable(.permissionRestricted(reason: deniedReason)),
            cpuPercent: .unavailable(.permissionRestricted(reason: deniedReason)),
            footprintBytes: .unavailable(.permissionRestricted(reason: deniedReason))
        )
    }

    private static func name(_ listing: ProcessListing) -> MetricReading<String> {
        listing.name.map { .available($0) } ?? .unavailable(.permissionRestricted(reason: nameReason))
    }

    private static func startDate(_ counters: ProcessCounters) -> MetricReading<Date> {
        guard let microseconds = counters.startMicroseconds else {
            return .unavailable(.permissionRestricted(reason: startReason))
        }
        return .available(Date(timeIntervalSince1970: Double(microseconds) / 1_000_000))
    }
}
