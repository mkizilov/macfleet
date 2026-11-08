import Foundation

/// A resource condition MacFleet can alert on. Thresholds use each metric's own unit: percent for CPU and free disk
/// space, megabytes per second for network, and an ordinal level for memory pressure and thermal state.
public enum AlertMetric: String, CaseIterable, Sendable {
    case highCPU
    case memoryPressure
    case lowDiskSpace
    case highNetwork
    case thermalPressure

    public var thresholdRange: ClosedRange<Double> {
        switch self {
        case .highCPU: 50...100
        case .memoryPressure: 1...2
        case .lowDiskSpace: 1...50
        case .highNetwork: 1...1_000
        case .thermalPressure: 1...3
        }
    }

    public var thresholdStep: Double {
        switch self {
        case .highCPU, .highNetwork: 5
        case .memoryPressure, .lowDiskSpace, .thermalPressure: 1
        }
    }

    public var defaultThreshold: Double {
        switch self {
        case .highCPU: 90
        case .memoryPressure: 2
        case .lowDiskSpace: 10
        case .highNetwork: 50
        case .thermalPressure: 2
        }
    }
}

/// The settings for one alert. The threshold starts the alert. The hysteresis band is fixed per metric in the alert
/// engine, so a reading that hovers near the threshold does not end an active alert.
public struct AlertRule: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var threshold: Double
    /// How long the condition must hold before the alert fires. Zero fires on the first sample that meets it.
    public var sustainedSeconds: Double
    /// The shortest time between two notifications for the same alert.
    public var cooldownSeconds: Double

    public static let sustainedRange: ClosedRange<Double> = 0...600
    public static let cooldownRange: ClosedRange<Double> = 60...3_600
    public static let defaultSustainedSeconds = 30.0
    public static let defaultCooldownSeconds = 900.0

    public init(isEnabled: Bool, threshold: Double, sustainedSeconds: Double, cooldownSeconds: Double) {
        self.isEnabled = isEnabled
        self.threshold = threshold
        self.sustainedSeconds = sustainedSeconds
        self.cooldownSeconds = cooldownSeconds
    }

    public static func defaults(for metric: AlertMetric) -> AlertRule {
        AlertRule(
            isEnabled: true,
            threshold: metric.defaultThreshold,
            sustainedSeconds: defaultSustainedSeconds,
            cooldownSeconds: defaultCooldownSeconds
        )
    }

    /// Settings arrive from a control or from disk, so every value is clamped into its range. A value that is not
    /// finite falls back to the default.
    func clamped(for metric: AlertMetric) -> AlertRule {
        AlertRule(
            isEnabled: isEnabled,
            threshold: Self.clamp(threshold, to: metric.thresholdRange, fallback: metric.defaultThreshold),
            sustainedSeconds: Self.clamp(sustainedSeconds, to: Self.sustainedRange, fallback: Self.defaultSustainedSeconds),
            cooldownSeconds: Self.clamp(cooldownSeconds, to: Self.cooldownRange, fallback: Self.defaultCooldownSeconds)
        )
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }
}

/// Alert preferences for every metric. A metric without a stored rule uses its defaults, so a newer build can add
/// metrics to an older file.
public struct AlertSettings: Equatable, Sendable {
    private var rules: [AlertMetric: AlertRule]

    public init(rules: [AlertMetric: AlertRule] = [:]) {
        var complete: [AlertMetric: AlertRule] = [:]
        for metric in AlertMetric.allCases {
            complete[metric] = (rules[metric] ?? .defaults(for: metric)).clamped(for: metric)
        }
        self.rules = complete
    }

    public func rule(for metric: AlertMetric) -> AlertRule {
        rules[metric] ?? .defaults(for: metric)
    }

    public mutating func setRule(_ rule: AlertRule, for metric: AlertMetric) {
        rules[metric] = rule.clamped(for: metric)
    }
}

extension AlertSettings: Codable {
    public init(from decoder: any Decoder) throws {
        let stored = try decoder.singleValueContainer().decode([String: AlertRule].self)
        var decoded: [AlertMetric: AlertRule] = [:]
        for (name, rule) in stored {
            if let metric = AlertMetric(rawValue: name) {
                decoded[metric] = rule
            }
        }
        self.init(rules: decoded)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: rules.map { ($0.key.rawValue, $0.value) }))
    }
}

/// Saves and loads alert preferences. `load` returns nil when nothing has been saved yet, and throws when saved data
/// cannot be read, so the caller can say so instead of using defaults silently.
public protocol AlertSettingsStoring: Sendable {
    func load() throws -> AlertSettings?
    func save(_ settings: AlertSettings) throws
}

/// Keeps alert preferences in user defaults, as one encoded value. `UserDefaults` is not `Sendable`, so the store keeps
/// only the suite name and resolves the defaults on each call. A nil suite name means the app's standard defaults.
public struct UserDefaultsAlertSettingsStore: AlertSettingsStoring {
    public static let key = "MacFleet.alertSettings"

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() throws -> AlertSettings? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try JSONDecoder().decode(AlertSettings.self, from: data)
    }

    public func save(_ settings: AlertSettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
    }
}
