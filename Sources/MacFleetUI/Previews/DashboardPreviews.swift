import MacFleetKit
import MacFleetState
import SwiftUI

/// Realistic data for previews, built synchronously from the simulated timeline. No system monitoring runs.
enum DashboardPreviewData {
    static func dashboard(seed: UInt64 = 7, steps: Int = 90) -> DashboardPresentation {
        var timeline = SimulatedMetricsTimeline(seed: seed)
        var history = MetricHistory()
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        var snapshot = timeline.nextSnapshot(selection: .default, capturedAt: start)
        history.record(snapshot)
        for step in 1..<max(steps, 2) {
            let capturedAt = start.addingTimeInterval(Double(step) * SimulatedMetricsTimeline.stepSeconds)
            snapshot = timeline.nextSnapshot(selection: .default, capturedAt: capturedAt)
            history.record(snapshot)
        }
        return DashboardPresentation(snapshot: snapshot, history: history, selection: .default)
    }

    static func history(range: HistoryRange = .day) -> HistoryCardPresentation {
        let series = MockHistorySource.makeSeries(range: range, now: Date(timeIntervalSince1970: 1_767_225_600))
        return HistoryCardPresentation(range: range, content: .loaded(HistoryPresentation(series: series)), notice: nil)
    }
}

struct DashboardPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            DashboardContentView(
                dashboard: DashboardPreviewData.dashboard(),
                isExpanded: true,
                history: DashboardPreviewData.history(),
                onSetVolumeMonitored: { _, _ in },
                onSetInterfaceMonitored: { _, _ in },
                onSelectHistoryRange: { _ in }
            )
            .padding()
            .frame(width: 360)
            .previewDisplayName("Expanded, light")

            DashboardContentView(
                dashboard: DashboardPreviewData.dashboard(),
                isExpanded: true,
                history: DashboardPreviewData.history(range: .week),
                onSetVolumeMonitored: { _, _ in },
                onSetInterfaceMonitored: { _, _ in },
                onSelectHistoryRange: { _ in }
            )
            .padding()
            .frame(width: 360)
            .preferredColorScheme(.dark)
            .previewDisplayName("Expanded, dark, week history")

            DashboardContentView(
                dashboard: DashboardPreviewData.dashboard(seed: 11),
                isExpanded: false,
                history: DashboardPreviewData.history(range: .hour),
                onSetVolumeMonitored: { _, _ in },
                onSetInterfaceMonitored: { _, _ in },
                onSelectHistoryRange: { _ in }
            )
            .padding()
            .frame(width: 360)
            .previewDisplayName("Overview")

            MenuBarLabelView(presentation: DashboardPreviewData.dashboard().menuBar)
                .padding()
                .previewDisplayName("Menu bar")
        }
    }
}
