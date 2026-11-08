import Foundation
import Testing
@testable import MacFleetKit

@Suite("App preferences: values and validation")
struct AppPreferencesValueTests {
    @Test func theDefaultsAreTheRatesTheAppUsedBeforeAndASaferRemoteRate() {
        let defaults = AppPreferences.default
        #expect(defaults.menuBarMetrics == [.cpu, .memory, .network])
        #expect(defaults.backgroundSeconds == 10)
        #expect(defaults.popoverSeconds == 2)
        #expect(defaults.processesSeconds == 2)
        #expect(defaults.remoteSeconds == 10)
    }

    @Test func everyKindOffersItsDefaultInAnAscendingListOfPositiveRates() {
        for kind in RefreshKind.allCases {
            #expect(kind.allowedSeconds.contains(kind.defaultSeconds), "\(kind)")
            #expect(kind.allowedSeconds == kind.allowedSeconds.sorted(), "\(kind)")
            #expect(kind.allowedSeconds.allSatisfy { $0 >= 1 }, "\(kind)")
        }
    }

    /// The energy policy in code: background sampling never runs faster than every 5 seconds, and the popover never
    /// samples slower than every 5 seconds, so an open popover always reads fresh values.
    @Test func theRateLimitsKeepBackgroundWorkLowAndTheOpenPopoverFresh() {
        #expect((RefreshKind.background.allowedSeconds.min() ?? 0) >= 5)
        #expect((RefreshKind.popover.allowedSeconds.max() ?? 0) <= 5)
    }

    @Test func aRateOutsideItsKindIsRefusedAndChangesNothing() {
        var prefs = AppPreferences.default
        let tooFast = prefs.setSeconds(3, for: .popover)
        #expect(tooFast == false)
        #expect(prefs.popoverSeconds == 2)
        let wrongKind = prefs.setSeconds(30, for: .popover)
        #expect(wrongKind == false)
        #expect(prefs.popoverSeconds == 2)
        let allowed = prefs.setSeconds(30, for: .background)
        #expect(allowed)
        #expect(prefs.backgroundSeconds == 30)
    }

    @Test func aRateOutsideItsListFallsBackToTheDefaultWhenCreated() {
        let prefs = AppPreferences(backgroundSeconds: 7, popoverSeconds: 60, processesSeconds: 0, remoteSeconds: 5)
        #expect(prefs.backgroundSeconds == 10)
        #expect(prefs.popoverSeconds == 2)
        #expect(prefs.processesSeconds == 2)
        #expect(prefs.remoteSeconds == 5)
    }

    @Test func menuBarMetricsKeepTheirOrderHaveNoDuplicatesAndCanBeEmptied() {
        var prefs = AppPreferences.default
        prefs.setMenuBarMetric(.disk, shown: true)
        #expect(prefs.menuBarMetrics == [.cpu, .memory, .network, .disk])
        prefs.setMenuBarMetric(.cpu, shown: false)
        #expect(prefs.menuBarMetrics == [.memory, .network, .disk])
        prefs.setMenuBarMetric(.memory, shown: true)
        #expect(prefs.menuBarMetrics == [.memory, .network, .disk])
        for metric in MenuBarMetric.allCases {
            prefs.setMenuBarMetric(metric, shown: false)
        }
        #expect(prefs.menuBarMetrics.isEmpty)
    }

    @Test func eachIntervalFollowsTheChosenRate() {
        var prefs = AppPreferences.default
        #expect(prefs.interval(for: .popover) == SamplingInterval.interactive)
        #expect(prefs.interval(for: .background) == SamplingInterval.background)
        prefs.setSeconds(60, for: .background)
        #expect(prefs.interval(for: .background).seconds == 60)
        prefs.setSeconds(5, for: .remote)
        #expect(prefs.interval(for: .remote).seconds == 5)
    }
}

@Suite("App preferences: encoding and loading")
struct AppPreferencesCodingTests {
    @Test func aPreferenceRoundTripsThroughJSON() throws {
        var prefs = AppPreferences.default
        prefs.setMenuBarMetric(.disk, shown: true)
        prefs.setSeconds(60, for: .background)
        prefs.setSeconds(5, for: .processes)
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(decoded == prefs)
    }

    @Test func aFileWithOnlySomeFieldsLoadsWithDefaultsForTheRest() throws {
        let data = Data(#"{"popoverSeconds": 5}"#.utf8)
        let loaded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(loaded.popoverSeconds == 5)
        #expect(loaded.backgroundSeconds == AppPreferences.default.backgroundSeconds)
        #expect(loaded.menuBarMetrics == AppPreferences.default.menuBarMetrics)
    }

    @Test func unknownMetricsAreDroppedAndInvalidRatesFallBackWhenLoaded() throws {
        let data = Data(#"{"menuBarMetrics": ["cpu", "gpu"], "backgroundSeconds": 3}"#.utf8)
        let loaded = try JSONDecoder().decode(AppPreferences.self, from: data)
        #expect(loaded.menuBarMetrics == [.cpu])
        #expect(loaded.backgroundSeconds == AppPreferences.default.backgroundSeconds)
    }
}

@Suite("App preferences: storage")
struct AppPreferencesStorageTests {
    private func withSuite(_ body: (String) throws -> Void) rethrows {
        let suite = "MacFleetTests.preferences.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        try body(suite)
    }

    @Test func nothingSavedLoadsAsNil() throws {
        try withSuite { suite in
            let loaded = try UserDefaultsPreferencesStore(suiteName: suite).load()
            #expect(loaded == nil)
        }
    }

    @Test func savedPreferencesPersistAcrossStoreInstances() throws {
        try withSuite { suite in
            var prefs = AppPreferences.default
            prefs.setSeconds(30, for: .background)
            try UserDefaultsPreferencesStore(suiteName: suite).save(prefs)
            let loaded = try UserDefaultsPreferencesStore(suiteName: suite).load()
            #expect(loaded == prefs)
        }
    }

    @Test func damagedDataIsMovedAsideNotDeleted() throws {
        try withSuite { suite in
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(Data("not settings".utf8), forKey: UserDefaultsPreferencesStore.key)
            let store = UserDefaultsPreferencesStore(suiteName: suite)
            do {
                _ = try store.load()
                Issue.record("damaged settings must not load")
            } catch PreferencesStoreError.damaged(let aside) {
                #expect(aside.hasPrefix(UserDefaultsPreferencesStore.key + ".damaged."))
                #expect(defaults.data(forKey: aside) == Data("not settings".utf8))
                #expect(defaults.data(forKey: UserDefaultsPreferencesStore.key) == nil)
            }
        }
    }

    @Test func aMemoryStoreRefusesSavesWhileTheFailureIsSet() throws {
        let store = MemoryPreferencesStore()
        store.setSaveFailure(CocoaError(.fileWriteNoPermission))
        #expect(throws: CocoaError.self) {
            try store.save(.default)
        }
        let afterRefusal = try store.load()
        #expect(afterRefusal == nil)
        store.setSaveFailure(nil)
        try store.save(.default)
        let afterSave = try store.load()
        #expect(afterSave == .default)
    }
}

@Suite("Launch at login: states and changes")
struct LaunchAtLoginStateTests {
    @Test func enablingAndDisablingChangesTheStatus() throws {
        let launch = MemoryLaunchAtLogin()
        #expect(launch.status() == .notRegistered)
        try launch.setEnabled(true)
        #expect(launch.status() == .enabled)
        try launch.setEnabled(false)
        #expect(launch.status() == .notRegistered)
    }

    @Test func approvalModeLeavesTheItemWaitingForTheUser() throws {
        let launch = MemoryLaunchAtLogin(requiresApproval: true)
        try launch.setEnabled(true)
        #expect(launch.status() == .requiresApproval)
    }

    @Test func aRefusalIsReportedAndLeavesTheStatusAlone() {
        let launch = MemoryLaunchAtLogin(refusal: "Blocked by a policy")
        #expect(throws: LaunchAtLoginError.refused("Blocked by a policy")) {
            try launch.setEnabled(true)
        }
        #expect(launch.status() == .notRegistered)
        #expect(LaunchAtLoginError.refused("Blocked by a policy").errorDescription == "Blocked by a policy")
    }

    @Test func openingLoginItemsSettingsIsCounted() {
        let launch = MemoryLaunchAtLogin()
        launch.openLoginItemsSettings()
        launch.openLoginItemsSettings()
        #expect(launch.openRequestCount == 2)
    }
}
