import os

/// GPU inventory with a fixed outcome, for tests and previews.
public struct MockGPUInventory: GPUInventorySource {
    private let result: Result<[GPUDescription], MetricIssue>

    public init(_ result: Result<[GPUDescription], MetricIssue>) {
        self.result = result
    }

    public func devices() throws(MetricIssue) -> [GPUDescription] {
        switch result {
        case let .success(devices):
            return devices
        case let .failure(issue):
            throw issue
        }
    }
}

/// A hardware measurement with a fixed capability and outcome. It counts its reads, so a test can prove that an
/// unavailable or restricted measurement is never read.
public final class MockHardwareSource<Value: Equatable & Sendable>: HardwareMetricSource, Sendable {
    public let capability: MetricCapability
    private let outcome: Result<Value, MetricIssue>
    private let reads = OSAllocatedUnfairLock(initialState: 0)

    public init(capability: MetricCapability, outcome: Result<Value, MetricIssue>) {
        self.capability = capability
        self.outcome = outcome
    }

    public var readCount: Int {
        reads.withLock { $0 }
    }

    public func read() throws(MetricIssue) -> Value {
        reads.withLock { $0 += 1 }
        switch outcome {
        case let .success(value):
            return value
        case let .failure(issue):
            throw issue
        }
    }
}

/// Hardware for a named kind of Mac, so tests and previews can check how each one is presented. The devices and
/// readings are invented for these scenarios and are labelled as mock values wherever they are shown.
public enum MockHardwareScenario: CaseIterable, Sendable {
    /// Apple silicon laptop with one unified GPU. Utilization and CPU temperature have no public API.
    case appleSiliconLaptop
    /// Workstation with a discrete GPU and an integrated GPU that reports no memory limit. Utilization is mocked as
    /// supported, to exercise that path. Temperature needs access the user has not granted.
    case workstationWithRestrictedSensors
    /// Virtual machine that exposes no GPU device.
    case virtualMachineWithoutGPU
    /// Metal refuses device enumeration for this process.
    case inventoryDenied

    static let appleGPU = GPUDescription(
        name: "Mock Apple GPU",
        registryID: 1,
        architecture: "mock_applegpu",
        hasUnifiedMemory: true,
        supportsRaytracing: true,
        maxThreadsPerThreadgroup: [1024, 1024, 1024],
        recommendedWorkingSetBytes: 12 * 1_073_741_824,
        allocatedBytes: 81_920,
        familyNames: ["Apple 9", "Mac 2", "Metal 3"]
    )

    static let discreteGPU = GPUDescription(
        name: "Mock Discrete GPU",
        registryID: 2,
        architecture: "mock_discrete",
        hasUnifiedMemory: false,
        supportsRaytracing: true,
        maxThreadsPerThreadgroup: [1024, 1024, 1024],
        recommendedWorkingSetBytes: 8 * 1_073_741_824,
        allocatedBytes: 2_147_483_648,
        familyNames: ["Mac 2", "Metal 3"]
    )

    static let integratedGPU = GPUDescription(
        name: "Mock Integrated GPU",
        registryID: 3,
        architecture: "mock_integrated",
        hasUnifiedMemory: true,
        supportsRaytracing: false,
        maxThreadsPerThreadgroup: [1024, 1024, 1024],
        recommendedWorkingSetBytes: 0,
        allocatedBytes: 0,
        familyNames: ["Mac 2", "Metal 3"]
    )

    /// The provider for this scenario. `thermal` overrides the scenario's thermal state.
    public func provider(thermal override: ThermalState? = nil) -> HardwareMetricProvider {
        let notAvailable = UnavailableMetricSource<Double>(reason: HardwareReasons.gpuUtilization)
        switch self {
        case .appleSiliconLaptop:
            return HardwareMetricProvider(
                inventory: MockGPUInventory(.success([Self.appleGPU])),
                thermal: MockHardwareSource(capability: .supported, outcome: .success(override ?? .nominal)),
                utilization: notAvailable,
                temperature: UnavailableMetricSource<Double>(reason: HardwareReasons.cpuTemperature)
            )
        case .workstationWithRestrictedSensors:
            return HardwareMetricProvider(
                inventory: MockGPUInventory(.success([Self.discreteGPU, Self.integratedGPU])),
                thermal: MockHardwareSource(capability: .supported, outcome: .success(override ?? .fair)),
                utilization: MockHardwareSource(capability: .supported, outcome: .success(0.42)),
                temperature: MockHardwareSource(
                    capability: .permissionRestricted(reason: "Access to temperature sensors has not been granted."),
                    outcome: .failure(.permissionDenied(resource: "temperature sensors"))
                )
            )
        case .virtualMachineWithoutGPU:
            return HardwareMetricProvider(
                inventory: MockGPUInventory(.success([])),
                thermal: MockHardwareSource(capability: .supported, outcome: .success(override ?? .nominal)),
                utilization: notAvailable,
                temperature: UnavailableMetricSource<Double>(reason: HardwareReasons.cpuTemperature)
            )
        case .inventoryDenied:
            return HardwareMetricProvider(
                inventory: MockGPUInventory(.failure(.permissionDenied(resource: "Metal devices"))),
                thermal: MockHardwareSource(capability: .supported, outcome: .success(override ?? .serious)),
                utilization: notAvailable,
                temperature: UnavailableMetricSource<Double>(reason: HardwareReasons.cpuTemperature)
            )
        }
    }

    public func sample(thermal: ThermalState? = nil) -> MetricReading<HardwareSample> {
        provider(thermal: thermal).read()
    }
}
