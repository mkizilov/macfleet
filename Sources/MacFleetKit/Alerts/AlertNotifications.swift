import Foundation
import UserNotifications

/// Whether macOS lets MacFleet post notifications. `notDetermined` means the user has not been asked yet.
public enum NotificationPermission: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// One notification. A notification with the same identifier replaces the one already shown.
public struct AlertNotification: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

/// Posts alert notifications. Reading the permission never prompts; only `requestPermission` may ask the user, and
/// the app calls it only from an explicit user action.
public protocol AlertNotifying: Sendable {
    func permission() async -> NotificationPermission
    func requestPermission() async throws -> NotificationPermission
    func deliver(_ notification: AlertNotification) async throws
}

/// Posts through UserNotifications, the system notification API. It works only in a bundled app, because the
/// notification center needs the app's bundle identifier.
public struct UserNotificationAlertNotifier: AlertNotifying {
    public init() {}

    public func permission() async -> NotificationPermission {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return Self.permission(from: status)
    }

    public func requestPermission() async throws -> NotificationPermission {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    public func deliver(_ notification: AlertNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }

    /// A provisional grant can show notifications, so it counts as allowed. An unrecognized future status counts as
    /// denied: an alert that is not posted is safer than one posted without permission.
    static func permission(from status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .authorized, .provisional: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .denied
        }
    }
}
