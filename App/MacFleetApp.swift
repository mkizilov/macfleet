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
            StatusPopoverView(
                model: appDelegate.model,
                onShowProcesses: { showWindow("processes") },
                onShowAlerts: { showWindow("alerts") },
                onShowFleet: { showWindow("fleet") }
            )
        } label: {
            MenuBarLabelView(presentation: appDelegate.model.dashboard?.menuBar)
                .task { await appDelegate.model.runSampling(every: .background) }
        }
        .menuBarExtraStyle(.window)

        Window("Processes", id: "processes") {
            ProcessWindowContent(model: appDelegate.processes)
        }

        Window("Alert Settings", id: "alerts") {
            AlertSettingsWindowContent(model: appDelegate.alerts)
        }

        Window("Fleet", id: "fleet") {
            FleetWindowContent(model: appDelegate.fleet)
        }
    }

    private func showWindow(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate()
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

/// Connects the fleet window to its model. Each action runs on the main actor, where the model lives.
private struct FleetWindowContent: View {
    let model: FleetOverviewModel

    var body: some View {
        FleetOverviewView(
            presentation: model.presentation,
            onField: { field, value in MainActor.assumeIsolated { model.setDraft(field, value) } },
            onCheck: { MainActor.assumeIsolated { model.beginPairing() } },
            onConfirm: { MainActor.assumeIsolated { model.confirmPairing() } },
            onCancel: { MainActor.assumeIsolated { model.cancelPairing() } },
            onAction: { id, action in
                MainActor.assumeIsolated {
                    switch action {
                    case .reconnect: model.retry(id)
                    case .trustAgain: model.beginTrustAgain(id)
                    case .remove: model.remove(id)
                    }
                }
            }
        )
    }
}

/// Connects the alert settings window to its model. The permission is read again when the window opens, because the
/// user may have changed it in System Settings since.
private struct AlertSettingsWindowContent: View {
    let model: AlertCenterModel

    var body: some View {
        AlertSettingsView(
            presentation: model.presentation,
            onEnabled: { metric, enabled in MainActor.assumeIsolated { model.setEnabled(metric, enabled) } },
            onThreshold: { metric, value in MainActor.assumeIsolated { model.setThreshold(metric, value) } },
            onSustained: { metric, seconds in MainActor.assumeIsolated { model.setSustainedSeconds(metric, seconds) } },
            onCooldown: { metric, seconds in MainActor.assumeIsolated { model.setCooldownSeconds(metric, seconds) } },
            onRequestPermission: { Task { await model.requestPermission() } },
            onReset: { MainActor.assumeIsolated { model.resetToDefaults() } }
        )
        .onAppear { Task { await model.refreshPermission() } }
    }
}
