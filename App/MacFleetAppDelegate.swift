import AppKit
import MacFleetKit
import MacFleetState

/// Owns the models and connects app-level events to the sampling engine: sleep, wake, and termination.
@MainActor
final class MacFleetAppDelegate: NSObject, NSApplicationDelegate {
    let model: FleetStatusModel
    let processes = ProcessMonitorModel(monitor: ProcessMonitor())
    let alerts: AlertCenterModel
    let fleet: FleetOverviewModel
    private var powerObservers: [NSObjectProtocol] = []

    override init() {
        let storage = HistoryStorage.open()
        let alerts = AlertCenterModel(notifier: UserNotificationAlertNotifier(), store: UserDefaultsAlertSettingsStore())
        let fleet = FleetOverviewModel(
            store: UserDefaultsRemoteHostStore(),
            secrets: KeychainSecretStore(service: KeychainSecretStore.remoteService),
            opener: MetricsClientSessionOpener(),
            prober: MetricsRemoteHostProber()
        )
        self.alerts = alerts
        self.fleet = fleet
        model = FleetStatusModel(
            engine: SamplingEngine(provider: ProcessSystemMetricsProvider(), store: storage.store),
            historySource: storage.history,
            startupNotice: storage.notice,
            alerts: alerts,
            overview: fleet
        )
        super.init()
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
    let notice: String?

    static func open() -> HistoryStorage {
        do {
            let store = try MetricHistoryStore.open(at: try MetricHistoryStore.defaultLocation())
            return HistoryStorage(store: store, history: store, notice: store.recoveryNote)
        } catch let fileError {
            do {
                let memory = try MetricHistoryStore.inMemory()
                return HistoryStorage(
                    store: memory,
                    history: memory,
                    notice: "History is kept for this session only: \(fileError.localizedDescription)"
                )
            } catch let memoryError {
                return HistoryStorage(
                    store: InMemorySnapshotStore(),
                    history: nil,
                    notice: "History is unavailable: \(fileError.localizedDescription) \(memoryError.localizedDescription)"
                )
            }
        }
    }
}
