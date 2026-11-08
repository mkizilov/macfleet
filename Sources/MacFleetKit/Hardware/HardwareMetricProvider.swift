import Foundation

/// Every hardware measurement taken in one sample. A measurement with no public API is `unavailable` with its reason,
/// never a placeholder number.
public struct HardwareSample: Codable, Equatable, Sendable {
    public let gpuDevices: MetricReading<[GPUDevice]>
    /// Fraction of GPU time busy, from 0 to 1. Reported only where a public API provides it.
    public let gpuUtilization: MetricReading<Double>
    public let thermalState: MetricReading<ThermalState>
    /// Degrees Celsius. Reported only where a public API provides it.
    public let cpuTemperature: MetricReading<Double>
    public let capabilities: HardwareCapabilities

    public init(
        gpuDevices: MetricReading<[GPUDevice]>,
        gpuUtilization: MetricReading<Double>,
        thermalState: MetricReading<ThermalState>,
        cpuTemperature: MetricReading<Double>,
        capabilities: HardwareCapabilities
    ) {
        self.gpuDevices = gpuDevices
        self.gpuUtilization = gpuUtilization
        self.thermalState = thermalState
        self.cpuTemperature = cpuTemperature
        self.capabilities = capabilities
    }
}

/// Reads the hardware measurements. A source's declared capability is checked first: an unavailable or
/// permission-restricted source is not read at all, and its reading carries the reason.
public struct HardwareMetricProvider: MetricProvider {
    public typealias Output = HardwareSample

    private let inventory: any GPUInventorySource
    private let thermal: any HardwareMetricSource<ThermalState>
    private let utilization: any HardwareMetricSource<Double>
    private let temperature: any HardwareMetricSource<Double>

    public init(
        inventory: any GPUInventorySource,
        thermal: any HardwareMetricSource<ThermalState>,
        utilization: any HardwareMetricSource<Double>,
        temperature: any HardwareMetricSource<Double>
    ) {
        self.inventory = inventory
        self.thermal = thermal
        self.utilization = utilization
        self.temperature = temperature
    }

    /// This Mac: Metal for GPUs, `ProcessInfo` for thermal state, and no public API for utilization or temperature.
    public static let live = HardwareMetricProvider(
        inventory: MetalInventory(),
        thermal: ProcessThermalSource(),
        utilization: UnavailableMetricSource<Double>(reason: HardwareReasons.gpuUtilization),
        temperature: UnavailableMetricSource<Double>(reason: HardwareReasons.cpuTemperature)
    )

    public func sample(_ context: SampleContext) async -> MetricReading<HardwareSample> {
        read()
    }

    /// Takes one sample. Every source is synchronous, so this needs no suspension.
    public func read() -> MetricReading<HardwareSample> {
        let devices = gpuDevices()
        let thermalResult = Self.read(thermal)
        let utilizationResult = Self.read(utilization)
        let temperatureResult = Self.read(temperature)
        return .available(HardwareSample(
            gpuDevices: devices.reading,
            gpuUtilization: utilizationResult.reading,
            thermalState: thermalResult.reading,
            cpuTemperature: temperatureResult.reading,
            capabilities: HardwareCapabilities(
                gpuDevices: devices.capability,
                gpuMemory: Self.memoryCapability(devices.reading),
                gpuUtilization: utilizationResult.capability,
                thermalState: thermalResult.capability,
                cpuTemperature: temperatureResult.capability
            )
        ))
    }

    private func gpuDevices() -> (reading: MetricReading<[GPUDevice]>, capability: MetricCapability) {
        do throws(MetricIssue) {
            let descriptions = try inventory.devices()
            guard !descriptions.isEmpty else {
                return (
                    .unavailable(.unsupported(reason: HardwareReasons.noGPU)),
                    .unavailable(reason: HardwareReasons.noGPU)
                )
            }
            return (.available(descriptions.map { GPUDevice($0) }), .supported)
        } catch {
            return (.unavailable(error), MetricCapability.classify(error))
        }
    }

    private static func read<Source: HardwareMetricSource>(
        _ source: Source
    ) -> (reading: MetricReading<Source.Value>, capability: MetricCapability) {
        switch source.capability {
        case let .unavailable(reason):
            return (.unavailable(.unsupported(reason: reason)), source.capability)
        case let .permissionRestricted(reason):
            return (.unavailable(.permissionRestricted(reason: reason)), source.capability)
        case .supported:
            let reading = metricReading { () throws(MetricIssue) -> Source.Value in try source.read() }
            return (reading, MetricCapability.observed(source.capability, reading: reading))
        }
    }

    private static func memoryCapability(_ devices: MetricReading<[GPUDevice]>) -> MetricCapability {
        guard let list = devices.availableValue else {
            return .unavailable(reason: "No GPU device was read, so no GPU memory is reported.")
        }
        if list.contains(where: { $0.workingSet.availableValue != nil }) {
            return .supported
        }
        return .unavailable(reason: HardwareReasons.noMemoryLimit)
    }
}
