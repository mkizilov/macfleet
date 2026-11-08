import Foundation
import MacFleetKit
import Testing
@testable import MacFleetState

private let gibibyte: UInt64 = 1_073_741_824

private func snapshot(
    cpu: MetricReading<CPUUtilization> = .available(CPUUtilization(
        total: 0.12,
        perCore: .available([0.10, 0.20, 0.30, 0.10])
    )),
    memory: MetricReading<MemoryUsage> = .available(MemoryUsage(
        totalBytes: 16 * gibibyte,
        usedBytes: 8 * gibibyte,
        availableBytes: 8 * gibibyte
    )),
    pressure: MetricReading<MemoryPressureLevel> = .available(.normal),
    volumes: MetricReading<[VolumeMetrics]> = .available([]),
    network: MetricReading<[NetworkInterfaceMetrics]> = .available([]),
    uptimeSeconds: TimeInterval = 3 * 86_400 + 4 * 3_600
) -> SystemSnapshot {
    SystemSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        hostName: "test-mac",
        operatingSystemVersion: "Test OS 1.0",
        activeProcessorCount: 4,
        physicalMemoryBytes: 16 * gibibyte,
        uptimeSeconds: uptimeSeconds,
        loadAverage: LoadAverage(oneMinute: 1.5, fiveMinutes: 1.2, fifteenMinutes: 0.9),
        cpu: cpu,
        memory: memory,
        memoryPressure: pressure,
        volumes: volumes,
        network: network
    )
}

private func volume(
    _ name: String,
    mount: String,
    browsable: Bool = true,
    removable: Bool = false,
    capacity: MetricReading<DiskCapacity> = .available(DiskCapacity(totalBytes: 500_000_000_000, availableBytes: 200_000_000_000))
) -> VolumeMetrics {
    VolumeMetrics(name: name, mountPoint: mount, isRemovable: removable, isBrowsable: browsable, capacity: capacity)
}

private func nic(
    _ name: String,
    addresses: [String] = ["192.168.1.2"],
    up: Bool = true,
    loopback: Bool = false,
    totals: MetricReading<NetworkTotals> = .available(NetworkTotals(bytesReceived: 2_000_000_000, bytesSent: 500_000_000)),
    rates: MetricReading<NetworkRate> = .available(NetworkRate(receivedPerSecond: 1_500_000, sentPerSecond: 40_000))
) -> NetworkInterfaceMetrics {
    NetworkInterfaceMetrics(
        name: name,
        isUp: up,
        isLoopback: loopback,
        ipv4Addresses: addresses,
        totals: totals,
        rates: rates
    )
}

private func dashboard(
    _ snapshot: SystemSnapshot,
    selection: MonitoringSelection = .default
) -> DashboardPresentation {
    var history = MetricHistory(capacity: 120)
    history.record(snapshot)
    return DashboardPresentation(snapshot: snapshot, history: history, selection: selection)
}

@Suite("Usage values and levels")
struct UsageValueTests {
    @Test func textAndSpokenFormsMatch() {
        let value = UsageValue(fraction: 0.456)
        #expect(value.text == "46%")
        #expect(value.spokenText == "46 percent")
        #expect(value.level == .normal)
    }

    @Test func fractionsAreClampedToTheRange() {
        #expect(UsageValue(fraction: 1.7).fraction == 1)
        #expect(UsageValue(fraction: -0.2).fraction == 0)
        #expect(UsageValue(fraction: -0.2).text == "0%")
    }

    @Test func levelThresholds() {
        #expect(UsageLevel.forFraction(0.74) == .normal)
        #expect(UsageLevel.forFraction(0.75) == .elevated)
        #expect(UsageLevel.forFraction(0.89) == .elevated)
        #expect(UsageLevel.forFraction(0.9) == .critical)
    }

    @Test func levelsHaveTextTitles() {
        #expect(UsageLevel.normal.title == "Normal")
        #expect(UsageLevel.elevated.title == "Elevated")
        #expect(UsageLevel.critical.title == "Critical")
    }
}

@Suite("Spoken formatting")
struct SpokenFormattingTests {
    @Test func byteWordingForEachScale() {
        #expect(SpokenFormatting.bytes(UInt64(1)) == "1 byte")
        #expect(SpokenFormatting.bytes(UInt64(512)) == "512 bytes")
        #expect(SpokenFormatting.bytes(UInt64(1_500)) == "1.5 kilobytes")
        #expect(SpokenFormatting.bytes(UInt64(4_200_000)) == "4.2 megabytes")
        #expect(SpokenFormatting.bytes(UInt64(2_000_000_000)) == "2.0 gigabytes")
    }

    @Test func binaryWordingUsesPowersOfTwo() {
        #expect(SpokenFormatting.bytes(gibibyte * 8, binary: true) == "8.0 gigabytes")
    }

    @Test func rateWording() {
        #expect(SpokenFormatting.rate(1_500_000) == "1.5 megabytes per second")
        #expect(SpokenFormatting.rate(0) == "0 bytes per second")
    }

    @Test func uptimeUsesTheLargestTwoUnits() {
        #expect(SpokenFormatting.uptime(3 * 86_400 + 4 * 3_600) == "3 days, 4 hours")
        #expect(SpokenFormatting.uptime(86_400 + 3_600) == "1 day, 1 hour")
        #expect(SpokenFormatting.uptime(3_600 + 120) == "1 hour, 2 minutes")
        #expect(SpokenFormatting.uptime(45) == "0 minutes")
        #expect(SpokenFormatting.uptime(60) == "1 minute")
    }
}

@Suite("CPU presentation")
struct CPUPresentationTests {
    @Test func totalAndCoresAreDisplayedWithLabels() throws {
        let presentation = dashboard(snapshot()).cpu
        let total = try #require(presentation.total.availableValue)
        #expect(total.text == "12%")
        #expect(total.spokenText == "12 percent")

        let cores = try #require(presentation.cores.availableValue)
        #expect(cores.map(\.label) == ["Core 1", "Core 2", "Core 3", "Core 4"])
        #expect(cores.map(\.usage.text) == ["10%", "20%", "30%", "10%"])
    }

    @Test func unavailableCPUCarriesTheReason() {
        let presentation = dashboard(snapshot(cpu: .unavailable(.noElapsedTicks))).cpu
        #expect(presentation.total == .unavailable("No CPU time elapsed since the last sample"))
        #expect(presentation.cores == .unavailable("No CPU time elapsed since the last sample"))
    }

    @Test func unavailableCoresKeepTheTotal() throws {
        let presentation = dashboard(snapshot(cpu: .available(CPUUtilization(
            total: 0.5,
            perCore: .unavailable(.kernelCallFailed(call: "host_processor_info", code: 4))
        )))).cpu
        #expect(try #require(presentation.total.availableValue).text == "50%")
        #expect(presentation.cores == .unavailable("host_processor_info failed with code 4"))
    }

    @Test func historyChartUsesAFixedCeiling() {
        let presentation = dashboard(snapshot()).cpu
        #expect(presentation.history.ceiling == 1)
        #expect(presentation.history.spokenSummary == "CPU: latest 12 percent, peak 12 percent over 1 sample.")
    }
}

@Suite("Memory presentation")
struct MemoryPresentationTests {
    @Test func amountsUseBinaryUnits() throws {
        let presentation = dashboard(snapshot()).memory
        #expect(try #require(presentation.used.availableValue).visible == "8.0 GB")
        #expect(try #require(presentation.used.availableValue).spoken == "8.0 gigabytes")
        #expect(try #require(presentation.available.availableValue).visible == "8.0 GB")
        #expect(try #require(presentation.total.availableValue).visible == "16 GB")
        #expect(try #require(presentation.usage.availableValue).text == "50%")
    }

    @Test func pressureLevelsMapToBadges() throws {
        let warning = dashboard(snapshot(pressure: .available(.warning))).memory
        #expect(try #require(warning.pressure.availableValue).title == "Warning")
        #expect(try #require(warning.pressure.availableValue).level == .elevated)

        let critical = dashboard(snapshot(pressure: .available(.critical))).memory
        #expect(try #require(critical.pressure.availableValue).level == .critical)
    }

    @Test func zeroTotalIsReportedInsteadOfAPercentage() {
        let zero = snapshot(memory: .available(MemoryUsage(totalBytes: 0, usedBytes: 0, availableBytes: 0)))
        #expect(dashboard(zero).memory.usage == .unavailable("Total memory is unknown"))
    }

    @Test func unavailablePressureCarriesTheReason() {
        let presentation = dashboard(snapshot(pressure: .unavailable(.unrecognizedPressureLevel(3)))).memory
        #expect(presentation.pressure == .unavailable("Unrecognized memory pressure level 3"))
    }
}

@Suite("Storage presentation")
struct StoragePresentationTests {
    @Test func onlyBrowsableMonitoredVolumesAreShown() throws {
        let presentation = dashboard(snapshot(volumes: .available([
            volume("Macintosh HD", mount: "/"),
            volume("VM", mount: "/System/Volumes/VM", browsable: false),
            volume("Backup", mount: "/Volumes/Backup", capacity: .unavailable(.notMonitored)),
        ]))).storage
        let rows = try #require(presentation.volumes.availableValue)
        #expect(rows.map(\.name) == ["Macintosh HD"])
    }

    @Test func capacityReadsAsPercentAndFreeSpace() throws {
        let row = try #require(dashboard(snapshot(volumes: .available([volume("Macintosh HD", mount: "/")]))).storage.volumes.availableValue?.first)
        let capacity = try #require(row.capacity.availableValue)
        #expect(capacity.usage.text == "60%")
        #expect(capacity.free.visible == "200 GB free of 500 GB")
        #expect(capacity.free.spoken == "200 gigabytes free of 500 gigabytes")
    }

    @Test func removableVolumesAreBadged() throws {
        let row = try #require(dashboard(snapshot(volumes: .available([
            volume("Backup", mount: "/Volumes/Backup", removable: true),
        ]))).storage.volumes.availableValue?.first)
        #expect(row.badge == "Removable")
    }

    @Test func denialStaysOnTheVolume() throws {
        let row = try #require(dashboard(snapshot(volumes: .available([
            volume("Private", mount: "/Volumes/Private", capacity: .unavailable(.permissionDenied(resource: "volume attributes"))),
        ]))).storage.volumes.availableValue?.first)
        #expect(row.capacity == .unavailable("Permission denied for volume attributes"))
    }

    @Test func primaryUsageComesFromTheFirstShownVolume() throws {
        let presentation = dashboard(snapshot(volumes: .available([volume("Macintosh HD", mount: "/")]))).storage
        #expect(try #require(presentation.primaryUsage.availableValue).text == "60%")
    }

    @Test func noShownVolumesIsExplicit() {
        let presentation = dashboard(snapshot(volumes: .available([]))).storage
        #expect(presentation.primaryUsage == .unavailable("No disks monitored"))
    }
}

@Suite("Network presentation")
struct NetworkPresentationTests {
    @Test func rateAndTotalsReadWithUnits() throws {
        let presentation = dashboard(snapshot(network: .available([nic("en1")]))).network
        #expect(try #require(presentation.download.availableValue).visible == "1.5 MB/s")
        #expect(try #require(presentation.download.availableValue).spoken == "1.5 megabytes per second")
        #expect(try #require(presentation.upload.availableValue).visible == "40 KB/s")

        let row = try #require(presentation.interfaces.availableValue?.first)
        #expect(row.title == "en1")
        #expect(row.address == "192.168.1.2")
        #expect(try #require(row.totals.availableValue).visible == "Received 2.0 GB · Sent 500 MB")
    }

    @Test func idleVirtualInterfacesAreHiddenFromTheSummary() throws {
        let idle = nic("awdl0", addresses: [], totals: .available(NetworkTotals(bytesReceived: 0, bytesSent: 0)))
        let presentation = dashboard(snapshot(network: .available([nic("en1"), idle]))).network
        #expect(try #require(presentation.interfaces.availableValue).map(\.id) == ["en1"])
    }

    @Test func excludedLoopbackIsHidden() throws {
        let loopback = nic("lo0", addresses: ["127.0.0.1"], loopback: true, totals: .unavailable(.notMonitored), rates: .unavailable(.notMonitored))
        let presentation = dashboard(snapshot(network: .available([nic("en1"), loopback]))).network
        #expect(try #require(presentation.interfaces.availableValue).map(\.id) == ["en1"])
    }

    @Test func downInterfaceIsLabelled() throws {
        let down = nic("bridge0", up: false)
        let row = try #require(dashboard(snapshot(network: .available([down]))).network.interfaces.availableValue?.first)
        #expect(row.title == "bridge0, down")
    }

    @Test func aggregateSumsMonitoredInterfaces() throws {
        let presentation = dashboard(snapshot(network: .available([
            nic("en1", rates: .available(NetworkRate(receivedPerSecond: 1_000_000, sentPerSecond: 10_000))),
            nic("utun3", rates: .available(NetworkRate(receivedPerSecond: 500_000, sentPerSecond: 30_000))),
        ]))).network
        #expect(try #require(presentation.download.availableValue).visible == "1.5 MB/s")
        #expect(try #require(presentation.upload.availableValue).visible == "40 KB/s")
    }

    @Test func aggregateIsUnavailableWhenAnyMonitoredInterfaceIs() {
        let presentation = dashboard(snapshot(network: .available([
            nic("en1"),
            nic("utun3", rates: .unavailable(.counterReset)),
        ]))).network
        #expect(presentation.download == .unavailable("Rate unavailable"))
    }

    @Test func chartCeilingLeavesHeadroomAndHasAFloor() {
        let presentation = dashboard(snapshot(network: .available([nic("en1")]))).network
        #expect(presentation.chart.ceiling == 1_500_000 * 1.15)
        #expect(presentation.chart.spokenSummary.contains("Download: latest 1.5 megabytes per second"))
    }

    @Test func emptyTrafficKeepsTheChartFloor() {
        let quiet = nic("en1", rates: .available(NetworkRate(receivedPerSecond: 0, sentPerSecond: 0)))
        let presentation = dashboard(snapshot(network: .available([quiet]))).network
        #expect(presentation.chart.ceiling == 128_000)
    }
}

@Suite("Menu bar and summary presentation")
struct MenuBarPresentationTests {
    @Test func compactTextAndSpokenLabel() {
        let presentation = dashboard(snapshot(network: .available([nic("en1")]))).menuBar
        #expect(presentation.cpuText == "12%")
        #expect(presentation.memoryText == "50%")
        #expect(presentation.networkText == "↓1.5M ↑40K")
        #expect(presentation.accessibilityLabel == "MacFleet. CPU 12 percent. Memory 50 percent. Download 1.5 megabytes per second, upload 40 kilobytes per second.")
    }

    @Test func unavailableValuesShowDashesAndSayWhy() {
        let presentation = dashboard(snapshot(
            cpu: .unavailable(.notSampled),
            network: .unavailable(.kernelCallFailed(call: "getifaddrs", code: 1))
        )).menuBar
        #expect(presentation.cpuText == "–")
        #expect(presentation.networkText == "↓– ↑–")
        #expect(presentation.accessibilityLabel.contains("CPU unavailable."))
        #expect(presentation.accessibilityLabel.contains("Network unavailable."))
    }

    @Test func summaryFormatsUptimeAndLoad() throws {
        let summary = dashboard(snapshot()).summary
        #expect(summary.uptime.visible == "3 days, 4 hours")
        #expect(summary.load.visible == "1.50 · 1.20 · 0.90")
        #expect(summary.cpuCountText == "4 CPUs")
        #expect(summary.load.spoken.hasPrefix("Load averages 1.50, 1.20, and 0.90"))
    }
}

@Suite("Sources presentation")
struct SourcesPresentationTests {
    @Test func togglesFollowTheSelection() throws {
        var selection = MonitoringSelection.default
        selection.setInterface(named: "en1", monitored: false)
        selection.setVolume(at: "/", monitored: false)
        let presentation = dashboard(
            snapshot(volumes: .available([volume("Macintosh HD", mount: "/")]), network: .available([nic("en1"), nic("lo0", loopback: true)])),
            selection: selection
        ).sources

        let interfaces = try #require(presentation.interfaces.availableValue)
        #expect(interfaces.map(\.monitored) == [false, false])
        let volumes = try #require(presentation.volumes.availableValue)
        #expect(volumes.first?.monitored == false)
    }

    @Test func sourcesListIncludesHiddenItems() throws {
        let presentation = dashboard(snapshot(volumes: .available([
            volume("VM", mount: "/System/Volumes/VM", browsable: false),
        ]))).sources
        #expect(try #require(presentation.volumes.availableValue).map(\.id) == ["/System/Volumes/VM"])
    }
}
