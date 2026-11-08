import Foundation
import MacFleetKit
import Testing
@testable import MacFleetState

@Suite("Hardware presentation by Mac kind")
struct HardwarePresentationScenarioTests {
    @Test func appleSiliconLaptopShowsItsGPUAndNamesTheMissingMeasurements() throws {
        let presentation = HardwarePresentation(sample: MockHardwareScenario.appleSiliconLaptop.sample())

        let rows = try #require(presentation.devices.availableValue)
        #expect(rows.map(\.name) == ["Mock Apple GPU"])
        #expect(rows[0].memoryKind == "Unified memory")
        #expect(rows[0].capabilities == "Ray tracing · Apple 9, Mac 2, Metal 3 · architecture mock_applegpu")
        #expect(rows[0].threadgroupLimit == "Threadgroup limit 1024 × 1024 × 1024")
        #expect(rows[0].memory.visible == "Working set 12 GB · Metal allocations 80 KB")
        #expect(presentation.devicesStatus == .supported)

        #expect(presentation.utilization == .unavailable(HardwareReasons.gpuUtilization))
        #expect(presentation.utilizationStatus == .unavailable)
        #expect(presentation.cpuTemperature == .unavailable(HardwareReasons.cpuTemperature))
        #expect(presentation.temperatureStatus == .unavailable)
    }

    @Test func workstationShowsSupportedUtilizationAndRestrictedTemperatureWithTheirReason() throws {
        let presentation = HardwarePresentation(sample: MockHardwareScenario.workstationWithRestrictedSensors.sample())

        let rows = try #require(presentation.devices.availableValue)
        #expect(rows.map(\.memoryKind) == ["Dedicated memory", "Unified memory"])
        #expect(rows[1].memory.visible == "Working set not reported · Metal allocations 0 B")
        #expect(rows[1].memory.spoken == "Working set not reported, Metal allocations 0 bytes")

        #expect(presentation.utilization.availableValue?.text == "42%")
        #expect(presentation.utilizationStatus == .supported)

        #expect(presentation.cpuTemperature == .unavailable("Access to temperature sensors has not been granted."))
        #expect(presentation.temperatureStatus == .permissionRestricted)
        let temperatureRow = try #require(presentation.capabilities.first { $0.id == "cpu-temperature" })
        #expect(temperatureRow.status == .permissionRestricted)
        #expect(temperatureRow.reason == "Access to temperature sensors has not been granted.")
    }

    @Test func aVirtualMachineShowsNoDevicesWithTheReason() throws {
        let presentation = HardwarePresentation(sample: MockHardwareScenario.virtualMachineWithoutGPU.sample())

        #expect(presentation.devices == .unavailable(HardwareReasons.noGPU))
        #expect(presentation.devicesStatus == .unavailable)
        let memoryRow = try #require(presentation.capabilities.first { $0.id == "gpu-memory" })
        #expect(memoryRow.status == .unavailable)
        #expect(memoryRow.reason == "No GPU device was read, so no GPU memory is reported.")
    }

    @Test func aDeniedInventoryIsShownAsPermissionNeededNotAsEmpty() {
        let presentation = HardwarePresentation(sample: MockHardwareScenario.inventoryDenied.sample())

        #expect(presentation.devices == .unavailable("Permission denied for Metal devices"))
        #expect(presentation.devicesStatus == .permissionRestricted)
        #expect(presentation.devicesStatus.title == "Permission needed")
    }

    @Test func aMissingHardwareSectionShowsItsReasonForEveryMeasurement() {
        let presentation = HardwarePresentation(sample: .unavailable(.timedOut))

        #expect(presentation.devices == .unavailable("Sampling timed out"))
        #expect(presentation.thermal == .unavailable("Sampling timed out"))
        #expect(presentation.capabilities.allSatisfy { $0.status == .unavailable && $0.reason == "Sampling timed out" })
    }
}

@Suite("Thermal state presentation")
struct ThermalPresentationTests {
    @Test func everyStateHasATitleAndASeverity() {
        #expect(ThermalDisplay(.nominal).title == "Nominal")
        #expect(ThermalDisplay(.nominal).level == .normal)
        #expect(ThermalDisplay(.fair).title == "Fair")
        #expect(ThermalDisplay(.fair).level == .elevated)
        #expect(ThermalDisplay(.serious).title == "Serious")
        #expect(ThermalDisplay(.serious).level == .critical)
        #expect(ThermalDisplay(.critical).title == "Critical")
        #expect(ThermalDisplay(.critical).level == .critical)
    }

    @Test func spokenWordingNamesTheState() {
        #expect(ThermalDisplay(.serious).spokenText == "Thermal state serious")
    }

    @Test func theOverviewShowsTheStateTitle() throws {
        let presentation = HardwarePresentation(sample: MockHardwareScenario.workstationWithRestrictedSensors.sample())
        #expect(presentation.thermalOverview.availableValue?.visible == "Fair")
    }
}

@Suite("Capability status")
struct CapabilityStatusTests {
    @Test func everyCapabilityMapsToItsStatus() {
        #expect(CapabilityStatus(.supported) == .supported)
        #expect(CapabilityStatus(.permissionRestricted(reason: "x")) == .permissionRestricted)
        #expect(CapabilityStatus(.unavailable(reason: "x")) == .unavailable)
    }

    @Test func statusesHaveTextLabels() {
        #expect(CapabilityStatus.supported.title == "Supported")
        #expect(CapabilityStatus.permissionRestricted.title == "Permission needed")
        #expect(CapabilityStatus.unavailable.title == "Not available")
    }
}

@Suite("Hardware in the dashboard")
struct DashboardHardwareTests {
    @Test func theDashboardCarriesTheHardwarePresentation() {
        let dashboard = DashboardPresentation(
            snapshot: MockSystemMetricsProvider.sampleSnapshot,
            history: MetricHistory(),
            selection: .default
        )
        #expect(dashboard.hardware.devicesStatus == .supported)
        #expect(dashboard.hardware.utilizationStatus == .unavailable)
        #expect(dashboard.hardware.thermalOverview.availableValue?.visible == "Nominal")
    }

    /// A value of zero must never stand in for a measurement this Mac cannot report.
    @Test func noUnavailableMeasurementRendersAsZero() {
        for scenario in MockHardwareScenario.allCases {
            let presentation = HardwarePresentation(sample: scenario.sample())
            if presentation.utilizationStatus != .supported {
                #expect(presentation.utilization.availableValue == nil)
            }
            if presentation.temperatureStatus != .supported {
                #expect(presentation.cpuTemperature.availableValue == nil)
            }
            if presentation.devicesStatus != .supported {
                #expect(presentation.devices.availableValue == nil)
            }
        }
    }
}
