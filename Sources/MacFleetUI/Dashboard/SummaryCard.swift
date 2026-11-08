import MacFleetState
import SwiftUI

struct SummaryCard: View {
    let summary: SummaryPresentation

    var body: some View {
        SectionCard("System") {
            LabeledContent {
                Text(summary.hostName)
            } label: {
                Text("Host")
            }
            LabeledContent {
                Text(summary.operatingSystem)
            } label: {
                Text("Version")
            }
            LabeledContent {
                Text(summary.cpuCountText)
            } label: {
                Text("Processors")
            }
            ReadoutRow(label: "Uptime", value: .available(summary.uptime))
            ReadoutRow(label: "Load", value: .available(summary.load))
            Text(summary.updatedText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
