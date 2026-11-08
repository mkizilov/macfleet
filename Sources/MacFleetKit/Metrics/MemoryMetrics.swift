import Foundation

/// Page counts from `host_statistics64(HOST_VM_INFO64)`, with the kernel page size they are counted in.
public struct VMCounters: Equatable, Sendable {
    public let pageSize: UInt64
    public let internalPages: UInt64
    public let purgeablePages: UInt64
    public let wiredPages: UInt64
    public let compressedPages: UInt64

    public init(pageSize: UInt64, internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64, compressedPages: UInt64) {
        self.pageSize = pageSize
        self.internalPages = internalPages
        self.purgeablePages = purgeablePages
        self.wiredPages = wiredPages
        self.compressedPages = compressedPages
    }
}

public struct MemoryUsage: Codable, Equatable, Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let availableBytes: UInt64

    public init(totalBytes: UInt64, usedBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }
}

/// Raw values match the kernel's `kern.memorystatus_vm_pressure_level` sysctl.
public enum MemoryPressureLevel: Int32, Codable, Equatable, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4
}

enum MemoryUsageCalculator {
    /// Used memory has the same breakdown as Activity Monitor's "Memory Used": app memory (anonymous
    /// pages minus purgeable), wired memory, and compressed memory. Available is what remains of
    /// physical memory, which includes free pages and reclaimable file cache.
    static func usage(from counters: VMCounters, totalBytes: UInt64) throws(MetricIssue) -> MemoryUsage {
        guard counters.internalPages >= counters.purgeablePages else {
            throw .inconsistentMemoryAccounting
        }
        let usedPages = counters.internalPages - counters.purgeablePages
            + counters.wiredPages + counters.compressedPages
        let usedBytes = usedPages * counters.pageSize
        guard usedBytes <= totalBytes else { throw .inconsistentMemoryAccounting }
        return MemoryUsage(totalBytes: totalBytes, usedBytes: usedBytes, availableBytes: totalBytes - usedBytes)
    }
}
