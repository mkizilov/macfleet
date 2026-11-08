import Foundation

/// A mounted volume as the operating system reports it. Each capacity value carries its own failure.
public struct RawVolume: Equatable, Sendable {
    public let name: String
    public let mountPoint: String
    public let isRemovable: Bool
    public let isBrowsable: Bool
    public let totalBytes: MetricReading<UInt64>
    public let availableBytes: MetricReading<UInt64>

    public init(
        name: String,
        mountPoint: String,
        isRemovable: Bool,
        isBrowsable: Bool,
        totalBytes: MetricReading<UInt64>,
        availableBytes: MetricReading<UInt64>
    ) {
        self.name = name
        self.mountPoint = mountPoint
        self.isRemovable = isRemovable
        self.isBrowsable = isBrowsable
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }
}

public protocol VolumeSource: Sendable {
    mutating func volumes() throws(MetricIssue) -> [RawVolume]
}

public struct DiskCapacity: Codable, Equatable, Sendable {
    public let totalBytes: UInt64
    public let availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: UInt64 {
        totalBytes - availableBytes
    }

    public var utilization: Double {
        Double(usedBytes) / Double(totalBytes)
    }
}

public struct VolumeMetrics: Codable, Equatable, Sendable {
    public let name: String
    public let mountPoint: String
    public let isRemovable: Bool
    public let isBrowsable: Bool
    public let capacity: MetricReading<DiskCapacity>

    public init(name: String, mountPoint: String, isRemovable: Bool, isBrowsable: Bool, capacity: MetricReading<DiskCapacity>) {
        self.name = name
        self.mountPoint = mountPoint
        self.isRemovable = isRemovable
        self.isBrowsable = isBrowsable
        self.capacity = capacity
    }
}

enum DiskUsageCalculator {
    static func capacity(total: UInt64, available: UInt64) throws(MetricIssue) -> DiskCapacity {
        guard total > 0, available <= total else { throw .inconsistentStorageCounters }
        return DiskCapacity(totalBytes: total, availableBytes: available)
    }

    static func reading(total: MetricReading<UInt64>, available: MetricReading<UInt64>) -> MetricReading<DiskCapacity> {
        switch (total, available) {
        case let (.available(totalBytes), .available(availableBytes)):
            do throws(MetricIssue) {
                return .available(try capacity(total: totalBytes, available: availableBytes))
            } catch {
                return .unavailable(error)
            }
        case let (.unavailable(issue), _), let (_, .unavailable(issue)):
            return .unavailable(issue)
        }
    }
}
