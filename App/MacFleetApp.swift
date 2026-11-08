import MacFleetKit
import MacFleetState
import MacFleetUI
import SwiftUI

@main
struct MacFleetApp: App {
    @State private var model = FleetStatusModel(
        provider: ProcessSystemMetricsProvider(),
        store: InMemorySnapshotStore()
    )

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(model: model)
        } label: {
            MenuBarLabelView(presentation: model.dashboard?.menuBar)
                .task { await model.runSampling(every: .seconds(2)) }
        }
        .menuBarExtraStyle(.window)
    }
}
