import MacFleetKit

/// How a measurement stands on this Mac. Always shown as text, so colour is never the only signal.
public enum CapabilityStatus: Equatable, Sendable {
    case supported
    case permissionRestricted
    case unavailable

    public init(_ capability: MetricCapability) {
        switch capability {
        case .supported: self = .supported
        case .permissionRestricted: self = .permissionRestricted
        case .unavailable: self = .unavailable
        }
    }

    public var title: String {
        switch self {
        case .supported: "Supported"
        case .permissionRestricted: "Permission needed"
        case .unavailable: "Not available"
        }
    }
}

/// One line of the capability list.
public struct CapabilityRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let status: CapabilityStatus
    /// Why the measurement is restricted or missing. Nil when it is supported.
    public let reason: String?

    public init(id: String, title: String, status: CapabilityStatus, reason: String?) {
        self.id = id
        self.title = title
        self.status = status
        self.reason = reason
    }
}

/// One GPU in the device list.
public struct GPUDeviceRow: Equatable, Sendable, Identifiable {
    public let id: UInt64
    public let name: String
    public let memoryKind: String
    public let capabilities: String
    public let threadgroupLimit: String
    public let memory: Readout

    public init(_ device: GPUDevice) {
        id = device.id
        name = device.name
        memoryKind = device.hasUnifiedMemory ? "Unified memory" : "Dedicated memory"
        capabilities = [
            device.supportsRaytracing ? "Ray tracing" : "No ray tracing",
            device.familyNames.joined(separator: ", "),
            "architecture \(device.architecture)",
        ].filter { !$0.isEmpty }.joined(separator: " · ")
        threadgroupLimit = device.maxThreadsPerThreadgroup.count == 3
            ? "Threadgroup limit \(device.maxThreadsPerThreadgroup.map(String.init).joined(separator: " × "))"
            : "Threadgroup limit not reported"
        let working = device.workingSet.availableValue
            .map { "Working set \(ByteFormatting.binary(bytes: $0))" } ?? "Working set not reported"
        let allocated = device.allocated.availableValue
            .map { " · Metal allocations \(ByteFormatting.binary(bytes: $0))" } ?? ""
        memory = Readout(
            visible: working + allocated,
            spoken: [
                device.workingSet.availableValue.map { "Working set \(SpokenFormatting.bytes($0, binary: true))" }
                    ?? "Working set not reported",
                device.allocated.availableValue.map { "Metal allocations \(SpokenFormatting.bytes($0, binary: true))" },
            ].compactMap { $0 }.joined(separator: ", ")
        )
    }
}

/// The thermal state as shown: a title, a severity, and the spoken wording.
public struct ThermalDisplay: Equatable, Sendable {
    public let title: String
    public let level: UsageLevel
    public let spokenText: String

    public init(_ state: ThermalState) {
        switch state {
        case .nominal:
            title = "Nominal"
            level = .normal
        case .fair:
            title = "Fair"
            level = .elevated
        case .serious:
            title = "Serious"
            level = .critical
        case .critical:
            title = "Critical"
            level = .critical
        }
        spokenText = "Thermal state \(title.lowercased())"
    }
}

/// Hardware measurements as the dashboard shows them. A measurement with no reading shows its reason and its status,
/// never a zero.
public struct HardwarePresentation: Equatable, Sendable {
    public let devices: Presented<[GPUDeviceRow]>
    public let devicesStatus: CapabilityStatus
    public let utilization: Presented<UsageValue>
    public let utilizationStatus: CapabilityStatus
    public let thermal: Presented<ThermalDisplay>
    public let thermalStatus: CapabilityStatus
    public let thermalOverview: Presented<Readout>
    public let cpuTemperature: Presented<Readout>
    public let temperatureStatus: CapabilityStatus
    public let capabilities: [CapabilityRow]

    public init(sample: MetricReading<HardwareSample>) {
        switch sample {
        case let .available(hardware):
            devices = presented(hardware.gpuDevices) { $0.map(GPUDeviceRow.init) }
            utilization = presented(hardware.gpuUtilization) { UsageValue(fraction: $0) }
            thermal = presented(hardware.thermalState) { ThermalDisplay($0) }
            cpuTemperature = presented(hardware.cpuTemperature) { Self.temperatureReadout($0) }
            let capabilities = hardware.capabilities
            devicesStatus = CapabilityStatus(capabilities.gpuDevices)
            utilizationStatus = CapabilityStatus(capabilities.gpuUtilization)
            thermalStatus = CapabilityStatus(capabilities.thermalState)
            temperatureStatus = CapabilityStatus(capabilities.cpuTemperature)
            self.capabilities = [
                Self.row("gpu-devices", "GPU devices", capabilities.gpuDevices),
                Self.row("gpu-memory", "GPU memory", capabilities.gpuMemory),
                Self.row("gpu-utilization", "GPU utilization", capabilities.gpuUtilization),
                Self.row("thermal-state", "Thermal state", capabilities.thermalState),
                Self.row("cpu-temperature", "CPU temperature", capabilities.cpuTemperature),
            ]
        case let .unavailable(issue):
            let reason = issue.errorDescription ?? "Not available"
            devices = .unavailable(reason)
            utilization = .unavailable(reason)
            thermal = .unavailable(reason)
            cpuTemperature = .unavailable(reason)
            devicesStatus = .unavailable
            utilizationStatus = .unavailable
            thermalStatus = .unavailable
            temperatureStatus = .unavailable
            capabilities = [
                CapabilityRow(id: "gpu-devices", title: "GPU devices", status: .unavailable, reason: reason),
                CapabilityRow(id: "gpu-memory", title: "GPU memory", status: .unavailable, reason: reason),
                CapabilityRow(id: "gpu-utilization", title: "GPU utilization", status: .unavailable, reason: reason),
                CapabilityRow(id: "thermal-state", title: "Thermal state", status: .unavailable, reason: reason),
                CapabilityRow(id: "cpu-temperature", title: "CPU temperature", status: .unavailable, reason: reason),
            ]
        }
        thermalOverview = thermal.map { Readout(visible: $0.title, spoken: $0.spokenText) }
    }

    private static func row(_ id: String, _ title: String, _ capability: MetricCapability) -> CapabilityRow {
        switch capability {
        case .supported:
            CapabilityRow(id: id, title: title, status: .supported, reason: nil)
        case let .permissionRestricted(reason):
            CapabilityRow(id: id, title: title, status: .permissionRestricted, reason: reason)
        case let .unavailable(reason):
            CapabilityRow(id: id, title: title, status: .unavailable, reason: reason)
        }
    }

    private static func temperatureReadout(_ celsius: Double) -> Readout {
        let whole = Int(celsius.rounded())
        return Readout(visible: "\(whole) °C", spoken: "\(whole) degrees Celsius")
    }
}

extension Presented {
    /// Transforms the value, keeping the reason of an unavailable reading.
    func map<Output: Equatable & Sendable>(_ transform: (Value) -> Output) -> Presented<Output> {
        switch self {
        case let .available(value):
            .available(transform(value))
        case let .unavailable(reason):
            .unavailable(reason)
        }
    }
}
