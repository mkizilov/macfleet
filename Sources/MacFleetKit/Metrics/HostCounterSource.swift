import Darwin

/// Source of raw kernel counters. Mutating so scripted test sources can advance; the Mach source holds no state.
public protocol HostCounterSource: Sendable {
    mutating func cpuTotalTicks() throws(MetricIssue) -> CPUTicks
    mutating func perCoreCPUTicks() throws(MetricIssue) -> [CPUTicks]
    mutating func virtualMemoryCounters() throws(MetricIssue) -> VMCounters
    mutating func memoryPressureLevelValue() throws(MetricIssue) -> Int32
}

public struct MachHostCounters: HostCounterSource {
    public init() {}

    public func cpuTotalTicks() throws(MetricIssue) -> CPUTicks {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw .kernelCallFailed(call: "host_statistics(HOST_CPU_LOAD_INFO)", code: status)
        }
        return CPUTicks(
            user: load.cpu_ticks.0,
            system: load.cpu_ticks.1,
            idle: load.cpu_ticks.2,
            nice: load.cpu_ticks.3
        )
    }

    public func perCoreCPUTicks() throws(MetricIssue) -> [CPUTicks] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
        guard status == KERN_SUCCESS, let info else {
            throw .kernelCallFailed(call: "host_processor_info(PROCESSOR_CPU_LOAD_INFO)", code: status)
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(coreCount)).map { core in
            let base = core * stride
            return CPUTicks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            )
        }
    }

    public func virtualMemoryCounters() throws(MetricIssue) -> VMCounters {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw .kernelCallFailed(call: "host_statistics64(HOST_VM_INFO64)", code: status)
        }
        return VMCounters(
            pageSize: UInt64(sysconf(_SC_PAGESIZE)),
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count)
        )
    }

    /// `kern.memorystatus_vm_pressure_level` is the value Apple's `memory_pressure` tool reads.
    /// It is a stable sysctl but is not described in the public documentation.
    public func memoryPressureLevelValue() throws(MetricIssue) -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            throw .kernelCallFailed(call: "sysctlbyname(kern.memorystatus_vm_pressure_level)", code: errno)
        }
        return level
    }
}
