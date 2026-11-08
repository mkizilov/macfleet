import MacFleetState
import SwiftUI

struct StorageCard: View {
    let storage: StoragePresentation

    var body: some View {
        SectionCard("Disks") {
            switch storage.volumes {
            case let .available(rows):
                if rows.isEmpty {
                    Text("No browsable volumes are monitored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    VolumeRowView(row: row)
                }
            case let .unavailable(reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct VolumeRowView: View {
    let row: VolumeRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.name)
                    .font(.callout.weight(.medium))
                if let badge = row.badge {
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
            }
            switch row.capacity {
            case let .available(capacity):
                UsageGauge(title: "Used", usage: .available(capacity.usage))
                Text(capacity.free.visible)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(capacity.free.spoken)
            case let .unavailable(reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
