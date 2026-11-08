import Foundation
import MacFleetKit
import Observation

/// Owns the alert settings, the engine that evaluates them, and what the settings screen shows. Every sample is
/// evaluated, including while the popover is closed. A settings change applies from the next sample and is saved at
/// once. Notifications are posted only while macOS allows them, and the permission is requested only by
/// `requestPermission`, which the settings screen calls from its button.
@MainActor
@Observable
public final class AlertCenterModel {
    public private(set) var settings: AlertSettings
    public private(set) var permission = NotificationPermission.notDetermined
    /// The last problem with loading, saving, or posting alerts, in plain words. Nil when there is none.
    public private(set) var notice: String?
    public private(set) var presentation: AlertSettingsPresentation

    private var engine: AlertEngine
    private var lastNotices: [AlertMetric: AlertNotice] = [:]
    private let notifier: any AlertNotifying
    private let store: any AlertSettingsStoring

    public init(notifier: any AlertNotifying, store: any AlertSettingsStoring) {
        self.notifier = notifier
        self.store = store
        var loaded = AlertSettings()
        var loadNotice: String?
        do {
            loaded = try store.load() ?? AlertSettings()
        } catch {
            loadNotice = "Saved alert settings could not be read, so the defaults are in use. \(error.localizedDescription)"
        }
        settings = loaded
        engine = AlertEngine(settings: loaded)
        notice = loadNotice
        presentation = AlertSettingsPresentation(
            settings: loaded,
            status: .idle,
            lastNotices: [:],
            permission: .notDetermined,
            notice: loadNotice
        )
    }

    /// Reads the permission without asking the user.
    public func refreshPermission() async {
        permission = await notifier.permission()
        rebuild()
    }

    /// Asks the user for permission. Call only from an explicit user action.
    public func requestPermission() async {
        do {
            permission = try await notifier.requestPermission()
        } catch {
            notice = "Notifications could not be requested. \(error.localizedDescription)"
        }
        rebuild()
    }

    public func setEnabled(_ metric: AlertMetric, _ isEnabled: Bool) {
        change(metric) { $0.isEnabled = isEnabled }
    }

    public func setThreshold(_ metric: AlertMetric, _ threshold: Double) {
        change(metric) { $0.threshold = threshold }
    }

    public func setSustainedSeconds(_ metric: AlertMetric, _ seconds: Double) {
        change(metric) { $0.sustainedSeconds = seconds }
    }

    public func setCooldownSeconds(_ metric: AlertMetric, _ seconds: Double) {
        change(metric) { $0.cooldownSeconds = seconds }
    }

    public func resetToDefaults() {
        settings = AlertSettings()
        applySettings()
    }

    /// Evaluates one sample. The status model calls this for every sample it applies.
    public func evaluate(_ snapshot: SystemSnapshot) {
        for alert in engine.evaluate(snapshot) {
            lastNotices[alert.key.metric] = alert
            post(alert)
        }
        rebuild()
    }

    private func change(_ metric: AlertMetric, _ edit: (inout AlertRule) -> Void) {
        var rule = settings.rule(for: metric)
        edit(&rule)
        settings.setRule(rule, for: metric)
        applySettings()
    }

    private func applySettings() {
        engine.apply(settings)
        do {
            try store.save(settings)
            notice = nil
        } catch {
            notice = "Alert settings could not be saved. \(error.localizedDescription)"
        }
        rebuild()
    }

    /// Posts one alert if the system allows it. The identifier replaces an earlier notice for the same alert, so a
    /// repeated alert does not stack notifications.
    private func post(_ alert: AlertNotice) {
        let notification = AlertNotification(
            identifier: "macfleet.\(alert.key.metric.rawValue).\(alert.key.subject)",
            title: alert.title,
            body: alert.message
        )
        Task {
            let current = await notifier.permission()
            permission = current
            if current == .authorized {
                do {
                    try await notifier.deliver(notification)
                } catch {
                    notice = "An alert could not be posted. \(error.localizedDescription)"
                }
            }
            rebuild()
        }
    }

    private func rebuild() {
        presentation = AlertSettingsPresentation(
            settings: settings,
            status: engine.status,
            lastNotices: lastNotices,
            permission: permission,
            notice: notice
        )
    }
}
