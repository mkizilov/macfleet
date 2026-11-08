import Foundation

/// A value the menu bar can show. Every one is read from the sample the app already takes, so showing more costs no
/// extra sampling.
public enum MenuBarMetric: String, Codable, CaseIterable, Sendable {
    case cpu
    case memory
    case network
    case disk

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        }
    }
}

/// Where sampling happens. Each kind offers a short list of rates, so no setting can spin the CPU or wait for hours.
public enum RefreshKind: String, Codable, CaseIterable, Sendable {
    /// Menu bar and alerts while the popover is closed.
    case background
    /// Values while the popover is open.
    case popover
    /// The process list, while its window is open.
    case processes
    /// Each registered remote Mac.
    case remote

    public var allowedSeconds: [Int] {
        switch self {
        case .background: [5, 10, 30, 60]
        case .popover: [1, 2, 5]
        case .processes: [2, 5, 10]
        case .remote: [5, 10, 30]
        }
    }

    /// The rate the app starts with. The background rate is the one the app used before rates were configurable.
    public var defaultSeconds: Int {
        switch self {
        case .background: 10
        case .popover: 2
        case .processes: 2
        case .remote: 10
        }
    }
}

/// The user's settings. Values are always valid: a rate outside its kind's list falls back to the default, and metrics are
/// kept in the order of `MenuBarMetric.allCases`.
public struct AppPreferences: Codable, Equatable, Sendable {
    public static let `default` = AppPreferences()

    /// Shown in the menu bar. Empty shows the icon alone.
    public private(set) var menuBarMetrics: [MenuBarMetric]
    public private(set) var backgroundSeconds: Int
    public private(set) var popoverSeconds: Int
    public private(set) var processesSeconds: Int
    public private(set) var remoteSeconds: Int

    public init(
        menuBarMetrics: [MenuBarMetric] = [.cpu, .memory, .network],
        backgroundSeconds: Int = RefreshKind.background.defaultSeconds,
        popoverSeconds: Int = RefreshKind.popover.defaultSeconds,
        processesSeconds: Int = RefreshKind.processes.defaultSeconds,
        remoteSeconds: Int = RefreshKind.remote.defaultSeconds
    ) {
        self.menuBarMetrics = MenuBarMetric.allCases.filter(menuBarMetrics.contains)
        self.backgroundSeconds = Self.validated(backgroundSeconds, for: .background)
        self.popoverSeconds = Self.validated(popoverSeconds, for: .popover)
        self.processesSeconds = Self.validated(processesSeconds, for: .processes)
        self.remoteSeconds = Self.validated(remoteSeconds, for: .remote)
    }

    public func seconds(for kind: RefreshKind) -> Int {
        switch kind {
        case .background: backgroundSeconds
        case .popover: popoverSeconds
        case .processes: processesSeconds
        case .remote: remoteSeconds
        }
    }

    /// The rate as a sampling interval. Every kind's list is above the sampling minimum, so no value is clamped here.
    public func interval(for kind: RefreshKind) -> SamplingInterval {
        SamplingInterval(seconds: Double(seconds(for: kind)))
    }

    public mutating func setMenuBarMetric(_ metric: MenuBarMetric, shown: Bool) {
        var metrics = Set(menuBarMetrics)
        if shown {
            metrics.insert(metric)
        } else {
            metrics.remove(metric)
        }
        menuBarMetrics = MenuBarMetric.allCases.filter(metrics.contains)
    }

    /// Returns false, and changes nothing, when the rate is not one the user can choose for this kind.
    @discardableResult
    public mutating func setSeconds(_ seconds: Int, for kind: RefreshKind) -> Bool {
        guard kind.allowedSeconds.contains(seconds) else { return false }
        switch kind {
        case .background: backgroundSeconds = seconds
        case .popover: popoverSeconds = seconds
        case .processes: processesSeconds = seconds
        case .remote: remoteSeconds = seconds
        }
        return true
    }

    private static func validated(_ seconds: Int, for kind: RefreshKind) -> Int {
        kind.allowedSeconds.contains(seconds) ? seconds : kind.defaultSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case menuBarMetrics, backgroundSeconds, popoverSeconds, processesSeconds, remoteSeconds
    }

    /// Missing or unknown values fall back to the defaults, so an older or edited file still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let savedNames = try container.decodeIfPresent([String].self, forKey: .menuBarMetrics)
        self.init(
            menuBarMetrics: savedNames.map { saved in MenuBarMetric.allCases.filter { saved.contains($0.rawValue) } }
                ?? AppPreferences.default.menuBarMetrics,
            backgroundSeconds: try container.decodeIfPresent(Int.self, forKey: .backgroundSeconds)
                ?? RefreshKind.background.defaultSeconds,
            popoverSeconds: try container.decodeIfPresent(Int.self, forKey: .popoverSeconds)
                ?? RefreshKind.popover.defaultSeconds,
            processesSeconds: try container.decodeIfPresent(Int.self, forKey: .processesSeconds)
                ?? RefreshKind.processes.defaultSeconds,
            remoteSeconds: try container.decodeIfPresent(Int.self, forKey: .remoteSeconds)
                ?? RefreshKind.remote.defaultSeconds
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(menuBarMetrics.map(\.rawValue), forKey: .menuBarMetrics)
        try container.encode(backgroundSeconds, forKey: .backgroundSeconds)
        try container.encode(popoverSeconds, forKey: .popoverSeconds)
        try container.encode(processesSeconds, forKey: .processesSeconds)
        try container.encode(remoteSeconds, forKey: .remoteSeconds)
    }
}
