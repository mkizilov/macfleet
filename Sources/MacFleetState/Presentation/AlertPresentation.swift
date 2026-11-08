import Foundation
import MacFleetKit

extension AlertMetric {
    public var title: String {
        switch self {
        case .highCPU: "High CPU use"
        case .memoryPressure: "Memory pressure"
        case .lowDiskSpace: "Low disk space"
        case .highNetwork: "High network use"
        case .thermalPressure: "Thermal pressure"
        }
    }

    /// Level names for the ordinal metrics, indexed by level. Empty for metrics measured in units.
    public var levelNames: [String] {
        switch self {
        case .memoryPressure: ["Normal", "Warning", "Critical"]
        case .thermalPressure: ["Nominal", "Fair", "Serious", "Critical"]
        case .highCPU, .lowDiskSpace, .highNetwork: []
        }
    }
}

/// Number and duration wording for alert messages and the settings screen.
enum AlertFormat {
    static func percent(_ value: Double) -> String {
        "\(String(format: "%.0f", value.rounded(.down)))%"
    }

    static func megabytesPerSecond(_ value: Double) -> String {
        "\(String(format: "%.0f", value.rounded(.down))) MB/s"
    }

    static func duration(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded(.down))
        return whole < 120 ? count(whole, "second") : count(whole / 60, "minute")
    }

    private static func count(_ value: Int, _ unit: String) -> String {
        value == 1 ? "1 \(unit)" : "\(value) \(unit)s"
    }
}

/// One alert as the settings screen shows it: its threshold, timing, and what it is doing now.
public struct AlertRowPresentation: Equatable, Sendable, Identifiable {
    public let metric: AlertMetric
    public let title: String
    public let isEnabled: Bool
    public let threshold: Double
    public let thresholdRange: ClosedRange<Double>
    public let thresholdStep: Double
    public let thresholdLabel: String
    public let sustainedSeconds: Double
    public let sustainedText: String
    public let cooldownSeconds: Double
    public let cooldownText: String
    public let statusText: String
    public let lastAlertText: String?

    public var id: AlertMetric {
        metric
    }

    public init(metric: AlertMetric, rule: AlertRule, status: AlertStatus, lastNotice: AlertNotice?) {
        self.metric = metric
        title = metric.title
        isEnabled = rule.isEnabled
        threshold = rule.threshold
        thresholdRange = metric.thresholdRange
        thresholdStep = metric.thresholdStep
        thresholdLabel = Self.thresholdLabel(metric, rule.threshold)
        sustainedSeconds = rule.sustainedSeconds
        sustainedText = rule.sustainedSeconds == 0
            ? "Alert on the first sample that meets the threshold"
            : "Alert once it lasts \(AlertFormat.duration(rule.sustainedSeconds))"
        cooldownSeconds = rule.cooldownSeconds
        cooldownText = "Notify at most once every \(AlertFormat.duration(rule.cooldownSeconds))"
        statusText = Self.statusText(
            enabled: rule.isEnabled,
            firing: status.firing[metric] ?? [],
            waiting: status.waiting.contains(metric)
        )
        lastAlertText = lastNotice.map {
            "Last alert \($0.firedAt.formatted(date: .omitted, time: .shortened)): \($0.message)"
        }
    }

    private static func thresholdLabel(_ metric: AlertMetric, _ value: Double) -> String {
        switch metric {
        case .highCPU:
            "Alert when CPU reaches \(AlertFormat.percent(value))"
        case .lowDiskSpace:
            "Alert when free space falls to \(AlertFormat.percent(value)) or less"
        case .highNetwork:
            "Alert when download and upload together reach \(AlertFormat.megabytesPerSecond(value))"
        case .memoryPressure, .thermalPressure:
            "Alert at \(metric.levelNames[Int(value)].lowercased()) or worse"
        }
    }

    private static func statusText(enabled: Bool, firing: [String], waiting: Bool) -> String {
        if !enabled {
            return "Off"
        }
        if !firing.isEmpty {
            return "Firing now: \(firing.joined(separator: ", "))"
        }
        return waiting ? "Condition present, waiting for it to last" : "Watching"
    }
}

/// Whether notifications may be posted, and what the user can do about it.
public struct NotificationStatusPresentation: Equatable, Sendable {
    public let text: String
    /// Only the explicit button asks the system, and only before the user has answered.
    public let canRequest: Bool

    public init(_ permission: NotificationPermission) {
        switch permission {
        case .notDetermined:
            text = "Notifications are not allowed yet. Allow them to hear about alerts while MacFleet runs in the background."
            canRequest = true
        case .denied:
            text = "Notifications are off for MacFleet. Turn them on in System Settings under Notifications."
            canRequest = false
        case .authorized:
            text = "Notifications are allowed for MacFleet."
            canRequest = false
        }
    }
}

/// Everything the alert settings screen shows.
public struct AlertSettingsPresentation: Equatable, Sendable {
    public let rows: [AlertRowPresentation]
    public let notifications: NotificationStatusPresentation
    /// A problem with saving, loading, or posting alerts. Nil when there is none.
    public let notice: String?

    public init(
        settings: AlertSettings,
        status: AlertStatus,
        lastNotices: [AlertMetric: AlertNotice],
        permission: NotificationPermission,
        notice: String?
    ) {
        rows = AlertMetric.allCases.map { metric in
            AlertRowPresentation(
                metric: metric,
                rule: settings.rule(for: metric),
                status: status,
                lastNotice: lastNotices[metric]
            )
        }
        notifications = NotificationStatusPresentation(permission)
        self.notice = notice
    }
}
