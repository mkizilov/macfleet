import Foundation

/// Assembles a snapshot from independent section providers.
///
/// Sections run concurrently and share one context, so their timestamps and selection agree. Each section has
/// a deadline; one that misses it reports `.timedOut` while the others still arrive. Only a missing load
/// average fails the whole snapshot, which is the behavior callers have always relied on.
public struct ProcessSystemMetricsProvider: SystemMetricsProviding {
    struct Sections: Sendable {
        let cpu: any MetricProvider<CPUUtilization>
        let memory: any MetricProvider<MemoryUsage>
        let pressure: any MetricProvider<MemoryPressureLevel>
        let storage: any MetricProvider<[VolumeMetrics]>
        let network: any MetricProvider<[NetworkInterfaceMetrics]>
        let load: any MetricProvider<LoadAverage>
        let hardware: any MetricProvider<HardwareSample>
    }

    private let sections: Sections
    private let clock: @Sendable () -> TimeInterval
    private let sampleTimeout: Duration

    /// `minimumCPUWindow` and `minimumNetworkWindow` are the shortest intervals, in seconds, that yield a rate.
    /// `clock` supplies awake monotonic seconds; the default does not advance during sleep.
    public init(
        counters: any HostCounterSource = MachHostCounters(),
        volumes: any VolumeSource = FileManagerVolumeSource(),
        interfaces: any InterfaceSource = SystemInterfaceSource(),
        hardware: HardwareMetricProvider = .live,
        minimumCPUWindow: TimeInterval = 1,
        minimumNetworkWindow: TimeInterval = 1,
        clock: @escaping @Sendable () -> TimeInterval = { MonotonicTime.awakeSeconds() },
        sampleTimeout: Duration = .seconds(2)
    ) {
        sections = Sections(
            cpu: CPUMetricProvider(counters: counters, minimumWindow: minimumCPUWindow),
            memory: MemoryUsageMetricProvider(counters: counters),
            pressure: MemoryPressureMetricProvider(counters: counters),
            storage: StorageMetricProvider(volumes: volumes),
            network: NetworkMetricProvider(interfaces: interfaces, minimumWindow: minimumNetworkWindow),
            load: LoadAverageMetricProvider(),
            hardware: hardware
        )
        self.clock = clock
        self.sampleTimeout = sampleTimeout
    }

    init(sections: Sections, clock: @escaping @Sendable () -> TimeInterval, sampleTimeout: Duration) {
        self.sections = sections
        self.clock = clock
        self.sampleTimeout = sampleTimeout
    }

    public func snapshot(selection: MonitoringSelection) async throws -> SystemSnapshot {
        let context = SampleContext(wallClock: Date(), monotonicSeconds: clock(), selection: selection)
        async let cpu = sample(sections.cpu, context)
        async let memory = sample(sections.memory, context)
        async let pressure = sample(sections.pressure, context)
        async let volumes = sample(sections.storage, context)
        async let network = sample(sections.network, context)
        async let hardware = sample(sections.hardware, context)
        let load = await sample(sections.load, context)

        guard let average = load.availableValue else {
            throw MetricsError.loadAverageUnavailable
        }
        let info = ProcessInfo.processInfo
        return SystemSnapshot(
            capturedAt: context.wallClock,
            hostName: info.hostName,
            operatingSystemVersion: info.operatingSystemVersionString,
            activeProcessorCount: info.activeProcessorCount,
            physicalMemoryBytes: info.physicalMemory,
            uptimeSeconds: info.systemUptime,
            loadAverage: average,
            cpu: await cpu,
            memory: await memory,
            memoryPressure: await pressure,
            volumes: await volumes,
            network: await network,
            hardware: await hardware
        )
    }

    public func resetBaselines() async {
        await sections.cpu.resetBaselines()
        await sections.memory.resetBaselines()
        await sections.pressure.resetBaselines()
        await sections.storage.resetBaselines()
        await sections.network.resetBaselines()
        await sections.load.resetBaselines()
    }

    private func sample<Output: Equatable & Sendable>(
        _ provider: any MetricProvider<Output>,
        _ context: SampleContext
    ) async -> MetricReading<Output> {
        let deadline = sampleTimeout
        return await withTaskGroup(of: MetricReading<Output>?.self) { group in
            group.addTask { () -> MetricReading<Output>? in
                await provider.sample(context)
            }
            group.addTask { () -> MetricReading<Output>? in
                try? await Task.sleep(for: deadline, clock: .suspending)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .unavailable(.timedOut)
        }
    }
}
