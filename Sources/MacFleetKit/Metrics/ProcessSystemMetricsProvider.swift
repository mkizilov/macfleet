import Foundation

public actor ProcessSystemMetricsProvider: SystemMetricsProviding {
    private var counters: any HostCounterSource
    private let clock: @Sendable () -> TimeInterval
    private var cpuTracker: CPUUtilizationTracker

    /// `minimumCPUWindow` is the shortest interval, in seconds, that yields a CPU percentage.
    public init(
        counters: any HostCounterSource = MachHostCounters(),
        minimumCPUWindow: TimeInterval = 1,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.counters = counters
        self.clock = clock
        cpuTracker = CPUUtilizationTracker(minimumWindow: minimumCPUWindow)
    }

    /// Reads are synchronous, so a snapshot never suspends mid-update and overlapping calls cannot
    /// record CPU counters out of order.
    public func snapshot() async throws -> SystemSnapshot {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else {
            throw MetricsError.loadAverageUnavailable
        }
        let info = ProcessInfo.processInfo
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
            cpu: sampleCPU(),
            memory: sampleMemory(totalBytes: info.physicalMemory),
            memoryPressure: samplePressure()
        )
    }

    private func sampleCPU() -> MetricReading<CPUUtilization> {
        let total = reading { () throws(MetricIssue) -> CPUTicks in try counters.cpuTotalTicks() }
        let perCore = reading { () throws(MetricIssue) -> [CPUTicks] in try counters.perCoreCPUTicks() }
        return cpuTracker.record(at: clock(), total: total, perCore: perCore)
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

    private func reading<T: Equatable & Sendable>(_ read: () throws(MetricIssue) -> T) -> MetricReading<T> {
        do throws(MetricIssue) {
            return .available(try read())
        } catch {
            return .unavailable(error)
        }
    }
}
