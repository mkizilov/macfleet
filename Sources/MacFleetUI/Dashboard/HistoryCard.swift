import MacFleetKit
import MacFleetState
import SwiftUI

/// Last hour, day, or week of CPU, memory, network, and disk. The picker reloads the charts for the chosen range.
struct HistoryCard: View {
    let history: HistoryCardPresentation
    let onSelectRange: @Sendable (HistoryRange) -> Void

    var body: some View {
        SectionCard("History") {
            Picker("History range", selection: Binding(get: { history.range }, set: onSelectRange)) {
                ForEach(HistoryRange.allCases, id: \.self) { range in
                    Text(range.pickerTitle).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let notice = history.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch history.content {
        case .loading:
            ProgressView("Loading history")
                .controlSize(.small)
        case let .unavailable(reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .loaded(presentation):
            Text(presentation.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if !presentation.hasData {
                Text("No history recorded for this range yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(presentation.charts, id: \.title) { chart in
                VStack(alignment: .leading, spacing: 2) {
                    Text(chart.title)
                        .font(.caption.weight(.semibold))
                    SparklineChart(chart: chart)
                }
            }
        }
    }
}
