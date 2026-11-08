import Foundation

/// The system thermal state from `ProcessInfo`, a documented API available on every supported macOS version.
public enum ThermalState: String, Codable, Equatable, Sendable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    /// Nil for a state this build does not recognize. Such a state is reported as unavailable, not guessed.
    public init?(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: return nil
        }
    }
}
