import Foundation
import os
import Testing
@testable import MacFleetKit

/// Clock the tests advance by hand, so rates are exact rather than timing-dependent.
private final class ManualClock: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: TimeInterval(0))

    var now: TimeInterval {
        state.withLock { $0 }
    }

    func set(_ value: TimeInterval) {
        state.withLock { $0 = value }
    }
}

private func volume(
    _ mountPoint: String,
    total: UInt64 = 1_000,
    available: UInt64 = 250,
    removable: Bool = false,
    browsable: Bool = true
) -> RawVolume {
    RawVolume(
        name: mountPoint == "/" ? "Macintosh HD" : mountPoint,
        mountPoint: mountPoint,
        isRemovable: removable,
        isBrowsable: browsable,
        totalBytes: .available(total),
        availableBytes: .available(available)
    )
}

private func interface(
    _ name: String,
    received: UInt64,
    sent: UInt64,
    up: Bool = true,
    loopback: Bool = false
) -> RawInterface {
    RawInterface(
        name: name,
        isUp: up,
        isLoopback: loopback,
        ipv4Addresses: loopback ? ["127.0.0.1"] : ["192.168.1.20"],
        totals: .available(NetworkTotals(bytesReceived: received, bytesSent: sent))
    )
}

private func provider(
    volumes: [Result<[RawVolume], MetricIssue>] = [],
    interfaces: [Result<[RawInterface], MetricIssue>] = [],
    clock: ManualClock = ManualClock()
) -> ProcessSystemMetricsProvider {
    ProcessSystemMetricsProvider(
        counters: MockHostCounters(virtualMemory: [.success(VMCounters(
            pageSize: 16_384,
            internalPages: 1_000,
            purgeablePages: 0,
            wiredPages: 0,
            compressedPages: 0
        ))]),
        volumes: MockVolumeSource(volumes),
        interfaces: MockInterfaceSource(interfaces),
        minimumCPUWindow: 0,
        minimumNetworkWindow: 1,
        clock: { clock.now }
    )
}

@Suite("Scripted volume metrics")
struct ScriptedVolumeProviderTests {
    @Test func capacityAndUtilizationComeFromTheVolume() async throws {
        let snapshot = try await provider(volumes: [.success([volume("/")])]).snapshot(selection: .all)
        let volumes = try #require(snapshot.volumes.availableValue)
        let root = try #require(volumes.first)
        #expect(root.name == "Macintosh HD")
        #expect(root.capacity.availableValue?.totalBytes == 1_000)
        #expect(root.capacity.availableValue?.availableBytes == 250)
        #expect(abs((root.capacity.availableValue?.utilization ?? 0) - 0.75) < 1e-12)
    }

    @Test func excludedVolumeKeepsItsIdentityButIsNotMeasured() async throws {
        var selection = MonitoringSelection.default
        selection.setVolume(at: "/Volumes/USB", monitored: false)
        let snapshot = try await provider(volumes: [.success([volume("/Volumes/USB", removable: true)])])
            .snapshot(selection: selection)
        let usb = try #require(snapshot.volumes.availableValue?.first)
        #expect(usb.mountPoint == "/Volumes/USB")
        #expect(usb.isRemovable)
        #expect(usb.capacity == .unavailable(.notMonitored))
    }

    @Test func permissionFailureStaysOnTheVolumeWithItsReason() async throws {
        let denied = RawVolume(
            name: "Private",
            mountPoint: "/Volumes/Private",
            isRemovable: false,
            isBrowsable: true,
            totalBytes: .unavailable(.permissionDenied(resource: "volume attributes")),
            availableBytes: .unavailable(.permissionDenied(resource: "volume attributes"))
        )
        let snapshot = try await provider(volumes: [.success([volume("/"), denied])]).snapshot(selection: .all)
        let volumes = try #require(snapshot.volumes.availableValue)
        #expect(volumes.count == 2)
        #expect(volumes[1].capacity == .unavailable(.permissionDenied(resource: "volume attributes")))
        #expect(volumes[0].capacity.availableValue != nil)
    }

    @Test func volumeListFailureIsReportedWithoutAffectingCPUOrMemory() async throws {
        let snapshot = try await provider(volumes: [.failure(.notProvided(resource: "mounted volume list"))])
            .snapshot(selection: .all)
        #expect(snapshot.volumes == .unavailable(.notProvided(resource: "mounted volume list")))
        #expect(snapshot.memory.availableValue != nil)
    }

    @Test func hiddenSystemVolumesAreStillListed() async throws {
        let snapshot = try await provider(volumes: [.success([volume("/System/Volumes/VM", browsable: false)])])
            .snapshot(selection: .all)
        let vm = try #require(snapshot.volumes.availableValue?.first)
        #expect(!vm.isBrowsable)
        #expect(vm.capacity.availableValue != nil)
    }
}

@Suite("Scripted network metrics")
struct ScriptedNetworkProviderTests {
    @Test func ratesComeFromCounterDeltasOverTheClockWindow() async throws {
        let clock = ManualClock()
        let sampler = provider(interfaces: [
            .success([interface("en0", received: 1_000, sent: 500)]),
            .success([interface("en0", received: 3_000, sent: 1_500)]),
        ], clock: clock)

        clock.set(0)
        let first = try await sampler.snapshot(selection: .all)
        #expect(first.network.availableValue?.first?.rates == .unavailable(.notSampled))

        clock.set(2)
        let second = try await sampler.snapshot(selection: .all)
        let en0 = try #require(second.network.availableValue?.first)
        #expect(en0.totals.availableValue == NetworkTotals(bytesReceived: 3_000, bytesSent: 1_500))
        #expect(en0.rates.availableValue == NetworkRate(receivedPerSecond: 1_000, sentPerSecond: 500))
    }

    @Test func counterResetIsReportedThenRecovers() async throws {
        let clock = ManualClock()
        let sampler = provider(interfaces: [
            .success([interface("en0", received: 9_000, sent: 0)]),
            .success([interface("en0", received: 100, sent: 0)]),
            .success([interface("en0", received: 600, sent: 0)]),
        ], clock: clock)

        clock.set(0)
        _ = try await sampler.snapshot(selection: .all)
        clock.set(1)
        let reset = try await sampler.snapshot(selection: .all)
        #expect(reset.network.availableValue?.first?.rates == .unavailable(.counterReset))
        clock.set(2)
        let recovered = try await sampler.snapshot(selection: .all)
        #expect(recovered.network.availableValue?.first?.rates.availableValue?.receivedPerSecond == 500)
    }

    @Test func disconnectedInterfaceIsReportedDownWithZeroRate() async throws {
        let clock = ManualClock()
        let sampler = provider(interfaces: [
            .success([interface("en0", received: 1_000, sent: 0)]),
            .success([interface("en0", received: 1_000, sent: 0, up: false)]),
        ], clock: clock)

        clock.set(0)
        _ = try await sampler.snapshot(selection: .all)
        clock.set(2)
        let down = try await sampler.snapshot(selection: .all)
        let en0 = try #require(down.network.availableValue?.first)
        #expect(!en0.isUp)
        #expect(en0.rates.availableValue == NetworkRate(receivedPerSecond: 0, sentPerSecond: 0))
    }

    @Test func excludedLoopbackIsListedButNotMeasured() async throws {
        let sampler = provider(interfaces: [.success([
            interface("en0", received: 1, sent: 1),
            interface("lo0", received: 1, sent: 1, loopback: true),
        ])])
        let snapshot = try await sampler.snapshot()
        let interfaces = try #require(snapshot.network.availableValue)
        let loopback = try #require(interfaces.first { $0.name == "lo0" })
        #expect(loopback.isLoopback)
        #expect(loopback.totals == .unavailable(.notMonitored))
        #expect(loopback.rates == .unavailable(.notMonitored))
        #expect(interfaces.first { $0.name == "en0" }?.totals.availableValue != nil)
    }

    @Test func interfaceDiscoveryFailureIsIsolated() async throws {
        let sampler = provider(
            volumes: [.success([volume("/")])],
            interfaces: [.failure(.kernelCallFailed(call: "getifaddrs", code: 1))]
        )
        let snapshot = try await sampler.snapshot(selection: .all)
        #expect(snapshot.network == .unavailable(.kernelCallFailed(call: "getifaddrs", code: 1)))
        #expect(snapshot.volumes.availableValue?.first?.mountPoint == "/")
    }

    @Test func missingCountersAreReportedPerInterface() async throws {
        let noCounters = RawInterface(
            name: "utun0",
            isUp: true,
            isLoopback: false,
            ipv4Addresses: [],
            totals: .unavailable(.notProvided(resource: "interface counters"))
        )
        let snapshot = try await provider(interfaces: [.success([noCounters])]).snapshot(selection: .all)
        let utun = try #require(snapshot.network.availableValue?.first)
        #expect(utun.totals == .unavailable(.notProvided(resource: "interface counters")))
        #expect(utun.rates == .unavailable(.notProvided(resource: "interface counters")))
    }
}

@Suite("Live volume and interface metrics")
struct LiveStorageAndNetworkTests {
    @Test func liveInterfaceListIncludesLoopbackWithCounters() throws {
        let interfaces = try SystemInterfaceSource().interfaces()
        let loopback = try #require(interfaces.first { $0.name == "lo0" })
        #expect(loopback.isLoopback)
        #expect(loopback.isUp)
        #expect(loopback.ipv4Addresses.contains("127.0.0.1"))
        #expect(loopback.totals.availableValue != nil)
    }

    @Test func liveNetworkRatesAreAvailableAfterTwoSamples() async throws {
        let sampler = ProcessSystemMetricsProvider(minimumNetworkWindow: 0.2)
        _ = try await sampler.snapshot(selection: .all)
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = try await sampler.snapshot(selection: .all)

        let interfaces = try #require(snapshot.network.availableValue)
        let loopback = try #require(interfaces.first { $0.name == "lo0" })
        let rate = try #require(loopback.rates.availableValue)
        #expect(rate.receivedPerSecond >= 0)
        #expect(rate.sentPerSecond >= 0)
    }

    @Test func liveVolumesAreListedWithSelectionApplied() async throws {
        let snapshot = try await ProcessSystemMetricsProvider(minimumCPUWindow: 0).snapshot(selection: .all)
        let volumes = try #require(snapshot.volumes.availableValue)
        let root = try #require(volumes.first { $0.mountPoint == "/" })
        let capacity = try #require(root.capacity.availableValue)
        #expect((0...1).contains(capacity.utilization))
    }
}
