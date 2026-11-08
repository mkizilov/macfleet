import Foundation
import MacFleetKit

/// One menu bar metric as the General pane shows it.
public struct MenuBarOptionPresentation: Equatable, Sendable, Identifiable {
    public let metric: MenuBarMetric
    public let title: String
    public let isShown: Bool

    public var id: MenuBarMetric {
        metric
    }
}

/// One rate the user can pick.
public struct RefreshChoicePresentation: Equatable, Sendable, Identifiable {
    public let seconds: Int
    public let title: String

    public var id: Int {
        seconds
    }
}

/// One kind of sampling, with the rate it uses and the rates it can use.
public struct RefreshRowPresentation: Equatable, Sendable, Identifiable {
    public let kind: RefreshKind
    public let title: String
    public let help: String
    public let selectedSeconds: Int
    public let choices: [RefreshChoicePresentation]

    public var id: RefreshKind {
        kind
    }
}

/// The login item, as the Startup section shows it.
public struct LaunchPresentation: Equatable, Sendable {
    public let isOn: Bool
    /// False when the system has no login item to change, as in a build run from a folder.
    public let canChange: Bool
    public let statusText: String
    public let helpText: String
    /// Set when the user has to allow MacFleet in System Settings before the login item takes effect.
    public let showsLoginItemsLink: Bool
}

/// The Settings window's content. Built when a setting changes, never inside a view body.
public struct PreferencesPresentation: Equatable, Sendable {
    public let pane: SettingsPane
    public let menuBarOptions: [MenuBarOptionPresentation]
    public let menuBarSummary: String
    public let refreshRows: [RefreshRowPresentation]
    public let energySummary: String
    public let launch: LaunchPresentation
    public let loadNotice: String?
    public let saveNotice: String?
    public let launchNotice: String?
    public let isDefault: Bool

    init(
        pane: SettingsPane,
        preferences: AppPreferences,
        launchStatus: LaunchAtLoginStatus,
        loadNotice: String?,
        saveNotice: String?,
        launchNotice: String?
    ) {
        self.pane = pane
        menuBarOptions = MenuBarMetric.allCases.map { metric in
            MenuBarOptionPresentation(
                metric: metric,
                title: metric.title,
                isShown: preferences.menuBarMetrics.contains(metric)
            )
        }
        menuBarSummary = Self.menuBarSummary(preferences.menuBarMetrics)
        refreshRows = RefreshKind.allCases.map { kind in
            RefreshRowPresentation(
                kind: kind,
                title: Self.rowTitle(kind),
                help: Self.rowHelp(kind),
                selectedSeconds: preferences.seconds(for: kind),
                choices: kind.allowedSeconds.map { RefreshChoicePresentation(seconds: $0, title: Self.duration($0)) }
            )
        }
        energySummary = [
            "Right now: every \(preferences.backgroundSeconds) seconds while the popover is closed,",
            "every \(preferences.popoverSeconds) seconds while it is open,",
            "and every \(preferences.remoteSeconds) seconds for each registered Mac.",
            "Sampling stops while the Mac sleeps.",
        ].joined(separator: " ")
        launch = Self.launch(launchStatus)
        self.loadNotice = loadNotice
        self.saveNotice = saveNotice
        self.launchNotice = launchNotice
        isDefault = preferences == .default
    }

    static func menuBarSummary(_ metrics: [MenuBarMetric]) -> String {
        guard !metrics.isEmpty else {
            return "Only the icon is shown. The values stay available in the popover."
        }
        let titles = metrics.map(\.title)
        let list = titles.count == 1
            ? titles[0]
            : titles.dropLast().joined(separator: ", ") + " and " + titles[titles.count - 1]
        return "Shows \(list) in the menu bar."
    }

    static func duration(_ seconds: Int) -> String {
        if seconds >= 60, seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return seconds == 1 ? "1 second" : "\(seconds) seconds"
    }

    private static func rowTitle(_ kind: RefreshKind) -> String {
        switch kind {
        case .background: "While the popover is closed"
        case .popover: "While the popover is open"
        case .processes: "Process list"
        case .remote: "Registered Macs"
        }
    }

    private static func rowHelp(_ kind: RefreshKind) -> String {
        switch kind {
        case .background:
            "How often the menu bar and alerts update. Shorter intervals update sooner and use more power."
        case .popover:
            "How often the values in the popover update."
        case .processes:
            "How often the process list updates while its window is open."
        case .remote:
            "How often each registered Mac reports. Shorter intervals update sooner and use more power on both Macs."
        }
    }

    private static func launch(_ status: LaunchAtLoginStatus) -> LaunchPresentation {
        let helpText = "Starts MacFleet when you log in to this Mac."
        switch status {
        case .enabled:
            return LaunchPresentation(
                isOn: true,
                canChange: true,
                statusText: "On. MacFleet opens when you log in.",
                helpText: helpText,
                showsLoginItemsLink: false
            )
        case .notRegistered:
            return LaunchPresentation(
                isOn: false,
                canChange: true,
                statusText: "Off.",
                helpText: helpText,
                showsLoginItemsLink: false
            )
        case .requiresApproval:
            return LaunchPresentation(
                isOn: true,
                canChange: true,
                statusText: "Waiting for approval. Allow MacFleet under Login Items in System Settings.",
                helpText: helpText,
                showsLoginItemsLink: true
            )
        case .notFound:
            return LaunchPresentation(
                isOn: false,
                canChange: false,
                statusText: "Not available in this build. Launch at login works in the installed app.",
                helpText: helpText,
                showsLoginItemsLink: false
            )
        case .unknown:
            return LaunchPresentation(
                isOn: false,
                canChange: true,
                statusText: "The system did not report whether MacFleet opens at login.",
                helpText: helpText,
                showsLoginItemsLink: false
            )
        }
    }
}
