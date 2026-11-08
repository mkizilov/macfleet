import Foundation

/// A measurement a host can report. The raw values are the wire names, so they stay stable across Swift changes.
public enum RemoteMetric: String, Codable, CaseIterable, Sendable {
    case cpu
    case memory
    case memoryPressure
    case storage
    case network
    case thermal
    case loadAverage
}

/// Whether a host can report a measurement, and if not, why.
public enum RemoteCapabilityState: Codable, Equatable, Sendable {
    case supported
    /// No public interface reports the measurement on this Mac. The reason says why.
    case unavailable(reason: String)
    /// The measurement exists, but macOS does not let the host read it. The reason says what is refused.
    case permissionRestricted(reason: String)
}

public struct RemoteCapability: Codable, Equatable, Sendable {
    public let metric: RemoteMetric
    public let state: RemoteCapabilityState

    public init(metric: RemoteMetric, state: RemoteCapabilityState) {
        self.metric = metric
        self.state = state
    }
}

/// The metrics of one sample, in the wire form. It is a projection of `SystemSnapshot` with its own schema, so the
/// protocol does not change when the host's internal model does. Every value stays a reading, so a missing value
/// arrives with its reason and never as zero.
public struct RemoteSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let cpuTotal: MetricReading<Double>
    public let memory: MetricReading<MemoryUsage>
    public let memoryPressure: MetricReading<MemoryPressureLevel>
    public let storage: MetricReading<[VolumeMetrics]>
    public let network: MetricReading<[NetworkInterfaceMetrics]>
    public let thermal: MetricReading<ThermalState>
    public let loadAverage: MetricReading<LoadAverage>

    public init(
        capturedAt: Date,
        cpuTotal: MetricReading<Double>,
        memory: MetricReading<MemoryUsage>,
        memoryPressure: MetricReading<MemoryPressureLevel>,
        storage: MetricReading<[VolumeMetrics]>,
        network: MetricReading<[NetworkInterfaceMetrics]>,
        thermal: MetricReading<ThermalState>,
        loadAverage: MetricReading<LoadAverage>
    ) {
        self.capturedAt = capturedAt
        self.cpuTotal = cpuTotal
        self.memory = memory
        self.memoryPressure = memoryPressure
        self.storage = storage
        self.network = network
        self.thermal = thermal
        self.loadAverage = loadAverage
    }

    public init(system snapshot: SystemSnapshot) {
        capturedAt = snapshot.capturedAt
        switch snapshot.cpu {
        case let .available(cpu): cpuTotal = .available(cpu.total)
        case let .unavailable(issue): cpuTotal = .unavailable(issue)
        }
        memory = snapshot.memory
        memoryPressure = snapshot.memoryPressure
        storage = snapshot.volumes
        network = snapshot.network
        switch snapshot.hardware {
        case let .available(hardware): thermal = hardware.thermalState
        case let .unavailable(issue): thermal = .unavailable(issue)
        }
        loadAverage = .available(snapshot.loadAverage)
    }

    /// One capability per metric, in `RemoteMetric.allCases` order. A measurement is supported when this sample read it.
    public var capabilities: [RemoteCapability] {
        [
            RemoteCapability(metric: .cpu, state: Self.state(cpuTotal)),
            RemoteCapability(metric: .memory, state: Self.state(memory)),
            RemoteCapability(metric: .memoryPressure, state: Self.state(memoryPressure)),
            RemoteCapability(metric: .storage, state: Self.state(storage)),
            RemoteCapability(metric: .network, state: Self.state(network)),
            RemoteCapability(metric: .thermal, state: Self.state(thermal)),
            RemoteCapability(metric: .loadAverage, state: Self.state(loadAverage)),
        ]
    }

    private static func state<Value>(_ reading: MetricReading<Value>) -> RemoteCapabilityState {
        switch reading {
        case .available:
            .supported
        case let .unavailable(issue):
            if case let .permissionRestricted(reason) = issue {
                .permissionRestricted(reason: reason)
            } else {
                .unavailable(reason: issue.errorDescription ?? "Not available")
            }
        }
    }
}
