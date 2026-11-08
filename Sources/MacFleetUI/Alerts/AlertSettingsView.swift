import MacFleetKit
import MacFleetState
import SwiftUI

/// The alert settings window. It takes presentation values and forwards each change, so it holds no state of its own.
/// Every alert shows its status in words, and a disabled alert keeps its values but cannot change them.
public struct AlertSettingsView: View {
    private let presentation: AlertSettingsPresentation
    private let onEnabled: @Sendable (AlertMetric, Bool) -> Void
    private let onThreshold: @Sendable (AlertMetric, Double) -> Void
    private let onSustained: @Sendable (AlertMetric, Double) -> Void
    private let onCooldown: @Sendable (AlertMetric, Double) -> Void
    private let onRequestPermission: @Sendable () -> Void
    private let onReset: @Sendable () -> Void

    public init(
        presentation: AlertSettingsPresentation,
        onEnabled: @escaping @Sendable (AlertMetric, Bool) -> Void,
        onThreshold: @escaping @Sendable (AlertMetric, Double) -> Void,
        onSustained: @escaping @Sendable (AlertMetric, Double) -> Void,
        onCooldown: @escaping @Sendable (AlertMetric, Double) -> Void,
        onRequestPermission: @escaping @Sendable () -> Void,
        onReset: @escaping @Sendable () -> Void
    ) {
        self.presentation = presentation
        self.onEnabled = onEnabled
        self.onThreshold = onThreshold
        self.onSustained = onSustained
        self.onCooldown = onCooldown
        self.onRequestPermission = onRequestPermission
        self.onReset = onReset
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Alerts")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                notificationCard
                if let notice = presentation.notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(presentation.rows) { row in
                    metricCard(row)
                }
                HStack {
                    Spacer()
                    Button("Restore Defaults", action: onReset)
                }
            }
            .padding()
        }
        .frame(minWidth: 440, minHeight: 520)
    }

    private var notificationCard: some View {
        SectionCard("Notifications") {
            Text(presentation.notifications.text)
                .font(.caption)
                .foregroundStyle(.secondary)
            if presentation.notifications.canRequest {
                Button("Allow Notifications", action: onRequestPermission)
            }
        }
    }

    private func metricCard(_ row: AlertRowPresentation) -> some View {
        let metric = row.metric
        let setEnabled = onEnabled
        let setThreshold = onThreshold
        let setSustained = onSustained
        let setCooldown = onCooldown
        return SectionCard(row.title) {
            Toggle("Enabled", isOn: flag(row.isEnabled) { setEnabled(metric, $0) })
            Text(row.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(
                value: number(row.threshold) { setThreshold(metric, $0) },
                in: row.thresholdRange,
                step: row.thresholdStep
            ) {
                Text(row.thresholdLabel)
            }
            .disabled(!row.isEnabled)
            Stepper(
                value: number(row.sustainedSeconds) { setSustained(metric, $0) },
                in: AlertRule.sustainedRange,
                step: 5
            ) {
                Text(row.sustainedText)
            }
            .disabled(!row.isEnabled)
            Stepper(
                value: number(row.cooldownSeconds) { setCooldown(metric, $0) },
                in: AlertRule.cooldownRange,
                step: 60
            ) {
                Text(row.cooldownText)
            }
            .disabled(!row.isEnabled)
            if let lastAlert = row.lastAlertText {
                Text(lastAlert)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func flag(_ value: Bool, _ change: @escaping @Sendable (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: change)
    }

    private func number(_ value: Double, _ change: @escaping @Sendable (Double) -> Void) -> Binding<Double> {
        Binding(get: { value }, set: change)
    }
}
