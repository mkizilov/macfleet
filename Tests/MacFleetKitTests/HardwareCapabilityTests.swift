import Foundation
import Testing
@testable import MacFleetKit

private func provider(
    inventory: MockGPUInventory = MockGPUInventory(.success([])),
    thermal: MockHardwareSource<ThermalState> = MockHardwareSource(capability: .supported, outcome: .success(.nominal)),
    utilization: any HardwareMetricSource<Double> = UnavailableMetricSource<Double>(reason: HardwareReasons.gpuUtilization),
    temperature: any HardwareMetricSource<Double> = UnavailableMetricSource<Double>(reason: HardwareReasons.cpuTemperature)
) -> HardwareMetricProvider {
    HardwareMetricProvider(inventory: inventory, thermal: thermal, utilization: utilization, temperature: temperature)
}

private func description(workingSet: UInt64 = 8_589_934_592, allocated: UInt64 = 0) -> GPUDescription {
    GPUDescription(
        name: "Test GPU",
        registryID: 42,
        architecture: "test_arch",
        hasUnifiedMemory: true,
        supportsRaytracing: false,
        maxThreadsPerThreadgroup: [1024, 1024, 1024],
        recommendedWorkingSetBytes: workingSet,
        allocatedBytes: allocated,
        familyNames: ["Apple 8"]
    )
}

@Suite("Metric capability")
struct MetricCapabilityTests {
    @Test func aPermissionDenialOnASupportedMetricRevealsARestriction() {
        let reading: MetricReading<Double> = .unavailable(.permissionDenied(resource: "sensors"))
        #expect(MetricCapability.observed(.supported, reading: reading) == .permissionRestricted(reason: "Permission denied for sensors"))
    }

    @Test func anUnsupportedReadingRevealsAnUnavailableMetric() {
        let reading: MetricReading<Double> = .unavailable(.unsupported(reason: "no API"))
        #expect(MetricCapability.observed(.supported, reading: reading) == .unavailable(reason: "no API"))
    }

    @Test func aTransientFailureKeepsTheDeclaredCapability() {
        let reading: MetricReading<Double> = .unavailable(.kernelCallFailed(call: "sysctl", code: 1))
        #expect(MetricCapability.observed(.supported, reading: reading) == .supported)
    }

    @Test func aSuccessfulReadKeepsTheDeclaredCapability() {
        #expect(MetricCapability.observed(.supported, reading: .available(0.5)) == .supported)
    }

    @Test func aDeclaredRestrictionIsNotOverriddenByAReading() {
        let declared = MetricCapability.unavailable(reason: "no API")
        #expect(MetricCapability.observed(declared, reading: .available(0.5)) == declared)
    }

    @Test func enumerationFailuresClassifyByCause() {
        #expect(MetricCapability.classify(.permissionDenied(resource: "Metal")) == .permissionRestricted(reason: "Permission denied for Metal"))
        #expect(MetricCapability.classify(.unsupported(reason: "none")) == .unavailable(reason: "none"))
        #expect(MetricCapability.classify(.timedOut) == .supported)
    }
}

@Suite("Hardware sources are read only when supported")
struct HardwareGatingTests {
    @Test func unavailableAndRestrictedMetricsAreNeverRead() {
        let utilization = MockHardwareSource<Double>(capability: .unavailable(reason: "no API"), outcome: .success(0.9))
        let temperature = MockHardwareSource<Double>(capability: .permissionRestricted(reason: "needs access"), outcome: .success(60))

        let hardware = provider(utilization: utilization, temperature: temperature).read().availableValue

        #expect(utilization.readCount == 0)
        #expect(temperature.readCount == 0)
        #expect(hardware?.gpuUtilization == .unavailable(.unsupported(reason: "no API")))
        #expect(hardware?.cpuTemperature == .unavailable(.permissionRestricted(reason: "needs access")))
        #expect(hardware?.capabilities.gpuUtilization == .unavailable(reason: "no API"))
        #expect(hardware?.capabilities.cpuTemperature == .permissionRestricted(reason: "needs access"))
    }

    @Test func aSupportedMetricIsReadOnce() {
        let utilization = MockHardwareSource<Double>(capability: .supported, outcome: .success(0.25))
        let hardware = provider(utilization: utilization).read().availableValue

        #expect(utilization.readCount == 1)
        #expect(hardware?.gpuUtilization == .available(0.25))
        #expect(hardware?.capabilities.gpuUtilization == .supported)
    }

    @Test func aSupportedMetricThatIsRefusedBecomesRestricted() {
        let utilization = MockHardwareSource<Double>(
            capability: .supported,
            outcome: .failure(.permissionDenied(resource: "sensors"))
        )
        let hardware = provider(utilization: utilization).read().availableValue

        #expect(hardware?.gpuUtilization == .unavailable(.permissionDenied(resource: "sensors")))
        #expect(hardware?.capabilities.gpuUtilization == .permissionRestricted(reason: "Permission denied for sensors"))
    }

    @Test func aTransientFailureLeavesTheCapabilitySupported() {
        let utilization = MockHardwareSource<Double>(
            capability: .supported,
            outcome: .failure(.kernelCallFailed(call: "sysctl", code: 9))
        )
        let hardware = provider(utilization: utilization).read().availableValue

        #expect(hardware?.gpuUtilization == .unavailable(.kernelCallFailed(call: "sysctl", code: 9)))
        #expect(hardware?.capabilities.gpuUtilization == .supported)
    }
}

@Suite("Mocked hardware scenarios")
struct MockHardwareScenarioTests {
    @Test func appleSiliconLaptopHasOneUnifiedGPUAndNoPublicUtilizationOrTemperature() throws {
        let hardware = try #require(MockHardwareScenario.appleSiliconLaptop.sample().availableValue)
        let devices = try #require(hardware.gpuDevices.availableValue)

        #expect(devices.map(\.name) == ["Mock Apple GPU"])
        #expect(devices[0].hasUnifiedMemory)
        #expect(devices[0].workingSet == .available(12 * 1_073_741_824))
        #expect(hardware.capabilities.gpuDevices == .supported)
        #expect(hardware.capabilities.gpuMemory == .supported)
        #expect(hardware.gpuUtilization == .unavailable(.unsupported(reason: HardwareReasons.gpuUtilization)))
        #expect(hardware.capabilities.gpuUtilization == .unavailable(reason: HardwareReasons.gpuUtilization))
        #expect(hardware.cpuTemperature == .unavailable(.unsupported(reason: HardwareReasons.cpuTemperature)))
        #expect(hardware.thermalState == .available(.nominal))
    }

    @Test func workstationHasTwoGPUsOneWithoutAMemoryLimitAndRestrictedTemperature() throws {
        let hardware = try #require(MockHardwareScenario.workstationWithRestrictedSensors.sample().availableValue)
        let devices = try #require(hardware.gpuDevices.availableValue)

        #expect(devices.map(\.name) == ["Mock Discrete GPU", "Mock Integrated GPU"])
        #expect(devices[0].hasUnifiedMemory == false)
        #expect(devices[0].workingSet == .available(8 * 1_073_741_824))
        #expect(devices[1].workingSet == .unavailable(.unsupported(reason: HardwareReasons.noMemoryLimit)))
        #expect(hardware.capabilities.gpuMemory == .supported)
        #expect(hardware.gpuUtilization == .available(0.42))
        #expect(hardware.capabilities.gpuUtilization == .supported)
        #expect(hardware.cpuTemperature == .unavailable(.permissionRestricted(reason: "Access to temperature sensors has not been granted.")))
        #expect(hardware.thermalState == .available(.fair))
    }

    @Test func aVirtualMachineWithoutAGPUReportsNoDevicesAndNoGPUMemory() throws {
        let hardware = try #require(MockHardwareScenario.virtualMachineWithoutGPU.sample().availableValue)

        #expect(hardware.gpuDevices == .unavailable(.unsupported(reason: HardwareReasons.noGPU)))
        #expect(hardware.capabilities.gpuDevices == .unavailable(reason: HardwareReasons.noGPU))
        #expect(hardware.capabilities.gpuMemory == .unavailable(reason: "No GPU device was read, so no GPU memory is reported."))
    }

    @Test func aDeniedInventoryIsRestrictedNotEmpty() throws {
        let hardware = try #require(MockHardwareScenario.inventoryDenied.sample().availableValue)

        #expect(hardware.gpuDevices == .unavailable(.permissionDenied(resource: "Metal devices")))
        #expect(hardware.capabilities.gpuDevices == .permissionRestricted(reason: "Permission denied for Metal devices"))
        #expect(hardware.thermalState == .available(.serious))
    }

    /// Across every scenario, a reading has a value exactly when its capability is supported. A value never appears
    /// for a measurement the Mac cannot report, and a supported measurement never goes missing silently.
    @Test func aValueExistsExactlyWhenItsCapabilityIsSupported() throws {
        for scenario in MockHardwareScenario.allCases {
            let hardware = try #require(scenario.sample().availableValue)
            #expect((hardware.capabilities.gpuDevices == .supported) == (hardware.gpuDevices.availableValue != nil))
            #expect((hardware.capabilities.gpuUtilization == .supported) == (hardware.gpuUtilization.availableValue != nil))
            #expect((hardware.capabilities.thermalState == .supported) == (hardware.thermalState.availableValue != nil))
            #expect((hardware.capabilities.cpuTemperature == .supported) == (hardware.cpuTemperature.availableValue != nil))
        }
    }

    @Test func aThermalOverrideReplacesTheScenarioState() {
        let hardware = MockHardwareScenario.appleSiliconLaptop.sample(thermal: .critical).availableValue
        #expect(hardware?.thermalState == .available(.critical))
    }

    @Test func aSimulatedSnapshotCarriesAnHonestHardwareSample() {
        var timeline = SimulatedMetricsTimeline(seed: 3)
        let snapshot = timeline.nextSnapshot(selection: .default, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let hardware = snapshot.hardware.availableValue
        #expect(hardware?.gpuUtilization == .unavailable(.unsupported(reason: HardwareReasons.gpuUtilization)))
        #expect(hardware?.cpuTemperature == .unavailable(.unsupported(reason: HardwareReasons.cpuTemperature)))
    }

    @Test func theHardwareSampleSurvivesEncodingAndDecoding() throws {
        let hardware = MockSystemMetricsProvider.sampleSnapshot.hardware
        let data = try JSONEncoder().encode(MockSystemMetricsProvider.sampleSnapshot)
        let decoded = try JSONDecoder().decode(SystemSnapshot.self, from: data)
        #expect(decoded.hardware == hardware)
    }
}

@Suite("GPU device mapping")
struct GPUDeviceMappingTests {
    @Test func aDeviceWithoutAMemoryLimitReportsThatInsteadOfZero() {
        let device = GPUDevice(description(workingSet: 0))
        #expect(device.workingSet == .unavailable(.unsupported(reason: HardwareReasons.noMemoryLimit)))
    }

    @Test func zeroAllocationIsARealValueAndIsReported() {
        let device = GPUDevice(description(allocated: 0))
        #expect(device.allocated == .available(0))
    }

    @Test func deviceFieldsFollowTheDescription() {
        let device = GPUDevice(description())
        #expect(device.id == 42)
        #expect(device.name == "Test GPU")
        #expect(device.architecture == "test_arch")
        #expect(device.hasUnifiedMemory)
        #expect(device.supportsRaytracing == false)
        #expect(device.maxThreadsPerThreadgroup == [1024, 1024, 1024])
        #expect(device.familyNames == ["Apple 8"])
    }

    @Test func metalFamilyValuesMapToReadableNames() {
        #expect(MetalInventory.familyName(1001) == "Apple 1")
        #expect(MetalInventory.familyName(1009) == "Apple 9")
        #expect(MetalInventory.familyName(1011) == "Apple 11")
        #expect(MetalInventory.familyName(2002) == "Mac 2")
        #expect(MetalInventory.familyName(5001) == "Metal 3")
        #expect(MetalInventory.familyName(5002) == "Metal 4")
    }
}

@Suite("Thermal state mapping")
struct ThermalStateMappingTests {
    @Test func everyProcessInfoStateMapsToItsOwnState() {
        #expect(ThermalState(ProcessInfo.ThermalState.nominal) == .nominal)
        #expect(ThermalState(ProcessInfo.ThermalState.fair) == .fair)
        #expect(ThermalState(ProcessInfo.ThermalState.serious) == .serious)
        #expect(ThermalState(ProcessInfo.ThermalState.critical) == .critical)
    }
}

@Suite("Inventory failures in the provider")
struct InventoryFailureTests {
    @Test func aRefusedInventoryDoesNotStopTheOtherMeasurements() {
        let hardware = provider(
            inventory: MockGPUInventory(.failure(.permissionDenied(resource: "Metal devices"))),
            thermal: MockHardwareSource(capability: .supported, outcome: .success(.nominal))
        ).read().availableValue

        #expect(hardware?.gpuDevices == .unavailable(.permissionDenied(resource: "Metal devices")))
        #expect(hardware?.thermalState == .available(.nominal))
    }

    @Test func aTransientInventoryFailureIsReportedAsSupportedWithTheCause() {
        let hardware = provider(
            inventory: MockGPUInventory(.failure(.kernelCallFailed(call: "MTLCopyAllDevices", code: 5)))
        ).read().availableValue

        #expect(hardware?.gpuDevices == .unavailable(.kernelCallFailed(call: "MTLCopyAllDevices", code: 5)))
        #expect(hardware?.capabilities.gpuDevices == .supported)
    }
}
