import MacFleetKit
import MacFleetState
import SwiftUI

/// Every change the history window can ask for. The app forwards each one to the main-actor model.
public struct FleetHistoryActions: Sendable {
    public let onRange: @Sendable (HistoryRange) -> Void
    public let onSelect: @Sendable (HistoryHostID, Bool) -> Void
    public let onExport: @Sendable () -> Void
    public let onDelete: @Sendable (HistoryHostID) -> Void
    public let onRetention: @Sendable (HistoryHostID, Int, Int, Int) -> Void
    public let onDefaultRetention: @Sendable (HistoryHostID) -> Void
    public let onAlertEnabled: @Sendable (HistoryHostID, AlertMetric, Bool) -> Void
    public let onAlertThreshold: @Sendable (HistoryHostID, AlertMetric, Double) -> Void
    public let onAlertSustained: @Sendable (HistoryHostID, AlertMetric, Double) -> Void
    public let onAlertCooldown: @Sendable (HistoryHostID, AlertMetric, Double) -> Void
    public let onResetAlerts: @Sendable (HistoryHostID) -> Void
    public let onRequestNotifications: @Sendable () -> Void

    public init(
        onRange: @escaping @Sendable (HistoryRange) -> Void,
        onSelect: @escaping @Sendable (HistoryHostID, Bool) -> Void,
        onExport: @escaping @Sendable () -> Void,
        onDelete: @escaping @Sendable (HistoryHostID) -> Void,
        onRetention: @escaping @Sendable (HistoryHostID, Int, Int, Int) -> Void,
        onDefaultRetention: @escaping @Sendable (HistoryHostID) -> Void,
        onAlertEnabled: @escaping @Sendable (HistoryHostID, AlertMetric, Bool) -> Void,
        onAlertThreshold: @escaping @Sendable (HistoryHostID, AlertMetric, Double) -> Void,
        onAlertSustained: @escaping @Sendable (HistoryHostID, AlertMetric, Double) -> Void,
        onAlertCooldown: @escaping @Sendable (HistoryHostID, AlertMetric, Double) -> Void,
        onResetAlerts: @escaping @Sendable (HistoryHostID) -> Void,
        onRequestNotifications: @escaping @Sendable () -> Void
    ) {
        self.onRange = onRange
        self.onSelect = onSelect
        self.onExport = onExport
        self.onDelete = onDelete
        self.onRetention = onRetention
        self.onDefaultRetention = onDefaultRetention
        self.onAlertEnabled = onAlertEnabled
        self.onAlertThreshold = onAlertThreshold
        self.onAlertSustained = onAlertSustained
        self.onAlertCooldown = onAlertCooldown
        self.onResetAlerts = onResetAlerts
        self.onRequestNotifications = onRequestNotifications
    }
}

/// The multi-Mac history window: which Macs are shown, a comparison, totals, one chart set per Mac, retention and alert
/// settings for the first Mac selected, and CSV export. It takes presentation values and actions only.
public struct FleetHistoryView: View {
    private static let sustainedChoices: [Double] = [0, 30, 60, 300]
    private static let cooldownChoices: [Double] = [300, 900, 1_800, 3_600]

    private let presentation: FleetHistoryPresentation
    private let actions: FleetHistoryActions

    public init(presentation: FleetHistoryPresentation, actions: FleetHistoryActions) {
        self.presentation = presentation
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("History")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Picker("History range", selection: Binding(get: { presentation.range }, set: actions.onRange)) {
                    ForEach(HistoryRange.allCases, id: \.self) { range in
                        Text(range.pickerTitle).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(presentation.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notice = presentation.notice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                macsCard
                aggregateCard
                comparisonCard
                ForEach(presentation.sections) { section in
                    hostCard(section)
                }
                if let retention = presentation.retention {
                    retentionCard(retention)
                }
                if let alerts = presentation.alerts, let host = presentation.alertsHost {
                    alertsCard(alerts, host: host)
                }
                exportCard
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 720)
    }

    private var macsCard: some View {
        SectionCard("Macs") {
            ForEach(presentation.choices) { choice in
                Toggle(isOn: Binding(get: { choice.isSelected }, set: { actions.onSelect(choice.id, $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(choice.label)
                        Text(choice.samples == 0 ? "No history in this range" : "\(choice.samples) snapshots in this range")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Compare up to \(FleetHistoryModel.maximumCompared) Macs. Each Mac's history is kept and charted on its own.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var aggregateCard: some View {
        SectionCard("All Macs") {
            Text(presentation.aggregate.coverage)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(presentation.aggregate.lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var comparisonCard: some View {
        SectionCard("Side by side") {
            if presentation.comparison.isEmpty {
                Text("Select Macs above to compare them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["Mac", "Snapshots", "CPU avg", "CPU peak", "Memory avg", "Download avg", "Disk avg", "Newest"], id: \.self) { heading in
                            Text(heading)
                                .font(.caption2.weight(.semibold))
                        }
                    }
                    ForEach(presentation.comparison) { row in
                        GridRow {
                            Text(row.title).font(.caption)
                            Text("\(row.samples)").font(.caption.monospacedDigit())
                            Text(row.cpuAverage).font(.caption.monospacedDigit())
                            Text(row.cpuPeak).font(.caption.monospacedDigit())
                            Text(row.memoryAverage).font(.caption.monospacedDigit())
                            Text(row.downloadAverage).font(.caption.monospacedDigit())
                            Text(row.diskAverage).font(.caption.monospacedDigit())
                            Text(row.lastSample).font(.caption)
                        }
                    }
                }
                ForEach(presentation.comparison.filter { $0.clockNote != nil }) { row in
                    Label("\(row.title): \(row.clockNote ?? "")", systemImage: "clock.badge.exclamationmark")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func hostCard(_ section: HostHistorySection) -> some View {
        SectionCard(section.title) {
            if !section.hasData {
                Text("No history for this Mac in this range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(section.charts, id: \.title) { chart in
                VStack(alignment: .leading, spacing: 2) {
                    Text(chart.title)
                        .font(.caption.weight(.semibold))
                    SparklineChart(chart: chart)
                }
            }
        }
    }

    private func retentionCard(_ policy: RetentionPresentation) -> some View {
        SectionCard("Retention for \(policy.title)") {
            Text(policy.isDefault ? "Using the default retention." : "Using a retention set for this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(
                value: Binding(get: { policy.rawHours }, set: { actions.onRetention(policy.host, $0, policy.fiveMinuteDays, policy.hourlyDays) }),
                in: 2...72
            ) {
                Text("Full detail: \(policy.rawHours) hours")
            }
            Stepper(
                value: Binding(get: { policy.fiveMinuteDays }, set: { actions.onRetention(policy.host, policy.rawHours, $0, policy.hourlyDays) }),
                in: 2...30
            ) {
                Text("Five-minute summaries: \(policy.fiveMinuteDays) days")
            }
            Stepper(
                value: Binding(get: { policy.hourlyDays }, set: { actions.onRetention(policy.host, policy.rawHours, policy.fiveMinuteDays, $0) }),
                in: 8...365
            ) {
                Text("Hourly summaries: \(policy.hourlyDays) days")
            }
            Text(policy.minimumsText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                if !policy.isDefault {
                    Button("Use Default") { actions.onDefaultRetention(policy.host) }
                }
                Spacer()
                Button("Delete Stored History", role: .destructive) { actions.onDelete(policy.host) }
            }
        }
    }

    private func alertsCard(_ alerts: AlertSettingsPresentation, host: HistoryHostID) -> some View {
        SectionCard("Alerts for this Mac") {
            if let notice = alerts.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if alerts.notifications.canRequest {
                Button("Allow Notifications", action: actions.onRequestNotifications)
            }
            Text(alerts.notifications.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(alerts.rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(row.title, isOn: Binding(get: { row.isEnabled }, set: { actions.onAlertEnabled(host, row.metric, $0) }))
                    if row.isEnabled {
                        Stepper(
                            value: Binding(get: { row.threshold }, set: { actions.onAlertThreshold(host, row.metric, $0) }),
                            in: row.thresholdRange,
                            step: row.thresholdStep
                        ) {
                            Text(row.thresholdLabel)
                                .font(.caption)
                        }
                        Text(row.sustainedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Menu("Timing") {
                            ForEach(Self.sustainedChoices, id: \.self) { seconds in
                                Button("Sustain for \(Self.label(seconds))") { actions.onAlertSustained(host, row.metric, seconds) }
                            }
                            Divider()
                            ForEach(Self.cooldownChoices, id: \.self) { seconds in
                                Button("Notify at most every \(Self.label(seconds))") { actions.onAlertCooldown(host, row.metric, seconds) }
                            }
                        }
                        .fixedSize()
                        Text(row.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let last = row.lastAlertText {
                            Text(last)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text(row.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Restore Defaults for This Mac") { actions.onResetAlerts(host) }
            }
        }
    }

    private var exportCard: some View {
        SectionCard("Export") {
            Text("Saves one CSV row per Mac, time bucket, and metric for the range shown. An empty value means no reading, never zero.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Export CSV…", action: actions.onExport)
            }
        }
    }

    private static func label(_ seconds: Double) -> String {
        switch seconds {
        case 0: "immediately"
        case 30: "30 seconds"
        case 60: "1 minute"
        case 300: "5 minutes"
        case 900: "15 minutes"
        case 1_800: "30 minutes"
        case 3_600: "1 hour"
        default: "\(Int(seconds)) seconds"
        }
    }
}
