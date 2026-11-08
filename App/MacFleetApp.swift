import AppKit
import MacFleetKit
import MacFleetState
import MacFleetUI
import SwiftUI

@main
struct MacFleetApp: App {
    @NSApplicationDelegateAdaptor(MacFleetAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(model: appDelegate.model) {
                openWindow(id: "processes")
                NSApplication.shared.activate()
            }
        } label: {
            MenuBarLabelView(presentation: appDelegate.model.dashboard?.menuBar)
                .task { await appDelegate.model.runSampling(every: .background) }
        }
        .menuBarExtraStyle(.window)

        Window("Processes", id: "processes") {
            ProcessWindowContent(model: appDelegate.processes)
        }
    }
}

/// Connects the process window to its model. The model samples only while this view is on screen.
private struct ProcessWindowContent: View {
    let model: ProcessMonitorModel

    var body: some View {
        // SwiftUI delivers binding updates on the main actor. Applying them synchronously keeps the search field from
        // reverting a keystroke while the model catches up.
        ProcessMonitorView(
            presentation: model.presentation,
            searchText: model.searchText,
            onSearch: { text in MainActor.assumeIsolated { model.setSearchText(text) } },
            onSort: { key in MainActor.assumeIsolated { model.setSort(key) } },
            onMode: { mode in MainActor.assumeIsolated { model.setMode(mode) } }
        )
        .onAppear { model.processesDidAppear() }
        .onDisappear { Task { await model.processesDidDisappear() } }
    }
}
