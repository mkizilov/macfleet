import MacFleetState
import SwiftUI

/// Linear capacity gauge with a visible percentage and a spoken value and severity.
struct UsageGauge: View {
    let title: String
    let usage: Presented<UsageValue>

    var body: some View {
        switch usage {
        case let .available(value):
            Gauge(value: value.fraction, in: 0...1) {
                Text(title)
            } currentValueLabel: {
                Text(value.text)
                    .monospacedDigit()
            }
            .gaugeStyle(.linearCapacity)
            .tint(value.level.tint)
            .accessibilityLabel(title)
            .accessibilityValue("\(value.spokenText), \(value.level.title)")
        case let .unavailable(reason):
            UnavailableText(title: title, reason: reason)
        }
    }
}

struct UnavailableText: View {
    let title: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
