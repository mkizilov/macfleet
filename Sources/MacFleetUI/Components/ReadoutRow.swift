import MacFleetState
import SwiftUI

/// Label and value. The visible value is short; VoiceOver speaks the full wording.
struct ReadoutRow: View {
    let label: String
    let value: Presented<Readout>

    var body: some View {
        LabeledContent {
            switch value {
            case let .available(readout):
                Text(readout.visible)
                    .monospacedDigit()
                    .accessibilityLabel(readout.spoken)
            case let .unavailable(reason):
                Text(reason)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(label)
        }
        .font(.callout)
    }
}

/// Symbol plus label, so severity never depends on color alone.
struct LevelBadge: View {
    let title: String
    let level: UsageLevel

    var body: some View {
        Label(title, systemImage: level.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(level.tint)
    }
}
