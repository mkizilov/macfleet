import Foundation
import Testing
@testable import MacFleetKit

private func makeListing(
    _ pid: Int32,
    name: String? = "worker",
    cpuSeconds: Double,
    start: UInt64? = 1_000_000
) -> ProcessListing {
    ProcessListing(
        pid: pid,
        name: name,
        outcome: .readable(ProcessCounters(
            startMicroseconds: start,
            cpuNanoseconds: UInt64(cpuSeconds * 1_000_000_000),
            footprintBytes: 1 << 20
        ))
    )
}

/// A monitor that reads the scripted listings, with a clock the test moves by hand so CPU windows are exact.
private func makeMonitor(
    _ script: [Result<[ProcessListing], MetricIssue>],
    minimumWindow: TimeInterval = 1
) -> (monitor: ProcessMonitor, clock: ClockBox) {
    let clock = ClockBox()
    let monitor = ProcessMonitor(
        source: MockProcessInventory(script),
        minimumWindow: minimumWindow,
        clock: { (Date(timeIntervalSince1970: clock.now), clock.now) }
    )
    return (monitor, clock)
}

@Suite("Process monitor: CPU percentage")
struct ProcessMonitorCPUTests {
    @Test func theFirstReadingHasNoPercentageAndTheSecondDerivesOneFromCPUTime() async throws {
        let (monitor, clock) = makeMonitor([
            .success([makeListing(42, cpuSeconds: 0)]),
            .success([makeListing(42, cpuSeconds: 1)]),
        ])
        let first = await monitor.sample()
        #expect(try #require(first.records.availableValue?.first).cpuPercent == .unavailable(.notSampled))

        clock.set(2)
        let second = await monitor.sample()
        #expect(try #require(second.records.availableValue?.first).cpuPercent == .available(50))
    }

    @Test func aShortWindowKeepsTheBaselineInsteadOfAdvancingIt() async throws {
        let (monitor, clock) = makeMonitor([
            .success([makeListing(7, cpuSeconds: 0)]),
            .success([makeListing(7, cpuSeconds: 0.25)]),
            .success([makeListing(7, cpuSeconds: 1)]),
        ])
        _ = await monitor.sample()

        clock.set(0.5)
        let short = await monitor.sample()
        #expect(try #require(short.records.availableValue?.first).cpuPercent == .unavailable(.notSampled))

        clock.set(2)
        let full = await monitor.sample()
        #expect(try #require(full.records.availableValue?.first).cpuPercent == .available(50))
    }

    @Test func aShortWindowRepeatsTheLastPercentage() async throws {
        let (monitor, clock) = makeMonitor([
            .success([makeListing(7, cpuSeconds: 0)]),
            .success([makeListing(7, cpuSeconds: 1)]),
            .success([makeListing(7, cpuSeconds: 1.1)]),
        ])
        _ = await monitor.sample()
        clock.set(2)
        _ = await monitor.sample()

        clock.set(2.5)
        let repeated = await monitor.sample()
        #expect(try #require(repeated.records.availableValue?.first).cpuPercent == .available(50))
    }

    @Test func aBackwardsCounterIsAResetAndTheNextWindowRecovers() async throws {
        let (monitor, clock) = makeMonitor([
            .success([makeListing(7, cpuSeconds: 5)]),
            .success([makeListing(7, cpuSeconds: 1)]),
            .success([makeListing(7, cpuSeconds: 2)]),
        ])
        _ = await monitor.sample()

        clock.set(2)
        let reset = await monitor.sample()
        #expect(try #require(reset.records.availableValue?.first).cpuPercent == .unavailable(.counterReset))

        clock.set(4)
        let recovered = await monitor.sample()
        #expect(try #require(recovered.records.availableValue?.first).cpuPercent == .available(50))
    }
}

@Suite("Process monitor: processes that change during collection")
struct ProcessMonitorIdentityTests {
    @Test func aProcessThatExitsMidCollectionIsOmittedWhileOthersStillReport() async throws {
        let (monitor, clock) = makeMonitor([
            .success([makeListing(7, cpuSeconds: 0), makeListing(8, cpuSeconds: 0)]),
            .success([ProcessListing(pid: 7, name: "worker", outcome: .gone), makeListing(8, cpuSeconds: 1)]),
            .success([makeListing(7, cpuSeconds: 4), makeListing(8, cpuSeconds: 2)]),
        ])
        _ = await monitor.sample()

        clock.set(2)
        let during = try #require(await monitor.sample().records.availableValue)
        #expect(during.map(\.pid) == [8])
        #expect(try #require(during.first).cpuPercent == .available(50))

        clock.set(4)
        let after = try #require(await monitor.sample().records.availableValue)
        let reappeared = try #require(after.first(where: { $0.pid == 7 }))
        #expect(reappeared.cpuPercent == .unavailable(.notSampled))
    }

    @Test func aReusedPIDWithADifferentStartTimeDoesNotInheritTheOldBaseline() async throws {
        let (monitor, clock) = makeMonitor([
            .success([makeListing(7, cpuSeconds: 100, start: 1_000)]),
            .success([makeListing(7, cpuSeconds: 101, start: 2_000)]),
        ])
        _ = await monitor.sample()

        clock.set(2)
        let row = try #require(await monitor.sample().records.availableValue?.first)
        #expect(row.cpuPercent == .unavailable(.notSampled))
        #expect(row.id == ProcessIdentity(pid: 7, startMicroseconds: 2_000))
    }
}

@Suite("Process monitor: unreadable processes")
struct ProcessMonitorPermissionTests {
    @Test func aDeniedProcessKeepsItsNameAndPIDButShowsReasonsInPlaceOfValues() async throws {
        let (monitor, _) = makeMonitor([
            .success([ProcessListing(pid: 1, name: "launchd", outcome: .denied)]),
        ])
        let row = try #require(await monitor.sample().records.availableValue?.first)

        #expect(row.pid == 1)
        #expect(row.name == .available("launchd"))
        #expect(row.isReadable == false)
        #expect(row.footprintBytes == .unavailable(.permissionRestricted(reason: ProcessMonitor.deniedReason)))
        #expect(row.cpuPercent == .unavailable(.permissionRestricted(reason: ProcessMonitor.deniedReason)))
        #expect(row.startDate.availableValue == nil)
    }

    @Test func aProcessWithoutAReadableNameStillReportsItsValues() async throws {
        let (monitor, _) = makeMonitor([
            .success([makeListing(3, name: nil, cpuSeconds: 0)]),
        ])
        let row = try #require(await monitor.sample().records.availableValue?.first)
        #expect(row.name == .unavailable(.permissionRestricted(reason: ProcessMonitor.nameReason)))
        #expect(row.isReadable)
        #expect(row.footprintBytes.availableValue == 1 << 20)
    }

    @Test func aFailedListingIsOneUnavailableSnapshotNotAnEmptyList() async {
        let (monitor, _) = makeMonitor([
            .failure(.kernelCallFailed(call: "proc_listpids", code: 1)),
        ])
        let snapshot = await monitor.sample()
        #expect(snapshot.records == .unavailable(.kernelCallFailed(call: "proc_listpids", code: 1)))
    }
}

@Suite("Process CPU time units")
struct ProcessCPUTimeUnitTests {
    @Test func absoluteTicksConvertToNanoseconds() {
        // Apple silicon's timebase is 125/3 nanoseconds per tick, so 3 ticks are 125 ns.
        #expect(DarwinProcessInventory.nanoseconds(absoluteTime: 3, numerator: 125, denominator: 3) == 125)
        #expect(DarwinProcessInventory.nanoseconds(absoluteTime: 7, numerator: 1, denominator: 1) == 7)
        #expect(DarwinProcessInventory.nanoseconds(absoluteTime: 7, numerator: 3, denominator: 0) == 7)
    }
}
