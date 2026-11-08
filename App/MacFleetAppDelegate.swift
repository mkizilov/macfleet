import AppKit
import MacFleetKit
import MacFleetState

/// Owns the models and connects app-level events to the sampling engine: sleep, wake, and termination.
@MainActor
final class MacFleetAppDelegate: NSObject, NSApplicationDelegate {
    let model: FleetStatusModel
    let processes: ProcessMonitorModel
    let alerts: AlertCenterModel
    let fleet: FleetOverviewModel
    let history: FleetHistoryModel?
    /// The user's settings. Every change reaches the models above through `apply`.
    let settings: PreferencesModel
    private var powerObservers: [NSObjectProtocol] = []

    override init() {
        let storage = HistoryStorage.open()
        let alerts = AlertCenterModel(notifier: UserNotificationAlertNotifier(), store: UserDefaultsAlertSettingsStore())
        let hostAlerts = HostAlertCenter(notifier: UserNotificationAlertNotifier(), store: UserDefaultsHostAlertSettingsStore())
        let fleet = FleetOverviewModel(
            store: UserDefaultsRemoteHostStore(),
            secrets: KeychainSecretStore(service: KeychainSecretStore.remoteService),
            opener: MetricsClientSessionOpener(),
            prober: MetricsRemoteHostProber(),
            history: storage.fleet,
            hostAlerts: hostAlerts
        )
        let model = FleetStatusModel(
            engine: SamplingEngine(provider: ProcessSystemMetricsProvider(), store: storage.store),
            historySource: storage.history,
            startupNotice: storage.notice,
            alerts: alerts,
            overview: fleet
        )
        let processes = ProcessMonitorModel(monitor: ProcessMonitor())
        self.alerts = alerts
        self.fleet = fleet
        self.model = model
        self.processes = processes
        history = storage.fleet.map { store in
            FleetHistoryModel(store: store, identities: { fleet.historyIdentities }, hostAlerts: hostAlerts)
        }
        settings = PreferencesModel(store: UserDefaultsPreferencesStore(), launchAtLogin: ServiceLaunchAtLogin()) { preferences in
            Self.apply(preferences, model: model, processes: processes, fleet: fleet)
        }
        super.init()
    }

    /// Hands saved settings to the models that use them. Runs at launch and after each change. The background rate is
    /// applied by the menu bar's task, which restarts whenever it changes.
    private static func apply(
        _ preferences: AppPreferences,
        model: FleetStatusModel,
        processes: ProcessMonitorModel,
        fleet: FleetOverviewModel
    ) {
        model.setMenuBarMetrics(preferences.menuBarMetrics)
        processes.setInterval(preferences.interval(for: .processes).duration)
        fleet.setRemoteSampleInterval(preferences.interval(for: .remote))
        Task { await model.setInteractiveInterval(preferences.interval(for: .popover)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        fleet.start()
        let center = NSWorkspace.shared.notificationCenter
        let model = model
        powerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Task { await model.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { await model.systemDidWake() }
            },
        ]
    }

    /// Replies only after sampling has stopped and pending history is written, so nothing is cut off mid-write.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            await fleet.stopAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        for observer in powerObservers {
            center.removeObserver(observer)
        }
        powerObservers = []
    }
}

/// Where history is kept, and what to do when the file cannot be opened. Live monitoring keeps running in every
/// case, and the notice tells the user what is not being saved.
private struct HistoryStorage {
    let store: any SnapshotStoring
    let history: (any HistorySource)?
    /// The same store, for the multi-Mac history. Nil only when no store could be opened at all.
    let fleet: (any FleetHistoryStoring)?
    let notice: String?

    static func open() -> HistoryStorage {
        do {
            let store = try MetricHistoryStore.open(at: try MetricHistoryStore.defaultLocation())
            return HistoryStorage(store: store, history: store, fleet: store, notice: store.recoveryNote)
        } catch let fileError {
            do {
                let memory = try MetricHistoryStore.inMemory()
                return HistoryStorage(
                    store: memory,
                    history: memory,
                    fleet: memory,
                    notice: "History is kept for this session only: \(fileError.localizedDescription)"
                )
            } catch let memoryError {
                return HistoryStorage(
                    store: InMemorySnapshotStore(),
                    history: nil,
                    fleet: nil,
                    notice: "History is unavailable: \(fileError.localizedDescription) \(memoryError.localizedDescription)"
                )
            }
        }
    }
}
