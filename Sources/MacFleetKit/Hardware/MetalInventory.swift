import Metal

/// GPUs from `MTLCopyAllDevices` and their public Metal properties. Reading them needs no permission.
public struct MetalInventory: GPUInventorySource {
    /// Metal family raw values to check. The Apple families run 1001 to 1011, then Mac 2 and Metal 3 and 4.
    /// Raw values let one list cover every family the SDK defines, and a family the device lacks is simply skipped.
    static let familyValues = Array(1001...1011) + [2002, 5001, 5002]

    public init() {}

    public func devices() throws(MetricIssue) -> [GPUDescription] {
        MTLCopyAllDevices().map(Self.describe)
    }

    static func describe(_ device: MTLDevice) -> GPUDescription {
        let limit = device.maxThreadsPerThreadgroup
        return GPUDescription(
            name: device.name,
            registryID: device.registryID,
            architecture: device.architecture.name,
            hasUnifiedMemory: device.hasUnifiedMemory,
            supportsRaytracing: device.supportsRaytracing,
            maxThreadsPerThreadgroup: [limit.width, limit.height, limit.depth],
            recommendedWorkingSetBytes: UInt64(device.recommendedMaxWorkingSetSize),
            allocatedBytes: UInt64(device.currentAllocatedSize),
            familyNames: familyValues.compactMap { value in
                guard let family = MTLGPUFamily(rawValue: value), device.supportsFamily(family) else { return nil }
                return familyName(value)
            }
        )
    }

    static func familyName(_ value: Int) -> String {
        switch value {
        case 1001...1999: "Apple \(value - 1000)"
        case 2000...2999: "Mac \(value - 2000)"
        case 5001: "Metal 3"
        case 5002: "Metal 4"
        default: "Family \(value)"
        }
    }
}
