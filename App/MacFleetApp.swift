import MacFleetKit
import MacFleetUI
import SwiftUI

@main
struct MacFleetApp: App {
    @NSApplicationDelegateAdaptor(MacFleetAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(model: appDelegate.model)
        } label: {
            MenuBarLabelView(presentation: appDelegate.model.dashboard?.menuBar)
                .task { await appDelegate.model.runSampling(every: .background) }
        }
        .menuBarExtraStyle(.window)
    }
}
