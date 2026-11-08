import AppKit
import MacFleetKit
import MacFleetState

/// Owns the model and connects app-level events to the sampling engine: sleep, wake, and termination.
@MainActor
final class MacFleetAppDelegate: NSObject, NSApplicationDelegate {
    let model = FleetStatusModel(
        provider: ProcessSystemMetricsProvider(),
        store: InMemorySnapshotStore()
    )
    private var powerObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    /// Replies only after sampling has stopped, so no collection is cut off mid-write.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
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
