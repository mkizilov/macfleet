import Foundation
import MacFleetKit
import Observation

/// Drives the multi-Mac history window: which Macs are compared, the range, each Mac's data, retention, and export. The
/// history reads go to the store, which answers each Mac on its own, so one Mac's rows are never read for another.
@MainActor
@Observable
public final class FleetHistoryModel {
    /// The most Macs shown side by side. Each one adds a chart for every metric.
    public static let maximumCompared = 4
    /// The most rows an export is allowed to produce per Mac and metric, so a long range stays a manageable file.
    static let exportPointBudget = 1_000

    public private(set) var presentation: FleetHistoryPresentation
    public private(set) var range = HistoryRange.day
    public private(set) var selected: [HistoryHostID] = []
    /// The last action's problem. A successful read does not clear it.
    public private(set) var notice: String?

    private var loadError: String?
    private let store: any FleetHistoryStoring
    private let identities: @MainActor () -> [HistoryHostIdentity]
    private let hostAlerts: HostAlertCenter?
    private let now: @Sendable () -> Date
    private var current: [HistoryHostIdentity] = []
    private var series: [HistoryHostID: HistorySeries] = [:]
    private var summaries: [HistoryHostID: HostWindowSummary] = [:]
    private var clocks: [HistoryHostID: HostClockStatus] = [:]
    private var policies: [HistoryHostID: HistoryRetention?] = [:]

    public init(
        store: any FleetHistoryStoring,
        identities: @escaping @MainActor () -> [HistoryHostIdentity],
        hostAlerts: HostAlertCenter? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.identities = identities
        self.hostAlerts = hostAlerts
        self.now = now
        presentation = FleetHistoryPresentation(
            range: .day,
            now: now(),
            identities: [],
            selected: [],
            series: [:],
            summaries: [:],
            clocks: [:],
            focusRetention: nil,
            alerts: nil,
            notice: nil
        )
    }

    /// Reads every source's totals for the range, and the charts and policy of the Macs being compared.
    public func refresh() async {
        await hostAlerts?.refreshPermission()
        current = identities()
        selected = selected.filter { id in current.contains { $0.id == id } }
        do {
            let window = HistorySeries.window(range: range, now: now())
            let from = Date(timeIntervalSince1970: window.start)
            let to = Date(timeIntervalSince1970: window.end)
            var totals: [HistoryHostID: HostWindowSummary] = [:]
            var statuses: [HistoryHostID: HostClockStatus] = [:]
            for identity in current {
                totals[identity.id] = try await store.summary(host: identity.id, from: from, to: to)
                statuses[identity.id] = await store.clockStatus(host: identity.id)
            }
            summaries = totals
            clocks = statuses

            var charts: [HistoryHostID: HistorySeries] = [:]
            var policy: [HistoryHostID: HistoryRetention?] = [:]
            for id in selected {
                charts[id] = try await store.series(host: id, range: range, now: now())
                policy[id] = try await store.retention(for: id)
            }
            series = charts
            policies = policy
            loadError = nil
        } catch {
            loadError = "History could not be read. \(error.localizedDescription)"
        }
        rebuild()
    }

    public func setRange(_ newRange: HistoryRange) async {
        range = newRange
        await refresh()
    }

    /// Adds or removes a Mac from the comparison. At most `maximumCompared` Macs are compared at once.
    public func select(_ host: HistoryHostID, _ isSelected: Bool) async {
        if isSelected {
            guard !selected.contains(host) else { return }
            guard selected.count < Self.maximumCompared else {
                notice = "Compare up to \(Self.maximumCompared) Macs at once. Remove one from the comparison first."
                rebuild()
                return
            }
            selected.append(host)
        } else {
            selected.removeAll { $0 == host }
        }
        await refresh()
    }

    public func setRetention(for host: HistoryHostID, rawHours: Int, fiveMinuteDays: Int, hourlyDays: Int) async {
        do {
            let policy = try HistoryRetention(
                raw: TimeInterval(rawHours) * 3_600,
                fiveMinute: TimeInterval(fiveMinuteDays) * 86_400,
                hourly: TimeInterval(hourlyDays) * 86_400
            )
            try await store.setRetention(policy, for: host)
            notice = nil
        } catch {
            notice = "The retention could not be set. \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Returns a Mac to the default retention.
    public func useDefaultRetention(for host: HistoryHostID) async {
        do {
            try await store.setRetention(nil, for: host)
        } catch {
            notice = "The retention could not be reset. \(error.localizedDescription)"
        }
        await refresh()
    }

    /// Deletes a Mac's stored history. Its pairing and alert settings are kept.
    public func deleteHistory(for host: HistoryHostID) async {
        do {
            _ = try await store.removeHistory(for: host)
        } catch {
            notice = "The history could not be deleted. \(error.localizedDescription)"
        }
        await refresh()
    }

    public func setAlertEnabled(_ host: HistoryHostID, _ metric: AlertMetric, _ isEnabled: Bool) {
        hostAlerts?.setEnabled(host, metric, isEnabled)
        rebuild()
    }

    public func setAlertThreshold(_ host: HistoryHostID, _ metric: AlertMetric, _ threshold: Double) {
        hostAlerts?.setThreshold(host, metric, threshold)
        rebuild()
    }

    public func setAlertSustained(_ host: HistoryHostID, _ metric: AlertMetric, _ seconds: Double) {
        hostAlerts?.setSustainedSeconds(host, metric, seconds)
        rebuild()
    }

    public func setAlertCooldown(_ host: HistoryHostID, _ metric: AlertMetric, _ seconds: Double) {
        hostAlerts?.setCooldownSeconds(host, metric, seconds)
        rebuild()
    }

    public func resetAlerts(for host: HistoryHostID) {
        hostAlerts?.resetToDefaults(host)
        rebuild()
    }

    public func requestNotifications() async {
        await hostAlerts?.requestPermission()
        rebuild()
    }

    /// The CSV for the range shown: the selected Macs, or every Mac when none is selected. A bucket with no reading for a
    /// metric is an empty field, never zero.
    public func exportCSV() async throws -> Data {
        let window = HistorySeries.window(range: range, now: now())
        let hosts = selected.isEmpty ? current.map(\.id) : selected
        let rows = try await store.exportRows(
            hosts: hosts,
            from: Date(timeIntervalSince1970: window.start),
            to: Date(timeIntervalSince1970: window.end),
            maximumPoints: Self.exportPointBudget
        )
        let labels = Dictionary(current.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        return Data(HistoryCSV.render(rows, labels: labels).utf8)
    }

    /// Shows a problem that happened outside the model, such as a file that could not be written.
    public func report(_ message: String) {
        notice = message
        rebuild()
    }

    private func rebuild() {
        let focus = selected.first
        presentation = FleetHistoryPresentation(
            range: range,
            now: now(),
            identities: current,
            selected: selected,
            series: series,
            summaries: summaries,
            clocks: clocks,
            focusRetention: focus.flatMap { policies[$0] } ?? nil,
            alerts: focus.flatMap { hostAlerts?.presentation(for: $0) },
            notice: notice ?? loadError
        )
    }
}

