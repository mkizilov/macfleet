import Foundation

/// The panes of the Settings window, in the order they appear.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general
    case notifications

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        }
    }
}

/// The windows that are opened by identifier. Settings opens through its own action.
public enum AppWindow: String, CaseIterable, Sendable {
    case fleet
    case history
    case processes

    public var id: String {
        rawValue
    }
}

/// Where a command leads. The app refreshes, opens a window, or opens Settings on a pane.
public enum AppDestination: Equatable, Sendable {
    case refresh
    case window(AppWindow)
    case settings(SettingsPane)
}

/// Every keyboard command the app offers. Each key is unique, and Command-comma stays with the system's Settings command.
public enum AppCommand: CaseIterable, Sendable {
    case refresh
    case fleet
    case history
    case processes
    case notifications

    public var title: String {
        switch self {
        case .refresh: "Refresh Now"
        case .fleet: "Fleet"
        case .history: "History"
        case .processes: "Processes"
        case .notifications: "Notification Settings"
        }
    }

    /// The character typed with Command.
    public var key: Character {
        switch self {
        case .refresh: "r"
        case .fleet: "1"
        case .history: "2"
        case .processes: "3"
        case .notifications: "4"
        }
    }

    public var destination: AppDestination {
        switch self {
        case .refresh: .refresh
        case .fleet: .window(.fleet)
        case .history: .window(.history)
        case .processes: .window(.processes)
        case .notifications: .settings(.notifications)
        }
    }
}
