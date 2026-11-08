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
        try Self.next(&cpuTotal)
    }

    public mutating func perCoreCPUTicks() throws(MetricIssue) -> [CPUTicks] {
        try Self.next(&perCoreCPU)
    }

    public mutating func virtualMemoryCounters() throws(MetricIssue) -> VMCounters {
        try Self.next(&vmCounters)
    }

    public mutating func memoryPressureLevelValue() throws(MetricIssue) -> Int32 {
        try Self.next(&pressureLevel)
    }

    private static func next<T>(_ script: inout [Result<T, MetricIssue>]) throws(MetricIssue) -> T {
        guard let entry = script.first else {
            throw .kernelCallFailed(call: "MockHostCounters: no scripted reading", code: 0)
        }
        if script.count > 1 { script.removeFirst() }
        switch entry {
        case let .success(value):
            return value
        case let .failure(issue):
            throw issue
        }
    }
}
