import Foundation

/// CPU utilization from cumulative host counters. The rate baseline is actor state.
public actor CPUMetricProvider: MetricProvider {
    private var counters: any HostCounterSource
    private let minimumWindow: TimeInterval
    private var tracker: CPUUtilizationTracker

    public init(counters: any HostCounterSource = MachHostCounters(), minimumWindow: TimeInterval = 1) {
        self.counters = counters
        self.minimumWindow = minimumWindow
        tracker = CPUUtilizationTracker(minimumWindow: minimumWindow)
    }

    public func sample(_ context: SampleContext) -> MetricReading<CPUUtilization> {
        let total = metricReading { () throws(MetricIssue) -> CPUTicks in try counters.cpuTotalTicks() }
        let perCore = metricReading { () throws(MetricIssue) -> [CPUTicks] in try counters.perCoreCPUTicks() }
        return tracker.record(at: context.monotonicSeconds, total: total, perCore: perCore)
    }

    public func resetBaselines() {
        tracker = CPUUtilizationTracker(minimumWindow: minimumWindow)
    }
}

/// Physical memory in use and available, from virtual memory counters.
public actor MemoryUsageMetricProvider: MetricProvider {
    private var counters: any HostCounterSource
    private let totalBytes: UInt64

    public init(counters: any HostCounterSource = MachHostCounters(), totalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.counters = counters
        self.totalBytes = totalBytes
    }

    public func sample(_ context: SampleContext) -> MetricReading<MemoryUsage> {
        metricReading { () throws(MetricIssue) -> MemoryUsage in
            let vm = try counters.virtualMemoryCounters()
            return try MemoryUsageCalculator.usage(from: vm, totalBytes: totalBytes)
        }
    }
}

/// Memory pressure level from the kernel.
public actor MemoryPressureMetricProvider: MetricProvider {
    private var counters: any HostCounterSource

    public init(counters: any HostCounterSource = MachHostCounters()) {
        self.counters = counters
    }

    public func sample(_ context: SampleContext) -> MetricReading<MemoryPressureLevel> {
        metricReading { () throws(MetricIssue) -> MemoryPressureLevel in
            let raw = try counters.memoryPressureLevelValue()
            guard let level = MemoryPressureLevel(rawValue: raw) else {
                throw .unrecognizedPressureLevel(raw)
            }
            return level
        }
    }
}

/// Mounted volumes, with exclusions from the context's selection applied.
public actor StorageMetricProvider: MetricProvider {
    private var volumeSource: any VolumeSource

    public init(volumes: any VolumeSource = FileManagerVolumeSource()) {
        volumeSource = volumes
    }

    /// Every mounted volume is listed. Excluded volumes keep their identity but report `.notMonitored`.
    public func sample(_ context: SampleContext) -> MetricReading<[VolumeMetrics]> {
        let discovered = metricReading { () throws(MetricIssue) -> [RawVolume] in try volumeSource.volumes() }
        switch discovered {
        case let .unavailable(issue):
            return .unavailable(issue)
        case let .available(volumes):
            return .available(volumes.map { volume in
                let capacity = context.selection.monitorsVolume(at: volume.mountPoint)
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
}

/// Per-interface byte totals and rates. The rate baseline is actor state, and rates use the context clock.
public actor NetworkMetricProvider: MetricProvider {
    private var interfaceSource: any InterfaceSource
    private let minimumWindow: TimeInterval
    private var tracker: NetworkRateTracker

    public init(interfaces: any InterfaceSource = SystemInterfaceSource(), minimumWindow: TimeInterval = 1) {
        interfaceSource = interfaces
        self.minimumWindow = minimumWindow
        tracker = NetworkRateTracker(minimumWindow: minimumWindow)
    }

    public func sample(_ context: SampleContext) -> MetricReading<[NetworkInterfaceMetrics]> {
        let discovered = metricReading { () throws(MetricIssue) -> [RawInterface] in try interfaceSource.interfaces() }
        switch discovered {
        case let .unavailable(issue):
            return .unavailable(issue)
        case let .available(interfaces):
            let totals = Dictionary(uniqueKeysWithValues: interfaces.map { interface in
                let monitored = context.selection.monitorsInterface(named: interface.name)
                return (interface.name, monitored ? interface.totals : .unavailable(.notMonitored))
            })
            let rates = tracker.record(at: context.monotonicSeconds, totals: totals)
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

    public func resetBaselines() {
        tracker = NetworkRateTracker(minimumWindow: minimumWindow)
    }
}

/// One, five, and fifteen minute load averages.
public struct LoadAverageMetricProvider: MetricProvider {
    public init() {}

    public func sample(_ context: SampleContext) -> MetricReading<LoadAverage> {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else {
            return .unavailable(.notProvided(resource: "load averages"))
        }
        return .available(LoadAverage(oneMinute: loads[0], fiveMinutes: loads[1], fifteenMinutes: loads[2]))
    }
}
