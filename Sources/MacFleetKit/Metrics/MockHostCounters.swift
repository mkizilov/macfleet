/// Scripted counters for tests and previews. Each call consumes the next scripted result;
/// once a script has one entry left, that entry repeats.
public struct MockHostCounters: HostCounterSource {
    private var cpuTotal: [Result<CPUTicks, MetricIssue>]
    private var perCoreCPU: [Result<[CPUTicks], MetricIssue>]
    private var vmCounters: [Result<VMCounters, MetricIssue>]
    private var pressureLevel: [Result<Int32, MetricIssue>]

    public init(
        cpuTotal: [Result<CPUTicks, MetricIssue>] = [],
        perCoreCPU: [Result<[CPUTicks], MetricIssue>] = [],
        virtualMemory: [Result<VMCounters, MetricIssue>] = [],
        pressureLevel: [Result<Int32, MetricIssue>] = []
    ) {
        self.cpuTotal = cpuTotal
        self.perCoreCPU = perCoreCPU
        self.vmCounters = virtualMemory
        self.pressureLevel = pressureLevel
    }

    public mutating func cpuTotalTicks() throws(MetricIssue) -> CPUTicks {
        try ScriptedReadings.next(&cpuTotal)
    }

    public mutating func perCoreCPUTicks() throws(MetricIssue) -> [CPUTicks] {
        try ScriptedReadings.next(&perCoreCPU)
    }

    public mutating func virtualMemoryCounters() throws(MetricIssue) -> VMCounters {
        try ScriptedReadings.next(&vmCounters)
    }

    public mutating func memoryPressureLevelValue() throws(MetricIssue) -> Int32 {
        try ScriptedReadings.next(&pressureLevel)
    }
}
