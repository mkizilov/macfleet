import Darwin
import Foundation

/// Every process the system lists, each with what macOS allowed this app to read about it.
public protocol ProcessInventorySource: Sendable {
    /// Throws only when the listing itself fails. A single process that cannot be read is an outcome, not an error.
    func listing() throws(MetricIssue) -> [ProcessListing]
}

/// Process listing through libproc, the public process interface. Other users' processes are listed, but macOS
/// refuses their details, and those are reported as denied. This source never reads kernel process tables or
/// elevates privileges to fill in what libproc refuses.
public struct DarwinProcessInventory: ProcessInventorySource {
    private let timebase: mach_timebase_info_data_t

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    public func listing() throws(MetricIssue) -> [ProcessListing] {
        try Self.processIDs().map(listing(for:))
    }

    /// CPU time from `proc_pid_rusage` is in mach absolute time units, which are not nanoseconds on Apple silicon
    /// (the timebase there is 125/3). Measured here: a 500 ms busy loop reads as 499.5 ms once converted.
    static func nanoseconds(absoluteTime ticks: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64 {
        guard denominator > 0 else { return ticks }
        let converted = Double(ticks) * Double(numerator) / Double(denominator)
        return UInt64(converted.rounded())
    }

    private func listing(for pid: pid_t) -> ProcessListing {
        let name = Self.executableName(pid)
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        if result != 0 {
            let code = errno
            return ProcessListing(pid: pid, name: name, outcome: code == ESRCH ? .gone : .denied)
        }

        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdResult = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size)
        let bsdCode = errno
        if bsdResult != size, bsdCode == ESRCH {
            return ProcessListing(pid: pid, name: name, outcome: .gone)
        }
        let start = bsdResult == size
            ? UInt64(bsd.pbi_start_tvsec) * 1_000_000 + UInt64(bsd.pbi_start_tvusec)
            : nil

        let ticks = usage.ri_user_time &+ usage.ri_system_time
        let counters = ProcessCounters(
            startMicroseconds: start,
            cpuNanoseconds: Self.nanoseconds(
                absoluteTime: ticks,
                numerator: timebase.numer,
                denominator: timebase.denom
            ),
            footprintBytes: usage.ri_phys_footprint
        )
        return ProcessListing(pid: pid, name: name, outcome: .readable(counters))
    }

    /// Every PID, growing the buffer when the process table outgrows it between the two calls.
    private static func processIDs() throws(MetricIssue) -> [pid_t] {
        var capacity = 1_024
        for _ in 0..<8 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<pid_t>.size))
            guard bytes > 0 else {
                throw .kernelCallFailed(call: "proc_listpids", code: errno)
            }
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            if count < capacity {
                return pids.prefix(count).filter { $0 > 0 }
            }
            capacity *= 2
        }
        throw .kernelCallFailed(call: "proc_listpids", code: ENOMEM)
    }

    /// The file name of the executable. macOS returns the path even for processes it hides in other respects.
    private static func executableName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
