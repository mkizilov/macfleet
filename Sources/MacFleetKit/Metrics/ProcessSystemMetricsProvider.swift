import Foundation

public actor ProcessSystemMetricsProvider: SystemMetricsProviding {
    private var counters: any HostCounterSource
    private var volumeSource: any VolumeSource
    private var interfaceSource: any InterfaceSource
    private let clock: @Sendable () -> TimeInterval
    private var cpuTracker: CPUUtilizationTracker
    private var networkTracker: NetworkRateTracker

    /// Window arguments are the shortest intervals, in seconds, that yield a rate or percentage.
    public init(
        counters: any HostCounterSource = MachHostCounters(),
        volumes: any VolumeSource = FileManagerVolumeSource(),
        interfaces: any InterfaceSource = SystemInterfaceSource(),
        minimumCPUWindow: TimeInterval = 1,
        minimumNetworkWindow: TimeInterval = 1,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.counters = counters
        volumeSource = volumes
        interfaceSource = interfaces
        self.clock = clock
        cpuTracker = CPUUtilizationTracker(minimumWindow: minimumCPUWindow)
        networkTracker = NetworkRateTracker(minimumWindow: minimumNetworkWindow)
    }

    /// Reads are synchronous, so a snapshot never suspends mid-update and overlapping calls cannot
    /// record counters out of order.
    public func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else {
            throw MetricsError.loadAverageUnavailable
        }
        let info = ProcessInfo.processInfo
        let now = clock()
        return SystemSnapshot(
            capturedAt: Date(),
            hostName: info.hostName,
            operatingSystemVersion: info.operatingSystemVersionString,
            activeProcessorCount: info.activeProcessorCount,
            physicalMemoryBytes: info.physicalMemory,
            uptimeSeconds: info.systemUptime,
            loadAverage: LoadAverage(
                oneMinute: loads[0],
                fiveMinutes: loads[1],
                fifteenMinutes: loads[2]
            ),
            cpu: sampleCPU(at: now),
            memory: sampleMemory(totalBytes: info.physicalMemory),
            memoryPressure: samplePressure(),
            volumes: sampleVolumes(selection: selection),
            network: sampleNetwork(selection: selection, at: now)
        )
    }

    private func sampleCPU(at now: TimeInterval) -> MetricReading<CPUUtilization> {
        let total = reading { () throws(MetricIssue) -> CPUTicks in try counters.cpuTotalTicks() }
        let perCore = reading { () throws(MetricIssue) -> [CPUTicks] in try counters.perCoreCPUTicks() }
        return cpuTracker.record(at: now, total: total, perCore: perCore)
    }

    private func sampleMemory(totalBytes: UInt64) -> MetricReading<MemoryUsage> {
        reading { () throws(MetricIssue) -> MemoryUsage in
            let vm = try counters.virtualMemoryCounters()
            return try MemoryUsageCalculator.usage(from: vm, totalBytes: totalBytes)
        }
    }

    private func samplePressure() -> MetricReading<MemoryPressureLevel> {
        reading { () throws(MetricIssue) -> MemoryPressureLevel in
            let raw = try counters.memoryPressureLevelValue()
            guard let level = MemoryPressureLevel(rawValue: raw) else {
                throw .unrecognizedPressureLevel(raw)
            }
            return level
        }
    }

    /// Every mounted volume is listed. Excluded volumes keep their identity but report `.notMonitored`.
    private func sampleVolumes(selection: MonitoringSelection) -> MetricReading<[VolumeMetrics]> {
        let discovered = reading { () throws(MetricIssue) -> [RawVolume] in try volumeSource.volumes() }
        switch discovered {
        case let .unavailable(issue):
            return .unavailable(issue)
        case let .available(volumes):
            return .available(volumes.map { volume in
                let capacity = selection.monitorsVolume(at: volume.mountPoint)
                    ? DiskUsageCalculator.reading(total: volume.totalBytes, available: volume.availableBytes)
                    : .unavailable(.notMonitored)
                return VolumeMetrics(
                    name: volume.name,
                    mountPoint: volume.mountPoint,
                    isRemovable: volume.isRemovable,
                    isBrowsable: volume.isBrowsable,
                    capacity: capacity
                )
            })
        }
    }

    private func sampleNetwork(selection: MonitoringSelection, at now: TimeInterval) -> MetricReading<[NetworkInterfaceMetrics]> {
        let discovered = reading { () throws(MetricIssue) -> [RawInterface] in try interfaceSource.interfaces() }
        switch discovered {
        case let .unavailable(issue):
            return .unavailable(issue)
        case let .available(interfaces):
            let totals = Dictionary(uniqueKeysWithValues: interfaces.map { interface in
                let monitored = selection.monitorsInterface(named: interface.name)
                return (interface.name, monitored ? interface.totals : .unavailable(.notMonitored))
            })
            let rates = networkTracker.record(at: now, totals: totals)
            return .available(interfaces.map { interface in
                NetworkInterfaceMetrics(
                    name: interface.name,
                    isUp: interface.isUp,
                    isLoopback: interface.isLoopback,
                    ipv4Addresses: interface.ipv4Addresses,
                    totals: totals[interface.name] ?? .unavailable(.notSampled),
                    rates: rates[interface.name] ?? .unavailable(.notSampled)
                )
            })
        }
    }

    private func reading<T: Equatable & Sendable>(_ read: () throws(MetricIssue) -> T) -> MetricReading<T> {
        do throws(MetricIssue) {
            return .available(try read())
        } catch {
            return .unavailable(error)
        }
    }
}
