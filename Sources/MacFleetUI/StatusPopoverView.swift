import AppKit
import MacFleetKit
import MacFleetState
import SwiftUI

public struct StatusPopoverView: View {
    private let model: FleetStatusModel

    public init(model: FleetStatusModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacFleet")
                .font(.headline)
            if let snapshot = model.snapshot {
                SystemSummaryView(snapshot: snapshot)
            } else {
                Text("No system data yet.")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider()
            HStack {
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 300)
        .task { await model.refresh() }
    }
}

private struct SystemSummaryView: View {
    let snapshot: SystemSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Host", value: snapshot.hostName)
            LabeledContent("OS", value: snapshot.operatingSystemVersion)
            LabeledContent("CPUs", value: "\(snapshot.activeProcessorCount)")
            LabeledContent(
                "Memory",
                value: Int64(snapshot.physicalMemoryBytes).formatted(.byteCount(style: .memory))
            )
            LabeledContent(
                "Uptime",
                value: Duration.seconds(snapshot.uptimeSeconds)
                    .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated))
            )
            LabeledContent(
                "Load (1m)",
                value: snapshot.loadAverage.oneMinute.formatted(.number.precision(.fractionLength(2)))
            )
        }
        .font(.callout)
    }
}
