import Foundation
import MacFleetKit
import MacFleetState
import Testing

/// Capture times are exact: every sample is stamped with the simulated clock, never the wall clock.
private let start = Date(timeIntervalSince1970: 1_700_000_000)

private func time(_ seconds: Double) -> Date {
    start.addingTimeInterval(seconds)
}

private func makeSettings(
    _ metric: AlertMetric,
    threshold: Double? = nil,
    sustained: Double = 30,
    cooldown: Double = 900,
    enabled: Bool = true
) -> AlertSettings {
    var settings = AlertSettings()
    settings.setRule(
        AlertRule(
            isEnabled: enabled,
            threshold: threshold ?? metric.defaultThreshold,
            sustainedSeconds: sustained,
            cooldownSeconds: cooldown
        ),
        for: metric
    )
    return settings
}

private func snapshot(
    at time: Date,
    cpu: Double? = nil,
    memory: MemoryPressureLevel? = nil,
    thermal: ThermalState? = nil,
    volumes: [VolumeMetrics]? = nil,
    network: [NetworkInterfaceMetrics]? = nil
) -> SystemSnapshot {
    SystemSnapshot(
        capturedAt: time,
        hostName: "test-mac",
        operatingSystemVersion: "test",
        activeProcessorCount: 8,
        physicalMemoryBytes: 1,
        uptimeSeconds: 1,
        loadAverage: LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0),
        cpu: cpu.map { .available(CPUUtilization(total: $0, perCore: .unavailable(.notSampled))) } ?? .unavailable(.notSampled),
        memoryPressure: memory.map { .available($0) } ?? .unavailable(.notSampled),
        volumes: volumes.map { .available($0) } ?? .unavailable(.notSampled),
        network: network.map { .available($0) } ?? .unavailable(.notSampled),
        hardware: thermal.map { MockHardwareScenario.appleSiliconLaptop.sample(thermal: $0) } ?? .unavailable(.notSampled)
    )
}

private func volume(_ mountPoint: String, name: String, freePercent: Double) -> VolumeMetrics {
    let total: UInt64 = 1_000_000
    let available = UInt64(Double(total) * freePercent / 100)
    return VolumeMetrics(
        name: name,
        mountPoint: mountPoint,
        isRemovable: false,
        isBrowsable: true,
        capacity: .available(DiskCapacity(totalBytes: total, availableBytes: available))
    )
}

private func interface(_ name: String, received: Double, sent: Double) -> NetworkInterfaceMetrics {
    NetworkInterfaceMetrics(
        name: name,
        isUp: true,
        isLoopback: false,
        ipv4Addresses: [],
        totals: .unavailable(.notSampled),
        rates: .available(NetworkRate(receivedPerSecond: received, sentPerSecond: sent))
    )
}

@Suite("Alert engine: sustained breaches")
struct AlertSustainedTests {
    @Test func aBreachFiresOnceWhenItHasLastedTheSustainedPeriod() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 120, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        #expect(notices.map(\.firedAt) == [time(30)])
        #expect(notices.first?.key == AlertKey(metric: .highCPU))
        #expect(notices.first?.title == "High CPU use")
        #expect(notices.first?.message == "CPU is at 95%, at or above the 90% threshold.")
        #expect(engine.status.firing[.highCPU] == ["High CPU use"])
    }

    @Test func aBreachThatEndsBeforeTheSustainedPeriodNeverNotifies() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 20, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        for seconds in stride(from: 22.0, through: 200, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.5))
        }
        #expect(notices.isEmpty)
        #expect(engine.status == .idle)
    }

    @Test func oneSampleBelowTheThresholdRestartsTheSustainedPeriod() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 28, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        notices += engine.evaluate(snapshot(at: time(30), cpu: 0.80))
        for seconds in stride(from: 32.0, through: 80, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        #expect(notices.map(\.firedAt) == [time(62)])
    }

    @Test func zeroSustainedPeriodFiresOnTheFirstSampleThatMeetsTheThreshold() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 0))
        let notices = engine.evaluate(snapshot(at: time(0), cpu: 0.95))
        #expect(notices.map(\.firedAt) == [time(0)])
    }

    @Test func aSnapshotWithoutReadingsNeverAlerts() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 0))
        #expect(engine.evaluate(snapshot(at: time(0))).isEmpty)
        #expect(engine.status == .idle)
    }
}

@Suite("Alert engine: hysteresis and cooldown")
struct AlertCooldownTests {
    @Test func theHysteresisBandHoldsAnActiveAlertAndOnlyPassingItClearsIt() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 30, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        for seconds in stride(from: 32.0, through: 60, by: 2) {
            // 88% sits inside the band between the 85% clear point and the 90% threshold.
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.88))
            #expect(engine.status.firing[.highCPU] != nil)
        }
        notices += engine.evaluate(snapshot(at: time(62), cpu: 0.84))
        #expect(engine.status.firing[.highCPU] == nil)
        #expect(notices.map(\.firedAt) == [time(30)])
    }

    @Test func aNoticeSuppressedByCooldownIsSentWhenTheCooldownEndsWhileTheAlertPersists() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30, cooldown: 900))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 30, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        notices += engine.evaluate(snapshot(at: time(32), cpu: 0.5))
        for seconds in stride(from: 34.0, through: 960, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        #expect(notices.map(\.firedAt) == [time(30), time(930)])
    }

    @Test func aSuppressedNoticeIsDroppedIfTheAlertClearsBeforeTheCooldownEnds() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30, cooldown: 900))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 30, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        notices += engine.evaluate(snapshot(at: time(32), cpu: 0.5))
        for seconds in stride(from: 34.0, through: 66, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        for seconds in stride(from: 68.0, through: 1_000, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.5))
        }
        #expect(notices.map(\.firedAt) == [time(30)])
        #expect(engine.status == .idle)
    }

    @Test func anAlertFiresAgainAfterItsCooldownHasEnded() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30, cooldown: 900))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 30, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        for seconds in stride(from: 32.0, through: 1_998, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.5))
        }
        for seconds in stride(from: 2_000.0, through: 2_030, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        #expect(notices.map(\.firedAt) == [time(30), time(2_030)])
    }

    @Test func unavailableReadingsHoldAnActiveAlertAndBreakAPendingPeriod() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 30, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        for seconds in stride(from: 32.0, through: 100, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds)))
        }
        #expect(engine.status.firing[.highCPU] != nil)
        #expect(notices.map(\.firedAt) == [time(30)])

        var pending = AlertEngine(settings: makeSettings(.highCPU, sustained: 30))
        var pendingNotices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 10, by: 2) {
            pendingNotices += pending.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        _ = pending.evaluate(snapshot(at: time(12)))
        #expect(pending.status.waiting.isEmpty)
        for seconds in stride(from: 14.0, through: 50, by: 2) {
            pendingNotices += pending.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        #expect(pendingNotices.map(\.firedAt) == [time(44)])
    }

    @Test func aSleepGapDoesNotCountTowardTheSustainedPeriod() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 30))
        var notices: [AlertNotice] = []
        for seconds in stride(from: 0.0, through: 20, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        // The Mac sleeps for 980 seconds, so no samples arrive until it wakes.
        for seconds in stride(from: 1_000.0, through: 1_030, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        #expect(notices.map(\.firedAt) == [time(1_030)])
    }

    @Test func disablingAMetricClearsItsAlertAndStopsItsNotices() {
        var engine = AlertEngine(settings: makeSettings(.highCPU, sustained: 0))
        var notices = engine.evaluate(snapshot(at: time(0), cpu: 0.95))
        #expect(engine.status.firing[.highCPU] != nil)

        engine.apply(makeSettings(.highCPU, sustained: 0, enabled: false))
        #expect(engine.status == .idle)
        for seconds in stride(from: 2.0, through: 200, by: 2) {
            notices += engine.evaluate(snapshot(at: time(seconds), cpu: 0.95))
        }
        #expect(notices.map(\.firedAt) == [time(0)])
    }
}

@Suite("Alert engine: volumes and network")
struct AlertInputTests {
    @Test func eachVolumeAlertsOnItsOwnAndEndsWhenTheVolumeIsGone() {
        var engine = AlertEngine(settings: makeSettings(.lowDiskSpace, threshold: 10, sustained: 0))
        let both = [
            volume("/", name: "Macintosh HD", freePercent: 5),
            volume("/Volumes/USB", name: "USB", freePercent: 60),
        ]
        var notices = engine.evaluate(snapshot(at: time(0), volumes: both))
        #expect(notices.map(\.key) == [AlertKey(metric: .lowDiskSpace, subject: "/")])
        #expect(notices.first?.message == "Macintosh HD has 5% free, at or below the 10% threshold.")

        let usbLow = [
            volume("/", name: "Macintosh HD", freePercent: 5),
            volume("/Volumes/USB", name: "USB", freePercent: 8),
        ]
        notices += engine.evaluate(snapshot(at: time(2), volumes: usbLow))
        #expect(notices.map(\.key.subject) == ["/", "/Volumes/USB"])
        #expect(engine.status.firing[.lowDiskSpace] == ["Macintosh HD", "USB"])

        _ = engine.evaluate(snapshot(at: time(4), volumes: [volume("/", name: "Macintosh HD", freePercent: 5)]))
        #expect(engine.status.firing[.lowDiskSpace] == ["Macintosh HD"])
    }

    @Test func volumesThatAreNotMonitoredAreIgnored() {
        var engine = AlertEngine(settings: makeSettings(.lowDiskSpace, threshold: 10, sustained: 0))
        let unmonitored = VolumeMetrics(
            name: "Scratch",
            mountPoint: "/Volumes/Scratch",
            isRemovable: true,
            isBrowsable: true,
            capacity: .unavailable(.notMonitored)
        )
        #expect(engine.evaluate(snapshot(at: time(0), volumes: [unmonitored])).isEmpty)
        #expect(engine.status == .idle)
    }

    @Test func networkUsesTheCombinedMonitoredRateAndWaitsForEveryInterface() {
        var engine = AlertEngine(settings: makeSettings(.highNetwork, threshold: 50, sustained: 0))
        let notices = engine.evaluate(snapshot(at: time(0), network: [interface("en0", received: 30e6, sent: 25e6)]))
        #expect(notices.first?.message == "Download and upload total 55 MB/s, at or above 50 MB/s.")

        var partial = AlertEngine(settings: makeSettings(.highNetwork, threshold: 50, sustained: 0))
        let withCounterReset = [
            interface("en0", received: 30e6, sent: 25e6),
            NetworkInterfaceMetrics(
                name: "en1",
                isUp: true,
                isLoopback: false,
                ipv4Addresses: [],
                totals: .unavailable(.notSampled),
                rates: .unavailable(.counterReset)
            ),
        ]
        #expect(partial.evaluate(snapshot(at: time(0), network: withCounterReset)).isEmpty)
    }
}

@Suite("Alert engine: pressure and thermal levels")
struct AlertLevelTests {
    @Test func memoryPressureFiresOnlyAtTheChosenLevel() {
        var critical = AlertEngine(settings: makeSettings(.memoryPressure, threshold: 2, sustained: 0))
        #expect(critical.evaluate(snapshot(at: time(0), memory: .warning)).isEmpty)
        let notices = critical.evaluate(snapshot(at: time(2), memory: .critical))
        #expect(notices.first?.message == "Memory pressure is Critical.")

        var warning = AlertEngine(settings: makeSettings(.memoryPressure, threshold: 1, sustained: 0))
        #expect(warning.evaluate(snapshot(at: time(0), memory: .warning)).count == 1)
    }

    @Test func thermalStateFiresAtSeriousAndClearsOnlyBelowIt() {
        var engine = AlertEngine(settings: makeSettings(.thermalPressure, threshold: 2, sustained: 0))
        #expect(engine.evaluate(snapshot(at: time(0), thermal: .fair)).isEmpty)
        #expect(engine.evaluate(snapshot(at: time(2), thermal: .serious)).count == 1)

        _ = engine.evaluate(snapshot(at: time(4), thermal: .critical))
        #expect(engine.status.firing[.thermalPressure] == ["Thermal pressure"])

        _ = engine.evaluate(snapshot(at: time(6), thermal: .fair))
        #expect(engine.status == .idle)
    }
}

@Suite("Alert engine: synthetic streams")
struct AlertStreamTests {
    /// A load that swings between idle and saturation over about 500 seconds, so it crosses the threshold again and
    /// again, and each crossing lasts long enough to be sustained.
    private func swingingLoad(samples: Int) -> [SystemSnapshot] {
        (0..<samples).map { index in
            snapshot(at: time(Double(index) * 2), cpu: 0.5 + 0.5 * sin(Double(index) / 40))
        }
    }

    @Test func theSameStreamAlwaysGivesTheSameNoticesAndCooldownSpacesThem() {
        let stream = swingingLoad(samples: 2_000)
        func run() -> [AlertNotice] {
            var engine = AlertEngine(settings: makeSettings(.highCPU, threshold: 90, sustained: 30, cooldown: 900))
            return stream.flatMap { engine.evaluate($0) }
        }

        let first = run()
        #expect(first == run())
        #expect(first.count >= 2)
        for (earlier, later) in zip(first, first.dropFirst()) {
            #expect(later.firedAt.timeIntervalSince(earlier.firedAt) >= 900)
        }
    }
}
