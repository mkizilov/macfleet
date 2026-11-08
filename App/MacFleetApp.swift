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
        MenuBarExtra("MacFleet", systemImage: "server.rack") {
            StatusPopoverView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
