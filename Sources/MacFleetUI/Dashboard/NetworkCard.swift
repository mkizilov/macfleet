import MacFleetState
import SwiftUI

struct NetworkCard: View {
    let network: NetworkPresentation

    var body: some View {
        SectionCard("Network") {
            ReadoutRow(label: "Download", value: network.download)
            ReadoutRow(label: "Upload", value: network.upload)
            SparklineChart(chart: network.chart)
            HStack(spacing: 12) {
                Label("Download", systemImage: "arrow.down")
                    .foregroundStyle(ChartRole.download.color)
                Label("Upload", systemImage: "arrow.up")
                    .foregroundStyle(ChartRole.upload.color)
            }
            .font(.caption)
            switch network.interfaces {
            case let .available(rows):
                if rows.isEmpty {
                    Text("No active interfaces are monitored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    InterfaceRowView(row: row)
                }
            case let .unavailable(reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct InterfaceRowView: View {
    let row: InterfaceRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
                .font(.callout.weight(.medium))
            Text(row.address)
                .font(.caption)
                .foregroundStyle(.secondary)
            ReadoutRow(label: "Download", value: row.download)
            ReadoutRow(label: "Upload", value: row.upload)
            switch row.totals {
            case let .available(totals):
                Text(totals.visible)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(totals.spoken)
            case let .unavailable(reason):
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
