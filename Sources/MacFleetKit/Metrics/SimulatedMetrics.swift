import Foundation

/// Deterministic, realistic metrics for previews, demos, and tests. Nothing here reads the system.
public struct SimulatedMetricsTimeline: Sendable {
    /// Matches the menu bar app's sampling interval, so simulated rates read like live ones.
    public static let stepSeconds: Double = 2

    private var random: SplitMix64
    private var step = 0
    private let coreCount: Int
    private var coreLoad: [Double]
    private var cpuBurstStepsLeft = 0
    private var cpuBurstLevel = 0.0
    private var memoryFraction = 0.56
    private var diskFraction = 0.61
    private var networkBurstStepsLeft = 0
    private var networkBurstLevel = 0.0
    private var downloadRate = 60_000.0
    private var uploadRate = 14_000.0
    private var loadAverages = (one: 1.2, five: 1.1, fifteen: 1.0)
    private var wifiReceived: UInt64 = 8_400_000_000
    private var wifiSent: UInt64 = 1_900_000_000
    private var vpnReceived: UInt64 = 900_000_000
    private var vpnSent: UInt64 = 700_000_000
    private var loopbackBytes: UInt64 = 2_600_000_000

    private let memoryTotal: UInt64 = 17_179_869_184
    private let mainVolumeTotal: UInt64 = 494_384_795_648
    private let backupVolumeTotal: UInt64 = 2_000_398_934_016
    private let backupUsedFraction = 0.42
    private let uptimeAtStart: TimeInterval = 3 * 86_400 + 4 * 3_600

    public init(seed: UInt64 = 42, coreCount: Int = 8) {
        self.coreCount = max(1, coreCount)
        random = SplitMix64(seed: seed)
        coreLoad = Array(repeating: 0.15, count: self.coreCount)
    }

    public mutating func nextSnapshot(selection: MonitoringSelection, capturedAt: Date) -> SystemSnapshot {
        step += 1
        let total = advanceCPU()
        let cpu: MetricReading<CPUUtilization> = step % 97 == 0
            ? .unavailable(.noElapsedTicks)
            : .available(CPUUtilization(total: total, perCore: .available(coreLoad)))

        loadAverages.one = 0.9 * loadAverages.one + 0.1 * total * Double(coreCount)
        loadAverages.five = 0.98 * loadAverages.five + 0.02 * total * Double(coreCount)
        loadAverages.fifteen = 0.995 * loadAverages.fifteen + 0.005 * total * Double(coreCount)

        let memory = advanceMemory()
        let pressure: MemoryPressureLevel = memoryFraction >= 0.93
            ? .critical
            : (memoryFraction >= 0.88 ? .warning : .normal)

        advanceNetwork()
        advanceDisk()

        return SystemSnapshot(
            capturedAt: capturedAt,
            hostName: "macfleet-preview.local",
            operatingSystemVersion: "Version 27.2 (Build 26B123)",
            activeProcessorCount: coreCount,
            physicalMemoryBytes: memoryTotal,
            uptimeSeconds: uptimeAtStart + Double(step) * Self.stepSeconds,
            loadAverage: LoadAverage(
                oneMinute: loadAverages.one,
                fiveMinutes: loadAverages.five,
                fifteenMinutes: loadAverages.fifteen
            ),
            cpu: cpu,
            memory: .available(memory),
            memoryPressure: .available(pressure),
            volumes: .available(volumes(selection: selection)),
            network: .available(interfaces(selection: selection))
        )
    }

    private mutating func advanceCPU() -> Double {
        if cpuBurstStepsLeft == 0, random.unit() < 0.06 {
            cpuBurstStepsLeft = 4 + Int(random.unit() * 6)
            cpuBurstLevel = 0.3 + random.unit() * 0.45
        }
        let burst = cpuBurstStepsLeft > 0 ? cpuBurstLevel : 0
        if cpuBurstStepsLeft > 0 { cpuBurstStepsLeft -= 1 }
        let baseline = 0.12 + 0.05 * sin(Double(step) / 23)
        for index in coreLoad.indices {
            let target = clamp(baseline + burst + (random.unit() - 0.5) * 0.12, 0, 1)
            coreLoad[index] = 0.6 * coreLoad[index] + 0.4 * target
        }
        return coreLoad.reduce(0, +) / Double(coreLoad.count)
    }

    private mutating func advanceMemory() -> MemoryUsage {
        memoryFraction = clamp(memoryFraction + (random.unit() - 0.5) * 0.02, 0.35, 0.95)
        let used = UInt64(memoryFraction * Double(memoryTotal))
        return MemoryUsage(totalBytes: memoryTotal, usedBytes: used, availableBytes: memoryTotal - used)
    }

    private mutating func advanceDisk() {
        diskFraction = clamp(diskFraction + (random.unit() - 0.45) * 0.0008, 0.3, 0.9)
    }

    private mutating func advanceNetwork() {
        if networkBurstStepsLeft == 0, random.unit() < 0.04 {
            networkBurstStepsLeft = 3 + Int(random.unit() * 5)
            networkBurstLevel = 2_000_000 + random.unit() * 6_000_000
        }
        let burst = networkBurstStepsLeft > 0 ? networkBurstLevel : 0
        if networkBurstStepsLeft > 0 { networkBurstStepsLeft -= 1 }
        let downTarget = 40_000 + random.unit() * 50_000 + burst
        let upTarget = 8_000 + random.unit() * 12_000 + burst * 0.15
        downloadRate = 0.7 * downloadRate + 0.3 * downTarget
        uploadRate = 0.7 * uploadRate + 0.3 * upTarget
        wifiReceived &+= UInt64(downloadRate * Self.stepSeconds)
        wifiSent &+= UInt64(uploadRate * Self.stepSeconds)
        vpnReceived &+= UInt64(downloadRate * 0.3 * Self.stepSeconds)
        vpnSent &+= UInt64(uploadRate * 0.3 * Self.stepSeconds)
        loopbackBytes &+= UInt64(5_000 * Self.stepSeconds)
    }

    private func volumes(selection: MonitoringSelection) -> [VolumeMetrics] {
        let mainUsed = UInt64(diskFraction * Double(mainVolumeTotal))
        let backupUsed = UInt64(backupUsedFraction * Double(backupVolumeTotal))
        return [
            VolumeMetrics(
                name: "Macintosh HD",
                mountPoint: "/",
                isRemovable: false,
                isBrowsable: true,
                capacity: capacity(
                    monitored: selection.monitorsVolume(at: "/"),
                    total: mainVolumeTotal,
                    available: mainVolumeTotal - mainUsed
                )
            ),
            VolumeMetrics(
                name: "Backup",
                mountPoint: "/Volumes/Backup",
                isRemovable: true,
                isBrowsable: true,
                capacity: capacity(
                    monitored: selection.monitorsVolume(at: "/Volumes/Backup"),
                    total: backupVolumeTotal,
                    available: backupVolumeTotal - backupUsed
                )
            ),
        ]
    }

    private func capacity(monitored: Bool, total: UInt64, available: UInt64) -> MetricReading<DiskCapacity> {
        monitored
            ? .available(DiskCapacity(totalBytes: total, availableBytes: available))
            : .unavailable(.notMonitored)
    }

    private func interfaces(selection: MonitoringSelection) -> [NetworkInterfaceMetrics] {
        let down = downloadRate
        let up = uploadRate
        return [
            network(
                "en0", selection, addresses: ["192.168.1.42"],
                totals: NetworkTotals(bytesReceived: wifiReceived, bytesSent: wifiSent),
                rate: NetworkRate(receivedPerSecond: down, sentPerSecond: up)
            ),
            network(
                "utun3", selection, addresses: ["10.8.0.6"],
                totals: NetworkTotals(bytesReceived: vpnReceived, bytesSent: vpnSent),
                rate: NetworkRate(receivedPerSecond: down * 0.3, sentPerSecond: up * 0.3)
            ),
            network(
                "awdl0", selection, addresses: [],
                totals: NetworkTotals(bytesReceived: 0, bytesSent: 0),
                rate: NetworkRate(receivedPerSecond: 0, sentPerSecond: 0)
            ),
            network(
                "bridge0", selection, addresses: [], isUp: false,
                totals: NetworkTotals(bytesReceived: 0, bytesSent: 0),
                rate: NetworkRate(receivedPerSecond: 0, sentPerSecond: 0)
            ),
            network(
                "lo0", selection, addresses: ["127.0.0.1"], isLoopback: true,
                totals: NetworkTotals(bytesReceived: loopbackBytes, bytesSent: loopbackBytes),
                rate: NetworkRate(receivedPerSecond: 5_000, sentPerSecond: 5_000)
            ),
        ]
    }

    private func network(
        _ name: String,
        _ selection: MonitoringSelection,
        addresses: [String],
        isUp: Bool = true,
        isLoopback: Bool = false,
        totals: NetworkTotals,
        rate: NetworkRate
    ) -> NetworkInterfaceMetrics {
        let monitored = selection.monitorsInterface(named: name)
        return NetworkInterfaceMetrics(
            name: name,
            isUp: isUp,
            isLoopback: isLoopback,
            ipv4Addresses: addresses,
            totals: monitored ? .available(totals) : .unavailable(.notMonitored),
            rates: monitored ? .available(rate) : .unavailable(.notMonitored)
        )
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

/// Serves `SimulatedMetricsTimeline` through the normal provider interface.
public actor SimulatedSystemMetricsProvider: SystemMetricsProviding {
    private var timeline: SimulatedMetricsTimeline
    private let now: @Sendable () -> Date

    public init(seed: UInt64 = 42, coreCount: Int = 8, now: @escaping @Sendable () -> Date = { Date() }) {
        timeline = SimulatedMetricsTimeline(seed: seed, coreCount: coreCount)
        self.now = now
    }

    public func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        timeline.nextSnapshot(selection: selection, capturedAt: now())
    }
}

/// SplitMix64: small, fast, and reproducible across runs and platforms.
private struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / 9_007_199_254_740_992
    }
}
