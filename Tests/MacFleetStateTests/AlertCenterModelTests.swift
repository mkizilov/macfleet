import Foundation
import MacFleetKit
import MacFleetState
import Testing

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func cpuSnapshot(at seconds: Double, cpu: Double) -> SystemSnapshot {
    SystemSnapshot(
        capturedAt: epoch.addingTimeInterval(seconds),
        hostName: "test-mac",
        operatingSystemVersion: "test",
        activeProcessorCount: 8,
        physicalMemoryBytes: 1,
        uptimeSeconds: 1,
        loadAverage: LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0),
        cpu: .available(CPUUtilization(total: cpu, perCore: .unavailable(.notSampled)))
    )
}

/// Polls until the condition holds, so a test waits for a notification posted from a task.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Suite("Alert center: settings")
struct AlertCenterSettingsTests {
    @Test func settingsPersistAndLoadIntoANewModel() throws {
        let store = MemoryAlertSettingsStore()
        let first = AlertCenterModel(notifier: RecordingAlertNotifier(), store: store)
        first.setThreshold(.highCPU, 95)
        first.setEnabled(.highNetwork, false)

        let second = AlertCenterModel(notifier: RecordingAlertNotifier(), store: store)
        #expect(second.settings.rule(for: .highCPU).threshold == 95)
        #expect(second.settings.rule(for: .highNetwork).isEnabled == false)
        #expect(try store.load() == first.settings)
    }

    @Test func valuesAreClampedBeforeTheyAreSaved() throws {
        let store = MemoryAlertSettingsStore()
        let model = AlertCenterModel(notifier: RecordingAlertNotifier(), store: store)
        model.setThreshold(.highCPU, 500)
        model.setCooldownSeconds(.highCPU, 1)
        #expect(model.settings.rule(for: .highCPU).threshold == 100)
        #expect(try store.load()?.rule(for: .highCPU).cooldownSeconds == 60)
    }

    @Test func enablingIsPerMetricAndLeavesTheOtherRulesAlone() {
        let model = AlertCenterModel(notifier: RecordingAlertNotifier(), store: MemoryAlertSettingsStore())
        model.setEnabled(.memoryPressure, false)
        #expect(model.settings.rule(for: .memoryPressure).isEnabled == false)
        #expect(model.settings.rule(for: .highCPU) == AlertRule.defaults(for: .highCPU))
        #expect(model.settings.rule(for: .thermalPressure).isEnabled)
    }

    @Test func unreadableSavedSettingsFallBackToDefaultsWithANotice() {
        let store = MemoryAlertSettingsStore(loadFailure: CocoaError(.fileReadCorruptFile))
        let model = AlertCenterModel(notifier: RecordingAlertNotifier(), store: store)
        #expect(model.settings == AlertSettings())
        #expect(model.notice?.contains("could not be read") == true)
        #expect(model.presentation.notice == model.notice)
    }

    @Test func aFailedSaveIsReportedAndTheChangeStillApplies() {
        let store = MemoryAlertSettingsStore(saveFailure: CocoaError(.fileWriteNoPermission))
        let model = AlertCenterModel(notifier: RecordingAlertNotifier(), store: store)
        model.setThreshold(.highCPU, 80)
        #expect(model.notice?.contains("could not be saved") == true)
        #expect(model.settings.rule(for: .highCPU).threshold == 80)
    }

    @Test func resetRestoresEveryDefault() {
        let model = AlertCenterModel(notifier: RecordingAlertNotifier(), store: MemoryAlertSettingsStore())
        model.setThreshold(.highCPU, 70)
        model.setEnabled(.lowDiskSpace, false)
        model.resetToDefaults()
        #expect(model.settings == AlertSettings())
    }
}

@MainActor
@Suite("Alert center: notifications")
struct AlertCenterNotificationTests {
    @Test func thePermissionIsReadWithoutAskingAndRequestedOnlyOnRequest() async {
        let notifier = RecordingAlertNotifier(permission: .notDetermined)
        let model = AlertCenterModel(notifier: notifier, store: MemoryAlertSettingsStore())

        await model.refreshPermission()
        #expect(model.permission == .notDetermined)
        #expect(notifier.requestCount == 0)
        #expect(model.presentation.notifications.canRequest)

        await model.requestPermission()
        #expect(model.permission == .authorized)
        #expect(notifier.requestCount == 1)
        #expect(!model.presentation.notifications.canRequest)
    }

    @Test func alertsAreNotPostedWhileNotificationsAreNotAllowed() async throws {
        let notifier = RecordingAlertNotifier(permission: .notDetermined)
        let model = AlertCenterModel(notifier: notifier, store: MemoryAlertSettingsStore())
        model.setSustainedSeconds(.highCPU, 0)

        model.evaluate(cpuSnapshot(at: 0, cpu: 0.95))
        #expect(model.presentation.rows.first { $0.metric == .highCPU }?.lastAlertText?.contains("CPU is at 95%") == true)

        // A notice that was going to be posted would be posted within a few milliseconds of its task starting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(notifier.delivered.isEmpty)
    }

    @Test func anAllowedAlertIsPostedWithItsMessageAndCooldownHoldsTheNext() async throws {
        let notifier = RecordingAlertNotifier(permission: .authorized)
        let model = AlertCenterModel(notifier: notifier, store: MemoryAlertSettingsStore())
        model.setSustainedSeconds(.highCPU, 0)
        model.setCooldownSeconds(.highCPU, 60)

        model.evaluate(cpuSnapshot(at: 0, cpu: 0.95))
        try await waitUntil { notifier.delivered.count == 1 }
        #expect(notifier.delivered.first?.title == "High CPU use")
        #expect(notifier.delivered.first?.body == "CPU is at 95%, at or above the 90% threshold.")
        #expect(notifier.delivered.first?.identifier == "macfleet.highCPU.")

        model.evaluate(cpuSnapshot(at: 2, cpu: 0.5))
        model.evaluate(cpuSnapshot(at: 120, cpu: 0.95))
        try await waitUntil { notifier.delivered.count == 2 }
        #expect(notifier.delivered.count == 2)
    }

    @Test func aFailedPostIsReportedInPlainWords() async throws {
        let notifier = RecordingAlertNotifier(
            permission: .authorized,
            deliveryFailure: CocoaError(.fileWriteUnknown)
        )
        let model = AlertCenterModel(notifier: notifier, store: MemoryAlertSettingsStore())
        model.setSustainedSeconds(.highCPU, 0)

        model.evaluate(cpuSnapshot(at: 0, cpu: 0.95))
        try await waitUntil { model.notice != nil }
        #expect(model.notice?.contains("could not be posted") == true)
        #expect(notifier.delivered.isEmpty)
    }
}
