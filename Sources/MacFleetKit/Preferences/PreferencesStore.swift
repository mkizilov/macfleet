import Foundation
import os

public enum PreferencesStoreError: Error, Equatable, Sendable {
    /// Saved settings could not be read. They were moved aside under `movedAside` and nothing was deleted.
    case damaged(movedAside: String)
}

public protocol PreferencesStoring: Sendable {
    /// The saved settings, or nil when none have been saved yet.
    func load() throws -> AppPreferences?
    func save(_ preferences: AppPreferences) throws
}

/// Keeps the settings in user defaults, as one encoded value. Damaged data is moved aside, never deleted.
public struct UserDefaultsPreferencesStore: PreferencesStoring {
    public static let key = "MacFleet.preferences"

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() throws -> AppPreferences? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            let aside = "\(Self.key).damaged.\(Int(Date().timeIntervalSince1970))"
            defaults.set(data, forKey: aside)
            defaults.removeObject(forKey: Self.key)
            throw PreferencesStoreError.damaged(movedAside: aside)
        }
    }

    public func save(_ preferences: AppPreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences), forKey: Self.key)
    }
}

/// Keeps the settings in memory, with an optional save failure, for tests and previews.
public final class MemoryPreferencesStore: PreferencesStoring, Sendable {
    private struct State: Sendable {
        var saved: AppPreferences?
        var saveFailure: (any Error)?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(saved: AppPreferences? = nil, saveFailure: (any Error)? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(saved: saved, saveFailure: saveFailure))
    }

    /// Makes the next and later saves fail, or lets them succeed again when nil.
    public func setSaveFailure(_ failure: (any Error)?) {
        state.withLock { $0.saveFailure = failure }
    }

    public func load() throws -> AppPreferences? {
        state.withLock { $0.saved }
    }

    public func save(_ preferences: AppPreferences) throws {
        try state.withLock { current in
            if let failure = current.saveFailure {
                throw failure
            }
            current.saved = preferences
        }
    }
}
