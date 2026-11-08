import Foundation
import MacFleetKit
import MacFleetState
import Testing

private func makePresentation(
    settings: AlertSettings = AlertSettings(),
    status: AlertStatus = .idle,
    notices: [AlertMetric: AlertNotice] = [:],
    permission: NotificationPermission = .notDetermined,
    notice: String? = nil
) -> AlertSettingsPresentation {
    AlertSettingsPresentation(
        settings: settings,
        status: status,
        lastNotices: notices,
        permission: permission,
        notice: notice
    )
}

private func row(_ presentation: AlertSettingsPresentation, _ metric: AlertMetric) -> AlertRowPresentation? {
    presentation.rows.first { $0.metric == metric }
}

@Suite("Alert settings presentation")
struct AlertSettingsPresentationTests {
    @Test func rowsFollowTheSettingsOrderAndShowTheDefaultThresholds() {
        let rows = makePresentation().rows
        #expect(rows.map(\.title) == [
            "High CPU use",
            "Memory pressure",
            "Low disk space",
            "High network use",
            "Thermal pressure",
        ])
        #expect(rows.map(\.thresholdLabel) == [
            "Alert when CPU reaches 90%",
            "Alert at critical or worse",
            "Alert when free space falls to 10% or less",
            "Alert when download and upload together reach 50 MB/s",
            "Alert at serious or worse",
        ])
    }

    @Test func statusSaysWhetherAnAlertIsOffWatchingWaitingOrFiring() {
        var settings = AlertSettings()
        settings.setRule(
            AlertRule(isEnabled: false, threshold: 90, sustainedSeconds: 30, cooldownSeconds: 900),
            for: .highCPU
        )
        let status = AlertStatus(
            firing: [.lowDiskSpace: ["Macintosh HD", "USB"]],
            waiting: [.memoryPressure]
        )
        let presentation = makePresentation(settings: settings, status: status)
        #expect(row(presentation, .highCPU)?.statusText == "Off")
        #expect(row(presentation, .memoryPressure)?.statusText == "Condition present, waiting for it to last")
        #expect(row(presentation, .lowDiskSpace)?.statusText == "Firing now: Macintosh HD, USB")
        #expect(row(presentation, .highNetwork)?.statusText == "Watching")
    }

    @Test func timingIsWrittenInPlainWords() {
        var settings = AlertSettings()
        settings.setRule(
            AlertRule(isEnabled: true, threshold: 90, sustainedSeconds: 0, cooldownSeconds: 60),
            for: .highCPU
        )
        settings.setRule(
            AlertRule(isEnabled: true, threshold: 90, sustainedSeconds: 120, cooldownSeconds: 900),
            for: .highNetwork
        )
        let presentation = makePresentation(settings: settings)
        #expect(row(presentation, .highCPU)?.sustainedText == "Alert on the first sample that meets the threshold")
        #expect(row(presentation, .highCPU)?.cooldownText == "Notify at most once every 60 seconds")
        #expect(row(presentation, .highNetwork)?.sustainedText == "Alert once it lasts 2 minutes")
        #expect(row(presentation, .highNetwork)?.cooldownText == "Notify at most once every 15 minutes")
    }

    @Test func aRecentAlertIsShownWithItsMessage() {
        let notice = AlertNotice(
            key: AlertKey(metric: .highCPU),
            title: "High CPU use",
            message: "CPU is at 95%, at or above the 90% threshold.",
            firedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let text = row(makePresentation(notices: [.highCPU: notice]), .highCPU)?.lastAlertText
        #expect(text?.hasPrefix("Last alert ") == true)
        #expect(text?.hasSuffix(": CPU is at 95%, at or above the 90% threshold.") == true)
        #expect(row(makePresentation(), .highCPU)?.lastAlertText == nil)
    }

    @Test func notificationWordingCoversEveryPermission() {
        #expect(NotificationStatusPresentation(.notDetermined).canRequest)
        #expect(!NotificationStatusPresentation(.denied).canRequest)
        #expect(NotificationStatusPresentation(.denied).text.contains("System Settings"))
        #expect(NotificationStatusPresentation(.authorized).text == "Notifications are allowed for MacFleet.")
        #expect(!NotificationStatusPresentation(.authorized).canRequest)
    }

    @Test func aSaveOrPostProblemIsCarriedToTheScreen() {
        let presentation = makePresentation(notice: "Alert settings could not be saved.")
        #expect(presentation.notice == "Alert settings could not be saved.")
    }
}
