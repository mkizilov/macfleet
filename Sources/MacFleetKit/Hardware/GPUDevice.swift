import Foundation

/// What Metal reports about one device, before it becomes a `GPUDevice`. Plain values keep the mapping testable
/// on any machine.
public struct GPUDescription: Equatable, Sendable {
    public let name: String
    public let registryID: UInt64
    public let architecture: String
    public let hasUnifiedMemory: Bool
    public let supportsRaytracing: Bool
    /// Largest threadgroup in each dimension: width, height, depth.
    public let maxThreadsPerThreadgroup: [Int]
    /// Metal's recommended working-set limit. Zero when the device reports none.
    public let recommendedWorkingSetBytes: UInt64
    /// Memory Metal reports as allocated on the device.
    public let allocatedBytes: UInt64
    /// Metal feature families the device supports, such as "Apple 9" or "Metal 3".
    public let familyNames: [String]

    public init(
        name: String,
        registryID: UInt64,
        architecture: String,
        hasUnifiedMemory: Bool,
        supportsRaytracing: Bool,
        maxThreadsPerThreadgroup: [Int],
        recommendedWorkingSetBytes: UInt64,
        allocatedBytes: UInt64,
        familyNames: [String]
    ) {
        self.name = name
        self.registryID = registryID
        self.architecture = architecture
        self.hasUnifiedMemory = hasUnifiedMemory
        self.supportsRaytracing = supportsRaytracing
        self.maxThreadsPerThreadgroup = maxThreadsPerThreadgroup
        self.recommendedWorkingSetBytes = recommendedWorkingSetBytes
        self.allocatedBytes = allocatedBytes
        self.familyNames = familyNames
    }
}

/// A GPU on this Mac. Memory values are readings, so a device that reports no limit shows that instead of zero.
public struct GPUDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt64
    public let name: String
    public let architecture: String
    public let hasUnifiedMemory: Bool
    public let supportsRaytracing: Bool
    public let maxThreadsPerThreadgroup: [Int]
    public let familyNames: [String]
    /// Metal's recommended working-set limit for this device.
    public let workingSet: MetricReading<UInt64>
    /// Memory Metal reports as allocated on the device. Zero is a real value, so it is reported as one.
    public let allocated: MetricReading<UInt64>

    public init(_ description: GPUDescription) {
        id = description.registryID
        name = description.name
        architecture = description.architecture
        hasUnifiedMemory = description.hasUnifiedMemory
        supportsRaytracing = description.supportsRaytracing
        maxThreadsPerThreadgroup = description.maxThreadsPerThreadgroup
        familyNames = description.familyNames
        workingSet = description.recommendedWorkingSetBytes > 0
            ? .available(description.recommendedWorkingSetBytes)
            : .unavailable(.unsupported(reason: HardwareReasons.noMemoryLimit))
        allocated = .available(description.allocatedBytes)
    }
}
