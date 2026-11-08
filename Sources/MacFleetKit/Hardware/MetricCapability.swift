import Foundation

/// What this Mac can report for one measurement, decided from documented public APIs and the macOS version.
/// It is separate from a reading. A supported measurement can still fail on one sample, and the reading says why.
public enum MetricCapability: Codable, Equatable, Sendable {
    /// Reported on this Mac. A single sample can still fail.
    case supported
    /// Reported only after the user grants access. The reason says what to grant.
    case permissionRestricted(reason: String)
    /// Not reported on this Mac, so no sample is taken. The reason says why.
    case unavailable(reason: String)

    /// The capability after one sample. A failed read can show a restriction that the declared capability did not
    /// show. A transient failure keeps the declared capability, and the reading explains it.
    static func observed<Value>(_ declared: MetricCapability, reading: MetricReading<Value>) -> MetricCapability {
        guard case .supported = declared, case let .unavailable(issue) = reading else { return declared }
        switch issue {
        case .permissionDenied, .permissionRestricted:
            return .permissionRestricted(reason: issue.errorDescription ?? "Permission is required.")
        case .unsupported:
            return .unavailable(reason: issue.errorDescription ?? "Not available on this Mac.")
        default:
            return declared
        }
    }

    /// The capability implied by a failed enumeration. Transient failures count as supported, as in `observed`.
    static func classify(_ issue: MetricIssue) -> MetricCapability {
        let reason = issue.errorDescription ?? "Not available on this Mac."
        switch issue {
        case .permissionDenied, .permissionRestricted:
            return .permissionRestricted(reason: reason)
        case .unsupported:
            return .unavailable(reason: reason)
        default:
            return .supported
        }
    }
}

/// The capability of each hardware measurement on this Mac.
public struct HardwareCapabilities: Codable, Equatable, Sendable {
    public let gpuDevices: MetricCapability
    public let gpuMemory: MetricCapability
    public let gpuUtilization: MetricCapability
    public let thermalState: MetricCapability
    public let cpuTemperature: MetricCapability

    public init(
        gpuDevices: MetricCapability,
        gpuMemory: MetricCapability,
        gpuUtilization: MetricCapability,
        thermalState: MetricCapability,
        cpuTemperature: MetricCapability
    ) {
        self.gpuDevices = gpuDevices
        self.gpuMemory = gpuMemory
        self.gpuUtilization = gpuUtilization
        self.thermalState = thermalState
        self.cpuTemperature = cpuTemperature
    }
}

/// Why a measurement is missing when no public API provides it. Shown to the user as written.
public enum HardwareReasons {
    public static let gpuUtilization =
        "macOS has no public API for system-wide GPU utilization. Metal counters measure only work submitted by this app."
    public static let cpuTemperature =
        "macOS has no public API for CPU temperature. Thermal sensors are not exposed through documented interfaces."
    public static let noGPU = "No Metal GPU device is reported by this Mac."
    public static let noMemoryLimit = "Metal reports no memory limit for this GPU."
}
