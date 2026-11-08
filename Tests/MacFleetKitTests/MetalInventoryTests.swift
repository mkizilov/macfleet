import Foundation
import Testing
@testable import MacFleetKit

/// These tests read the real hardware of the machine running them. They check what is true of any Mac with a GPU,
/// and they assert what this build can and cannot report, rather than fixed device names.
@Suite("Live hardware on this Mac")
struct LiveHardwareTests {
    @Test func metalReportsAtLeastOneNamedGPUWithFamilies() throws {
        let devices = try MetalInventory().devices()
        #expect(!devices.isEmpty)
        for device in devices {
            #expect(!device.name.isEmpty)
            #expect(!device.familyNames.isEmpty)
            #expect(device.maxThreadsPerThreadgroup.count == 3)
        }
    }

    @Test func metalReportsAWorkingSetLimitForTheFirstGPU() throws {
        let devices = try MetalInventory().devices()
        let first = try #require(devices.first)
        #expect(first.recommendedWorkingSetBytes > 0)
    }

    @Test func thermalStateIsReadFromProcessInfo() throws {
        let state = try ProcessThermalSource().read()
        #expect(ThermalState.allCases.contains(state))
    }

    /// No documented macOS API reports these two values. This test fails if the code starts reporting them, so any
    /// new source must come with a public API that justifies it.
    @Test func utilizationAndTemperatureAreHonestlyUnavailable() throws {
        let hardware = try #require(HardwareMetricProvider.live.read().availableValue)
        #expect(hardware.gpuUtilization == .unavailable(.unsupported(reason: HardwareReasons.gpuUtilization)))
        #expect(hardware.capabilities.gpuUtilization == .unavailable(reason: HardwareReasons.gpuUtilization))
        #expect(hardware.cpuTemperature == .unavailable(.unsupported(reason: HardwareReasons.cpuTemperature)))
        #expect(hardware.capabilities.cpuTemperature == .unavailable(reason: HardwareReasons.cpuTemperature))
    }

    @Test func liveSampleReportsTheDevicesItRead() throws {
        let hardware = try #require(HardwareMetricProvider.live.read().availableValue)
        #expect(hardware.capabilities.gpuDevices == .supported)
        #expect(hardware.gpuDevices.availableValue?.isEmpty == false)
        #expect(hardware.thermalState.availableValue != nil)
    }
}
