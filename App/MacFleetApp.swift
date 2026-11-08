import AppKit
import MacFleetKit
import MacFleetState
import MacFleetUI
import SwiftUI
import UniformTypeIdentifiers

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
                onShowFleet: { showWindow("fleet") },
                onShowHistory: { showWindow("history") }
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

        Window("History", id: "history") {
            if let history = appDelegate.history {
                FleetHistoryWindowContent(model: history)
            } else {
                Text("History is unavailable in this session.")
                    .padding()
            }
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

/// Connects the multi-Mac history window to its model. The model reloads while the window is open, and the loop ends
/// when the window closes. Each action runs on the main actor, where the model lives.
private struct FleetHistoryWindowContent: View {
    let model: FleetHistoryModel

    var body: some View {
        FleetHistoryView(
            presentation: model.presentation,
            actions: FleetHistoryActions(
                onRange: { range in Task { await model.setRange(range) } },
                onSelect: { host, isSelected in Task { await model.select(host, isSelected) } },
                onExport: { Task { @MainActor in await exportHistory(model) } },
                onDelete: { host in Task { await model.deleteHistory(for: host) } },
                onRetention: { host, raw, five, hourly in
                    Task { await model.setRetention(for: host, rawHours: raw, fiveMinuteDays: five, hourlyDays: hourly) }
                },
                onDefaultRetention: { host in Task { await model.useDefaultRetention(for: host) } },
                onAlertEnabled: { host, metric, isEnabled in
                    MainActor.assumeIsolated { model.setAlertEnabled(host, metric, isEnabled) }
                },
                onAlertThreshold: { host, metric, threshold in
                    MainActor.assumeIsolated { model.setAlertThreshold(host, metric, threshold) }
                },
                onAlertSustained: { host, metric, seconds in
                    MainActor.assumeIsolated { model.setAlertSustained(host, metric, seconds) }
                },
                onAlertCooldown: { host, metric, seconds in
                    MainActor.assumeIsolated { model.setAlertCooldown(host, metric, seconds) }
                },
                onResetAlerts: { host in MainActor.assumeIsolated { model.resetAlerts(for: host) } },
                onRequestNotifications: { Task { await model.requestNotifications() } }
            )
        )
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// Saves the selected Macs, or every Mac when none is selected, as CSV. A failure is shown in the window, not dropped.
@MainActor
private func exportHistory(_ model: FleetHistoryModel) async {
    let data: Data
    do {
        data = try await model.exportCSV()
    } catch {
        model.report("The history could not be exported. \(error.localizedDescription)")
        return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = "macfleet-history.csv"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        model.report("The export could not be written. \(error.localizedDescription)")
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
