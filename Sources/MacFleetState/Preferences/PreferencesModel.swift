import Foundation
import MacFleetKit
import Observation

/// Owns the user's settings and the login item state. Every change is saved and then pushed to the models that use it,
/// through `onChange`. Nothing here runs on a timer, and nothing is sampled.
@MainActor
@Observable
public final class PreferencesModel {
    public private(set) var preferences: AppPreferences
    public private(set) var presentation: PreferencesPresentation
    /// Set when saved settings could not be read at launch. Stays until the app restarts.
    public private(set) var loadNotice: String?
    /// Set when the latest change could not be saved. The new value still applies until the app quits.
    public private(set) var saveNotice: String?
    /// Set when the login item could not be changed.
    public private(set) var launchNotice: String?
    public private(set) var pane = SettingsPane.general
    public private(set) var launchStatus: LaunchAtLoginStatus

    private let store: any PreferencesStoring
    private let launchAtLogin: any LaunchAtLoginControlling
    private let onChange: @MainActor (AppPreferences) -> Void

    public init(
        store: any PreferencesStoring,
        launchAtLogin: any LaunchAtLoginControlling,
        onChange: @escaping @MainActor (AppPreferences) -> Void = { _ in }
    ) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        self.onChange = onChange
        var loaded = AppPreferences.default
        var problem: String?
        do {
            loaded = try store.load() ?? .default
        } catch PreferencesStoreError.damaged(let aside) {
            problem = "Saved settings could not be read, so the defaults are in use. The damaged data was kept under \(aside)."
        } catch {
            problem = "Saved settings could not be read, so the defaults are in use. \(error.localizedDescription)"
        }
        let status = launchAtLogin.status()
        preferences = loaded
        loadNotice = problem
        launchStatus = status
        presentation = PreferencesPresentation(
            pane: .general,
            preferences: loaded,
            launchStatus: status,
            loadNotice: problem,
            saveNotice: nil,
            launchNotice: nil
        )
        onChange(loaded)
    }

    public func setMenuBarMetric(_ metric: MenuBarMetric, shown: Bool) {
        var updated = preferences
        updated.setMenuBarMetric(metric, shown: shown)
        apply(updated)
    }

    /// Sets a rate the user can choose. A rate outside the kind's list is refused and changes nothing.
    public func setRefresh(_ kind: RefreshKind, seconds: Int) {
        var updated = preferences
        guard updated.setSeconds(seconds, for: kind) else { return }
        apply(updated)
    }

    public func resetToDefaults() {
        apply(.default)
    }

    /// Turns the login item on or off. The status is read back from the system, so the toggle shows what the system did.
    public func setLaunchAtLogin(_ enabled: Bool) {
        guard launchStatus != .notFound else {
            launchNotice = "Launch at login is available in the installed app."
            rebuild()
            return
        }
        do {
            try launchAtLogin.setEnabled(enabled)
            launchNotice = nil
        } catch {
            launchNotice = "Launch at login could not be changed. \(error.localizedDescription)"
        }
        launchStatus = launchAtLogin.status()
        rebuild()
    }

    public func refreshLaunchStatus() {
        launchStatus = launchAtLogin.status()
        rebuild()
    }

    public func openLoginItemsSettings() {
        launchAtLogin.openLoginItemsSettings()
    }

    public func show(_ pane: SettingsPane) {
        self.pane = pane
        rebuild()
    }

    private func apply(_ updated: AppPreferences) {
        guard updated != preferences else { return }
        preferences = updated
        onChange(updated)
        do {
            try store.save(updated)
            saveNotice = nil
        } catch {
            saveNotice = "Settings could not be saved. They apply until the app quits. \(error.localizedDescription)"
        }
        rebuild()
    }

    private func rebuild() {
        presentation = PreferencesPresentation(
            pane: pane,
            preferences: preferences,
            launchStatus: launchStatus,
            loadNotice: loadNotice,
            saveNotice: saveNotice,
            launchNotice: launchNotice
        )
    }
}
