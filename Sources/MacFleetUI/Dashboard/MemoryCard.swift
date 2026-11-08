import MacFleetState
import SwiftUI

struct MemoryCard: View {
    let memory: MemoryPresentation

    var body: some View {
        SectionCard("Memory") {
            UsageGauge(title: "In use", usage: memory.usage)
            ReadoutRow(label: "Used", value: memory.used)
            ReadoutRow(label: "Available", value: memory.available)
            ReadoutRow(label: "Total", value: memory.total)
            PressureRow(pressure: memory.pressure)
            SparklineChart(chart: memory.history)
        }
    }
}

private struct PressureRow: View {
    let pressure: Presented<PressureBadge>

    var body: some View {
        LabeledContent {
            switch pressure {
            case let .available(badge):
                LevelBadge(title: badge.title, level: badge.level)
            case let .unavailable(reason):
                Text(reason)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text("Pressure")
        }
        .font(.callout)
    }
}
