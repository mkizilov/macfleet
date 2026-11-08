import Foundation
import MacFleetKit
import Observation

/// Alert settings and alert state for each remote Mac. Each Mac has its own thresholds, switches, sustained periods,
/// and cooldowns, and its own engine, so one Mac's readings never change another's alerts. Notices name the Mac they
/// concern. The local Mac keeps its settings in `AlertCenterModel`.
@MainActor
@Observable
public final class HostAlertCenter {
    public private(set) var notice: String?
    public private(set) var permission = NotificationPermission.notDetermined

    private var settings: [String: AlertSettings]
    private var engines: [String: AlertEngine] = [:]
    private var lastNotices: [String: [AlertMetric: AlertNotice]] = [:]
    private var presentations: [String: AlertSettingsPresentation] = [:]
    private let notifier: any AlertNotifying
    private let store: any HostAlertSettingsStoring

    public init(notifier: any AlertNotifying, store: any HostAlertSettingsStoring) {
        self.notifier = notifier
        self.store = store
        do {
            settings = try store.load()
        } catch {
            settings = [:]
            notice = "Saved alert settings for remote Macs could not be read, so their defaults are in use. \(error.localizedDescription)"
        }
    }

    /// The alert settings screen for one Mac. A Mac with no saved settings shows the defaults.
    public func presentation(for host: HistoryHostID) -> AlertSettingsPresentation {
        presentations[host.rawValue] ?? build(host)
    }

    public func refreshPermission() async {
        permission = await notifier.permission()
        rebuildAll()
    }

    /// Asks the user for permission. Call only from an explicit user action.
    public func requestPermission() async {
        do {
            permission = try await notifier.requestPermission()
        } catch {
            notice = "Notifications could not be requested. \(error.localizedDescription)"
        }
        rebuildAll()
    }

    public func setEnabled(_ host: HistoryHostID, _ metric: AlertMetric, _ isEnabled: Bool) {
        change(host, metric) { $0.isEnabled = isEnabled }
    }

    public func setThreshold(_ host: HistoryHostID, _ metric: AlertMetric, _ threshold: Double) {
        change(host, metric) { $0.threshold = threshold }
    }

    public func setSustainedSeconds(_ host: HistoryHostID, _ metric: AlertMetric, _ seconds: Double) {
        change(host, metric) { $0.sustainedSeconds = seconds }
    }

    public func setCooldownSeconds(_ host: HistoryHostID, _ metric: AlertMetric, _ seconds: Double) {
        change(host, metric) { $0.cooldownSeconds = seconds }
    }

    public func resetToDefaults(_ host: HistoryHostID) {
        settings[host.rawValue] = AlertSettings()
        engines[host.rawValue]?.apply(AlertSettings())
        persist()
        rebuild(host)
    }

    /// Forgets a Mac's settings, engine, and notices. Called when the Mac is removed.
    public func remove(_ host: HistoryHostID) {
        settings[host.rawValue] = nil
        engines[host.rawValue] = nil
        lastNotices[host.rawValue] = nil
        presentations[host.rawValue] = nil
        persist()
    }

    /// Evaluates one reading at the time this app received it, and posts a notification for each alert that fires.
    public func evaluate(host: HistoryHostID, label: String, snapshot: RemoteSnapshot, receivedAt: Date) {
        let key = host.rawValue
        var engine = engines[key] ?? AlertEngine(settings: settings[key] ?? AlertSettings())
        let notices = engine.evaluate(snapshot.withCapturedAt(receivedAt))
        engines[key] = engine
        for alert in notices {
            lastNotices[key, default: [:]][alert.key.metric] = alert
            post(host, label, alert)
        }
        rebuild(host)
    }

    private func change(_ host: HistoryHostID, _ metric: AlertMetric, _ edit: (inout AlertRule) -> Void) {
        var current = settings[host.rawValue] ?? AlertSettings()
        var rule = current.rule(for: metric)
        edit(&rule)
        current.setRule(rule, for: metric)
        settings[host.rawValue] = current
        engines[host.rawValue]?.apply(current)
        persist()
        rebuild(host)
    }

    private func persist() {
        do {
            try store.save(settings)
            notice = nil
        } catch {
            notice = "Alert settings for remote Macs could not be saved. \(error.localizedDescription)"
        }
        rebuildAll()
    }

    /// One notification per alert. The identifier is per Mac and alert, so a repeat replaces the earlier notice.
    private func post(_ host: HistoryHostID, _ label: String, _ alert: AlertNotice) {
        let notification = AlertNotification(
            identifier: "macfleet.host.\(host.rawValue).\(alert.key.metric.rawValue).\(alert.key.subject)",
            title: "\(label): \(alert.title)",
            body: alert.message
        )
        Task { [self] in
            let current = await notifier.permission()
            permission = current
            if current == .authorized {
                do {
                    try await notifier.deliver(notification)
                } catch {
                    notice = "An alert for \(label) could not be posted. \(error.localizedDescription)"
                }
            }
            rebuildAll()
        }
    }

    private func build(_ host: HistoryHostID) -> AlertSettingsPresentation {
        let key = host.rawValue
        return AlertSettingsPresentation(
            settings: settings[key] ?? AlertSettings(),
            status: engines[key]?.status ?? .idle,
            lastNotices: lastNotices[key] ?? [:],
            permission: permission,
            notice: notice
        )
    }

    private func rebuild(_ host: HistoryHostID) {
        presentations[host.rawValue] = build(host)
    }

    private func rebuildAll() {
        for key in Set(presentations.keys).union(settings.keys) {
            presentations[key] = build(HistoryHostID(rawValue: key))
        }
    }
}
