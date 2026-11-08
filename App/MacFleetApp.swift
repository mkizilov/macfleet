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
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        Group {
            MenuBarExtra {
                StatusPopoverView(
                    model: appDelegate.model,
                    onShowProcesses: { showWindow(.processes) },
                    onShowAlerts: { showSettings(.notifications) },
                    onShowFleet: { showWindow(.fleet) },
                    onShowHistory: { showWindow(.history) },
                    onShowSettings: { showSettings(.general) }
                )
            } label: {
                MenuBarLabelView(presentation: appDelegate.model.menuBarLabel)
                    // Restarts whenever the chosen rate changes, so the menu bar samples at exactly the saved rate.
                    .task(id: appDelegate.settings.preferences.backgroundSeconds) {
                        await appDelegate.model.runSampling(every: appDelegate.settings.preferences.interval(for: .background))
                    }
            }
            .menuBarExtraStyle(.window)

            Window("Processes", id: AppWindow.processes.id) {
                ProcessWindowContent(model: appDelegate.processes)
            }
            .defaultSize(width: 720, height: 560)

            Window("Fleet", id: AppWindow.fleet.id) {
                FleetWindowContent(model: appDelegate.fleet)
            }
            .defaultSize(width: 520, height: 720)

            Window("History", id: AppWindow.history.id) {
                if let history = appDelegate.history {
                    FleetHistoryWindowContent(model: history)
                } else {
                    Text("History is unavailable in this session.")
                        .padding()
                }
            }
            .defaultSize(width: 660, height: 760)

            Settings {
                SettingsWindowContent(settings: appDelegate.settings, alerts: appDelegate.alerts)
            }
        }
        .commands {
            CommandMenu("Navigate") {
                ForEach(AppCommand.allCases, id: \.self) { command in
                    Button(command.title) { run(command.destination) }
                        .keyboardShortcut(KeyEquivalent(command.key), modifiers: .command)
                }
            }
        }
    }

    private func run(_ destination: AppDestination) {
        switch destination {
        case .refresh:
            Task { await appDelegate.model.refresh() }
        case let .window(window):
            showWindow(window)
        case let .settings(pane):
            showSettings(pane)
        }
    }

    private func showWindow(_ window: AppWindow) {
        openWindow(id: window.id)
        NSApplication.shared.activate()
    }

    private func showSettings(_ pane: SettingsPane) {
        appDelegate.settings.show(pane)
        openSettings()
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
            },
            onGroup: { id, group in MainActor.assumeIsolated { model.setGroup(id, group) } }
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

/// The Settings window: General preferences, and the Notifications pane with the alert thresholds.
private struct SettingsWindowContent: View {
    let settings: PreferencesModel
    let alerts: AlertCenterModel

    var body: some View {
        SettingsView(
            presentation: settings.presentation,
            onMenuBar: { metric, shown in MainActor.assumeIsolated { settings.setMenuBarMetric(metric, shown: shown) } },
            onRefresh: { kind, seconds in MainActor.assumeIsolated { settings.setRefresh(kind, seconds: seconds) } },
            onLaunchAtLogin: { enabled in MainActor.assumeIsolated { settings.setLaunchAtLogin(enabled) } },
            onOpenLoginItems: { MainActor.assumeIsolated { settings.openLoginItemsSettings() } },
            onPane: { pane in MainActor.assumeIsolated { settings.show(pane) } },
            onReset: { MainActor.assumeIsolated { settings.resetToDefaults() } }
        ) {
            AlertSettingsPane(model: alerts)
        }
        .onAppear { MainActor.assumeIsolated { settings.refreshLaunchStatus() } }
    }
}

/// The notification thresholds. The permission is read again when the pane opens, because the user may have changed it
/// in System Settings since.
private struct AlertSettingsPane: View {
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
