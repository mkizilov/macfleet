import Foundation
import MacFleetKit
import MacFleetState
import Testing

/// Records every value the settings model pushes to the app.
@MainActor
final class SettingsChangeLog {
    private(set) var values: [AppPreferences] = []

    func record(_ value: AppPreferences) {
        values.append(value)
    }
}

/// A store whose saved data is damaged, as after a failed write or a hand edit.
private struct SettingsDamagedStore: PreferencesStoring {
    func load() throws -> AppPreferences? {
        throw PreferencesStoreError.damaged(movedAside: "MacFleet.preferences.damaged.1")
    }

    func save(_ preferences: AppPreferences) throws {}
}

@MainActor
private func settingsModel(
    store: any PreferencesStoring = MemoryPreferencesStore(),
    launch: any LaunchAtLoginControlling = MemoryLaunchAtLogin(),
    log: SettingsChangeLog = SettingsChangeLog()
) -> PreferencesModel {
    PreferencesModel(store: store, launchAtLogin: launch) { log.record($0) }
}

@MainActor
@Suite("Settings flows: menu bar and refresh rates")
struct SettingsMenuBarAndRateFlowTests {
    @Test func aMenuBarChoiceIsSavedAppliedAndShownInThePane() {
        let log = SettingsChangeLog()
        let model = settingsModel(log: log)
        model.setMenuBarMetric(.disk, shown: true)
        #expect(model.preferences.menuBarMetrics.contains(.disk))
        #expect(model.presentation.menuBarOptions.first { $0.metric == .disk }?.isShown == true)
        #expect(log.values.last?.menuBarMetrics.contains(.disk) == true)
    }

    @Test func hidingEveryMetricSaysOnlyTheIconIsShown() {
        let model = settingsModel()
        for metric in MenuBarMetric.allCases {
            model.setMenuBarMetric(metric, shown: false)
        }
        #expect(model.presentation.menuBarSummary == "Only the icon is shown. The values stay available in the popover.")
    }

    @Test func aRateChangeIsAppliedAndARateOutsideItsListPushesNothing() {
        let log = SettingsChangeLog()
        let model = settingsModel(log: log)
        let before = log.values.count
        model.setRefresh(.processes, seconds: 5)
        #expect(model.preferences.processesSeconds == 5)
        #expect(log.values.count == before + 1)
        model.setRefresh(.processes, seconds: 3)
        #expect(model.preferences.processesSeconds == 5)
        #expect(log.values.count == before + 1)
    }

    @Test func eachRefreshRowOffersItsListAndShowsTheSavedRate() {
        let model = settingsModel()
        model.setRefresh(.remote, seconds: 30)
        let remote = model.presentation.refreshRows.first { $0.kind == .remote }
        #expect(remote?.selectedSeconds == 30)
        #expect(remote?.choices.map(\.seconds) == [5, 10, 30])
        let background = model.presentation.refreshRows.first { $0.kind == .background }
        #expect(background?.choices.map(\.title) == ["5 seconds", "10 seconds", "30 seconds", "1 minute"])
    }

    @Test func resetRestoresTheDefaultsAndTheButtonIsOffWhenTheyAreAlreadyInUse() {
        let model = settingsModel()
        #expect(model.presentation.isDefault)
        model.setRefresh(.background, seconds: 60)
        #expect(model.presentation.isDefault == false)
        model.resetToDefaults()
        #expect(model.preferences == .default)
        #expect(model.presentation.isDefault)
    }
}

@MainActor
@Suite("Settings flows: saving and loading")
struct SettingsSavingFlowTests {
    @Test func changesPersistAcrossLaunches() {
        let store = MemoryPreferencesStore()
        let first = settingsModel(store: store)
        first.setRefresh(.background, seconds: 30)
        first.setMenuBarMetric(.cpu, shown: false)
        let second = settingsModel(store: store)
        #expect(second.preferences == first.preferences)
        #expect(second.presentation.menuBarOptions.first { $0.metric == .cpu }?.isShown == false)
    }

    @Test func aFailedSaveKeepsTheNewValueAndSaysSo() {
        let store = MemoryPreferencesStore()
        let model = settingsModel(store: store)
        store.setSaveFailure(CocoaError(.fileWriteNoPermission))
        model.setRefresh(.popover, seconds: 5)
        #expect(model.preferences.popoverSeconds == 5)
        #expect(model.saveNotice?.contains("apply until the app quits") == true)
        #expect(model.presentation.saveNotice == model.saveNotice)
        store.setSaveFailure(nil)
        model.setRefresh(.popover, seconds: 1)
        #expect(model.saveNotice == nil)
    }

    @Test func damagedSavedSettingsStartFromDefaultsAndSayWhy() {
        let log = SettingsChangeLog()
        let model = settingsModel(store: SettingsDamagedStore(), log: log)
        #expect(model.preferences == .default)
        #expect(model.loadNotice?.contains("MacFleet.preferences.damaged.1") == true)
        #expect(model.presentation.loadNotice == model.loadNotice)
        #expect(log.values.first == .default)
    }
}

@MainActor
@Suite("Settings flows: startup at login")
struct SettingsLaunchAtLoginFlowTests {
    @Test func theToggleFollowsWhatTheSystemDid() {
        let model = settingsModel(launch: MemoryLaunchAtLogin())
        #expect(model.presentation.launch.isOn == false)
        model.setLaunchAtLogin(true)
        #expect(model.launchStatus == .enabled)
        #expect(model.presentation.launch.isOn)
        #expect(model.presentation.launch.statusText == "On. MacFleet opens when you log in.")
        model.setLaunchAtLogin(false)
        #expect(model.presentation.launch.isOn == false)
        #expect(model.launchNotice == nil)
    }

    @Test func anApprovalNeededIsExplainedAndLinksToLoginItems() {
        let launch = MemoryLaunchAtLogin(requiresApproval: true)
        let model = settingsModel(launch: launch)
        model.setLaunchAtLogin(true)
        #expect(model.presentation.launch.showsLoginItemsLink)
        #expect(model.presentation.launch.statusText.hasPrefix("Waiting for approval"))
        model.openLoginItemsSettings()
        #expect(launch.openRequestCount == 1)
    }

    @Test func aRefusalIsShownAndTheToggleKeepsTheRealState() {
        let model = settingsModel(launch: MemoryLaunchAtLogin(refusal: "Blocked by a policy"))
        model.setLaunchAtLogin(true)
        #expect(model.launchNotice?.contains("Blocked by a policy") == true)
        #expect(model.presentation.launch.isOn == false)
        #expect(model.presentation.launchNotice == model.launchNotice)
    }

    @Test func aBuildWithoutABundleCannotChangeTheLoginItem() {
        let model = settingsModel(launch: MemoryLaunchAtLogin(status: .notFound))
        #expect(model.presentation.launch.canChange == false)
        model.setLaunchAtLogin(true)
        #expect(model.launchStatus == .notFound)
        #expect(model.launchNotice == "Launch at login is available in the installed app.")
    }
}

@MainActor
@Suite("Settings navigation")
struct SettingsNavigationFlowTests {
    @Test func everyCommandHasItsOwnKeyAndNoneUsesCommandComma() {
        let keys = AppCommand.allCases.map(\.key)
        #expect(Set(keys).count == AppCommand.allCases.count)
        #expect(keys.contains(",") == false)
    }

    @Test func eachCommandLeadsWhereItSaysItDoes() {
        #expect(AppCommand.refresh.destination == .refresh)
        #expect(AppCommand.fleet.destination == .window(.fleet))
        #expect(AppCommand.history.destination == .window(.history))
        #expect(AppCommand.processes.destination == .window(.processes))
        #expect(AppCommand.notifications.destination == .settings(.notifications))
    }

    @Test func everyWindowCanBeReachedByACommand() {
        let reached = AppCommand.allCases.compactMap { command -> AppWindow? in
            if case let .window(window) = command.destination { window } else { nil }
        }
        #expect(Set(reached) == Set(AppWindow.allCases))
    }

    @Test func showingAPaneSelectsItInTheWindow() {
        let model = settingsModel()
        #expect(model.pane == .general)
        model.show(.notifications)
        #expect(model.pane == .notifications)
        #expect(model.presentation.pane == .notifications)
    }
}

@MainActor
@Suite("Settings wording and accessibility")
struct SettingsWordingTests {
    @Test func everyRefreshRowHasHelpAndItsChoicesHaveDistinctNames() {
        for row in settingsModel().presentation.refreshRows {
            #expect(row.help.isEmpty == false, "\(row.kind)")
            let titles = row.choices.map(\.title)
            #expect(Set(titles).count == titles.count, "\(row.kind)")
            #expect(row.choices.map(\.seconds).contains(row.selectedSeconds), "\(row.kind)")
        }
    }

    @Test func everyLaunchStateSaysWhatItMeans() {
        let states: [LaunchAtLoginStatus] = [.enabled, .notRegistered, .requiresApproval, .notFound, .unknown]
        for state in states {
            let launch = settingsModel(launch: MemoryLaunchAtLogin(status: state)).presentation.launch
            #expect(launch.statusText.isEmpty == false, "\(state)")
            #expect(launch.helpText.isEmpty == false, "\(state)")
        }
    }

    @Test func theMenuBarSummaryNamesTheChosenMetricsInWords() {
        let model = settingsModel()
        model.setMenuBarMetric(.memory, shown: false)
        model.setMenuBarMetric(.network, shown: false)
        #expect(model.presentation.menuBarSummary == "Shows CPU in the menu bar.")
        model.setMenuBarMetric(.network, shown: true)
        #expect(model.presentation.menuBarSummary == "Shows CPU and Network in the menu bar.")
    }

    @Test func theEnergySummaryStatesTheRatesInUse() {
        let model = settingsModel()
        model.setRefresh(.popover, seconds: 5)
        #expect(model.presentation.energySummary.contains("every 5 seconds while it is open"))
        #expect(model.presentation.energySummary.contains("every 10 seconds while the popover is closed"))
    }
}
