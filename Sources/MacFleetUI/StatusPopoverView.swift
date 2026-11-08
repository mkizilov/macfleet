import AppKit
import MacFleetState
import SwiftUI

/// Menu bar popover. Reads presentation values from the model and forwards actions back to it.
public struct StatusPopoverView: View {
    private let model: FleetStatusModel
    private let onShowProcesses: () -> Void
    private let onShowAlerts: () -> Void
    private let onShowFleet: () -> Void
    private let onShowHistory: () -> Void

    public init(
        model: FleetStatusModel,
        onShowProcesses: @escaping () -> Void,
        onShowAlerts: @escaping () -> Void,
        onShowFleet: @escaping () -> Void,
        onShowHistory: @escaping () -> Void
    ) {
        self.model = model
        self.onShowProcesses = onShowProcesses
        self.onShowAlerts = onShowAlerts
        self.onShowFleet = onShowFleet
        self.onShowHistory = onShowHistory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let dashboard = model.dashboard {
                ScrollView {
                    DashboardContentView(
                        dashboard: dashboard,
                        isExpanded: model.isShowingDetails,
                        history: model.historyCard,
                        onSetVolumeMonitored: { mountPoint, monitored in
                            Task { await model.setVolumeMonitored(mountPoint, monitored) }
                        },
                        onSetInterfaceMonitored: { name, monitored in
                            Task { await model.setInterfaceMonitored(name, monitored) }
                        },
                        onSelectHistoryRange: { range in
                            Task { await model.selectHistoryRange(range) }
                        }
                    )
                }
                .frame(maxHeight: model.isShowingDetails ? 600 : 360)
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
            footer
        }
        .padding()
        .frame(width: 360)
        .onAppear { Task { await model.popoverDidAppear() } }
        .onDisappear { Task { await model.popoverDidDisappear() } }
    }

    private var header: some View {
        HStack {
            Text("MacFleet")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            } else if let updated = model.dashboard?.summary.updatedText {
                Text(updated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(model.isShowingDetails ? "Show less" : "Show details") {
                Task { await model.setShowingDetails(!model.isShowingDetails) }
            }
            .accessibilityHint(model.isShowingDetails ? "Collapses the graphs and details" : "Expands the graphs and details")
            Spacer()
            Menu("Windows") {
                Button("Fleet", action: onShowFleet)
                Button("History", action: onShowHistory)
                Button("Processes", action: onShowProcesses)
                Button("Alerts", action: onShowAlerts)
            }
            .fixedSize()
            Button("Refresh") {
                Task { await model.refresh() }
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
