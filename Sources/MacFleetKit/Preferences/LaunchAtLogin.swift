import Foundation
import os
import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case notRegistered
    /// Registered, but the user has to allow MacFleet under Login Items in System Settings.
    case requiresApproval
    /// The system has nothing to register, as when the app runs from a build folder rather than an installed bundle.
    case notFound
    case unknown
}

public enum LaunchAtLoginError: LocalizedError, Equatable, Sendable {
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case let .refused(reason): reason
        }
    }
}

/// Starts MacFleet at login through the system's login item registration.
public protocol LaunchAtLoginControlling: Sendable {
    func status() -> LaunchAtLoginStatus
    func setEnabled(_ enabled: Bool) throws
    /// Opens the Login Items pane of System Settings, where the user can allow MacFleet.
    func openLoginItemsSettings()
}

/// Uses `SMAppService.mainApp`, the supported way for an app to start at login on macOS 13 and later.
public struct ServiceLaunchAtLogin: LaunchAtLoginControlling {
    public init() {}

    public func status() -> LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Keeps the login item state in memory. Tests use it, so no login item is ever registered by a test run.
public final class MemoryLaunchAtLogin: LaunchAtLoginControlling, Sendable {
    private struct State: Sendable {
        var status: LaunchAtLoginStatus
        var refusal: String?
        var requiresApproval: Bool
        var openRequests = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    /// `requiresApproval` makes enabling leave the item waiting for approval, as the system does on first use.
    public init(status: LaunchAtLoginStatus = .notRegistered, refusal: String? = nil, requiresApproval: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(status: status, refusal: refusal, requiresApproval: requiresApproval))
    }

    public var openRequestCount: Int {
        state.withLock { $0.openRequests }
    }

    public func status() -> LaunchAtLoginStatus {
        state.withLock { $0.status }
    }

    public func setEnabled(_ enabled: Bool) throws {
        try state.withLock { current in
            if let refusal = current.refusal {
                throw LaunchAtLoginError.refused(refusal)
            }
            current.status = enabled ? (current.requiresApproval ? .requiresApproval : .enabled) : .notRegistered
        }
    }

    public func openLoginItemsSettings() {
        state.withLock { $0.openRequests += 1 }
    }
}
