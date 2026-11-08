import MacFleetState
import SwiftUI

struct CPUCard: View {
    let cpu: CPUPresentation

    var body: some View {
        SectionCard("CPU") {
            UsageGauge(title: "Total", usage: cpu.total)
            SparklineChart(chart: cpu.history)
            CoreGrid(cores: cpu.cores)
        }
    }
}

private struct CoreGrid: View {
    let cores: Presented<[CoreUsage]>
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        switch cores {
        case let .available(items):
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(items) { core in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(core.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ProgressView(value: core.usage.fraction)
                            .tint(core.usage.level.tint)
                        Text(core.usage.text)
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(core.label)
                    .accessibilityValue(core.usage.spokenText)
                }
            }
        case let .unavailable(reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
