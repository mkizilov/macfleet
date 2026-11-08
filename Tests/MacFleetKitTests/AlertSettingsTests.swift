import Foundation
import Testing
import UserNotifications
@testable import MacFleetKit

@Suite("Alert settings values")
struct AlertSettingsValueTests {
    @Test func everyMetricHasADefaultInsideItsRange() {
        for metric in AlertMetric.allCases {
            let rule = AlertRule.defaults(for: metric)
            #expect(metric.thresholdRange.contains(rule.threshold))
            #expect(rule.isEnabled)
            #expect(AlertSettings().rule(for: metric) == rule)
        }
    }

    @Test func outOfRangeValuesAreClampedWhenSet() {
        var settings = AlertSettings()
        settings.setRule(
            AlertRule(isEnabled: true, threshold: 500, sustainedSeconds: -4, cooldownSeconds: 5),
            for: .highCPU
        )
        let rule = settings.rule(for: .highCPU)
        #expect(rule.threshold == 100)
        #expect(rule.sustainedSeconds == 0)
        #expect(rule.cooldownSeconds == 60)
    }

    @Test func aValueThatIsNotFiniteFallsBackToItsDefault() {
        var settings = AlertSettings()
        settings.setRule(
            AlertRule(isEnabled: true, threshold: .nan, sustainedSeconds: .infinity, cooldownSeconds: -.infinity),
            for: .lowDiskSpace
        )
        let rule = settings.rule(for: .lowDiskSpace)
        #expect(rule.threshold == AlertMetric.lowDiskSpace.defaultThreshold)
        #expect(rule.sustainedSeconds == AlertRule.defaultSustainedSeconds)
        #expect(rule.cooldownSeconds == AlertRule.defaultCooldownSeconds)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        var settings = AlertSettings()
        settings.setRule(
            AlertRule(isEnabled: false, threshold: 75, sustainedSeconds: 120, cooldownSeconds: 1_800),
            for: .lowDiskSpace
        )
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AlertSettings.self, from: data) == settings)
    }

    @Test func aFileMissingAMetricFillsItWithDefaults() throws {
        let json = #"{"highCPU":{"isEnabled":false,"threshold":80,"sustainedSeconds":10,"cooldownSeconds":600}}"#
        let settings = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        #expect(settings.rule(for: .highCPU).isEnabled == false)
        #expect(settings.rule(for: .highCPU).threshold == 80)
        #expect(settings.rule(for: .thermalPressure) == AlertRule.defaults(for: .thermalPressure))
    }

    @Test func unknownMetricNamesAreIgnored() throws {
        let json = #"{"gpuTemperature":{"isEnabled":true,"threshold":1,"sustainedSeconds":1,"cooldownSeconds":60}}"#
        let settings = try JSONDecoder().decode(AlertSettings.self, from: Data(json.utf8))
        #expect(settings == AlertSettings())
    }

    @Test func damagedDataThrowsInsteadOfDecodingSilently() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AlertSettings.self, from: Data("not json".utf8))
        }
    }
}

/// A throwaway defaults suite. Each test removes its suite when it ends, so no preference outlives the test.
private func makeSuiteName() -> String {
    "MacFleetTests.alerts.\(UUID().uuidString)"
}

private func removeSuite(_ suite: String) {
    UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
}

@Suite("Alert settings persistence")
struct AlertSettingsStoreTests {
    @Test func savedSettingsLoadAgainFromTheSameSuite() throws {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }
        var settings = AlertSettings()
        settings.setRule(
            AlertRule(isEnabled: true, threshold: 95, sustainedSeconds: 60, cooldownSeconds: 900),
            for: .highCPU
        )
        let store = UserDefaultsAlertSettingsStore(suiteName: suite)
        try store.save(settings)
        #expect(try store.load() == settings)
    }

    @Test func nothingSavedLoadsAsNil() throws {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }
        #expect(try UserDefaultsAlertSettingsStore(suiteName: suite).load() == nil)
    }

    @Test func damagedStoredDataSurfacesAsAnError() throws {
        let suite = makeSuiteName()
        defer { removeSuite(suite) }
        let store = UserDefaultsAlertSettingsStore(suiteName: suite)
        UserDefaults(suiteName: suite)?.set(Data("damaged".utf8), forKey: UserDefaultsAlertSettingsStore.key)
        #expect(throws: DecodingError.self) {
            try store.load()
        }
    }
}

@Suite("Notification permission mapping")
struct NotificationPermissionMappingTests {
    @Test func everySystemStatusMapsToOneOfThreeStates() {
        #expect(UserNotificationAlertNotifier.permission(from: .authorized) == .authorized)
        #expect(UserNotificationAlertNotifier.permission(from: .provisional) == .authorized)
        #expect(UserNotificationAlertNotifier.permission(from: .denied) == .denied)
        #expect(UserNotificationAlertNotifier.permission(from: .notDetermined) == .notDetermined)
    }
}
