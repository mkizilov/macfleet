import MacFleetKit
import MacFleetState
import SwiftUI

/// The popover body. Collapsed shows an overview; expanded adds graphs, per-core load, storage, network,
/// the system summary, and the monitored-sources toggles.
public struct DashboardContentView: View {
    private let dashboard: DashboardPresentation
    private let isExpanded: Bool
    private let onSetVolumeMonitored: @Sendable (String, Bool) -> Void
    private let onSetInterfaceMonitored: @Sendable (String, Bool) -> Void
    private let history: HistoryCardPresentation
    private let onSelectHistoryRange: @Sendable (HistoryRange) -> Void

    public init(
        dashboard: DashboardPresentation,
        isExpanded: Bool,
        history: HistoryCardPresentation,
        onSetVolumeMonitored: @escaping @Sendable (String, Bool) -> Void,
        onSetInterfaceMonitored: @escaping @Sendable (String, Bool) -> Void,
        onSelectHistoryRange: @escaping @Sendable (HistoryRange) -> Void
    ) {
        self.dashboard = dashboard
        self.isExpanded = isExpanded
        self.history = history
        self.onSetVolumeMonitored = onSetVolumeMonitored
        self.onSetInterfaceMonitored = onSetInterfaceMonitored
        self.onSelectHistoryRange = onSelectHistoryRange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OverviewCard(dashboard: dashboard)
            if isExpanded {
                CPUCard(cpu: dashboard.cpu)
                MemoryCard(memory: dashboard.memory)
                StorageCard(storage: dashboard.storage)
                NetworkCard(network: dashboard.network)
                HistoryCard(history: history, onSelectRange: onSelectHistoryRange)
                SummaryCard(summary: dashboard.summary)
                SourcesSection(
                    sources: dashboard.sources,
                    onSetVolumeMonitored: onSetVolumeMonitored,
                    onSetInterfaceMonitored: onSetInterfaceMonitored
                )
            }
        }
    }
}

private struct OverviewCard: View {
    let dashboard: DashboardPresentation

    var body: some View {
        SectionCard("Overview") {
            UsageGauge(title: "CPU", usage: dashboard.cpu.total)
            UsageGauge(title: "Memory", usage: dashboard.memory.usage)
            UsageGauge(title: "Disk", usage: dashboard.storage.primaryUsage)
            ReadoutRow(label: "Download", value: dashboard.network.download)
            ReadoutRow(label: "Upload", value: dashboard.network.upload)
        }
    }
}
