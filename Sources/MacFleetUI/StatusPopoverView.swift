import AppKit
import MacFleetState
import SwiftUI

/// Menu bar popover. Reads presentation values from the model and forwards actions back to it.
public struct StatusPopoverView: View {
    private let model: FleetStatusModel

    public init(model: FleetStatusModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let dashboard = model.dashboard {
                ScrollView {
                    DashboardContentView(
                        dashboard: dashboard,
                        isExpanded: model.isShowingDetails,
                        onSetVolumeMonitored: { mountPoint, monitored in
                            Task { await model.setVolumeMonitored(mountPoint, monitored) }
                        },
                        onSetInterfaceMonitored: { name, monitored in
                            Task { await model.setInterfaceMonitored(name, monitored) }
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
        .task { await model.refresh() }
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
                model.isShowingDetails.toggle()
            }
            .accessibilityHint(model.isShowingDetails ? "Collapses the graphs and details" : "Expands the graphs and details")
            Spacer()
            Button("Refresh") {
                Task { await model.refresh() }
            }
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
