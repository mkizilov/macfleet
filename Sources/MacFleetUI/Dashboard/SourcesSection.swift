import MacFleetState
import SwiftUI

/// Toggles for each discovered volume and interface. Toggle state comes from the presentation, which the
/// model rebuilds as soon as a toggle changes.
struct SourcesSection: View {
    let sources: SourcesPresentation
    let onSetVolumeMonitored: @Sendable (String, Bool) -> Void
    let onSetInterfaceMonitored: @Sendable (String, Bool) -> Void

    var body: some View {
        DisclosureGroup("Monitored sources") {
            VStack(alignment: .leading, spacing: 8) {
                switch sources.volumes {
                case let .available(items):
                    ForEach(items) { item in
                        SourceToggle(item: item) { monitored in
                            onSetVolumeMonitored(item.id, monitored)
                        }
                    }
                case let .unavailable(reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switch sources.interfaces {
                case let .available(items):
                    ForEach(items) { item in
                        SourceToggle(item: item) { monitored in
                            onSetInterfaceMonitored(item.id, monitored)
                        }
                    }
                case let .unavailable(reason):
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }
}

private struct SourceToggle: View {
    let item: SourceItem
    let onChange: @Sendable (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { item.monitored }, set: onChange)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }
}
