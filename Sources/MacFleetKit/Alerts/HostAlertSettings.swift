import Foundation
import os

/// Saves alert settings for each remote Mac, keyed by its history host ID. The local Mac keeps its own settings.
public protocol HostAlertSettingsStoring: Sendable {
    func load() throws -> [String: AlertSettings]
    func save(_ settings: [String: AlertSettings]) throws
}

/// Keeps the per-host alert settings in user defaults, as one encoded map. Nothing is written when nothing changes.
public struct UserDefaultsHostAlertSettingsStore: HostAlertSettingsStoring {
    public static let key = "MacFleet.hostAlertSettings"

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() throws -> [String: AlertSettings] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return try JSONDecoder().decode([String: AlertSettings].self, from: data)
    }

    public func save(_ settings: [String: AlertSettings]) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.key)
    }
}

/// Keeps the settings in memory, with optional failures, for tests and previews.
public final class MemoryHostAlertSettingsStore: HostAlertSettingsStoring, Sendable {
    private let settings: OSAllocatedUnfairLock<[String: AlertSettings]>
    private let loadFailure: (any Error)?
    private let saveFailure: (any Error)?

    public init(settings: [String: AlertSettings] = [:], loadFailure: (any Error)? = nil, saveFailure: (any Error)? = nil) {
        self.settings = OSAllocatedUnfairLock(initialState: settings)
        self.loadFailure = loadFailure
        self.saveFailure = saveFailure
    }

    public func load() throws -> [String: AlertSettings] {
        if let loadFailure {
            throw loadFailure
        }
        return settings.withLock { $0 }
    }

    public func save(_ updated: [String: AlertSettings]) throws {
        if let saveFailure {
            throw saveFailure
        }
        settings.withLock { $0 = updated }
    }
}
