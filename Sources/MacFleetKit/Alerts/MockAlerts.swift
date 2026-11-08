import os

/// Records notifications in memory, with a permission the test sets. Tests and previews use it in place of the system
/// notification center.
public final class RecordingAlertNotifier: AlertNotifying, Sendable {
    private struct State {
        var permission: NotificationPermission
        var grantsRequests: Bool
        var deliveryFailure: (any Error)?
        var delivered: [AlertNotification] = []
        var requestCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(
        permission: NotificationPermission = .notDetermined,
        grantsRequests: Bool = true,
        deliveryFailure: (any Error)? = nil
    ) {
        state = OSAllocatedUnfairLock(initialState: State(
            permission: permission,
            grantsRequests: grantsRequests,
            deliveryFailure: deliveryFailure
        ))
    }

    public var delivered: [AlertNotification] {
        state.withLock { $0.delivered }
    }

    public var requestCount: Int {
        state.withLock { $0.requestCount }
    }

    public func permission() async -> NotificationPermission {
        state.withLock { $0.permission }
    }

    public func requestPermission() async throws -> NotificationPermission {
        state.withLock { state in
            state.requestCount += 1
            state.permission = state.grantsRequests ? .authorized : .denied
            return state.permission
        }
    }

    public func deliver(_ notification: AlertNotification) async throws {
        try state.withLock { state in
            if let failure = state.deliveryFailure {
                throw failure
            }
            state.delivered.append(notification)
        }
    }
}

/// Keeps alert settings in memory, with optional failures on load or save.
public final class MemoryAlertSettingsStore: AlertSettingsStoring, Sendable {
    private let settings: OSAllocatedUnfairLock<AlertSettings?>
    private let loadFailure: (any Error)?
    private let saveFailure: (any Error)?

    public init(settings: AlertSettings? = nil, loadFailure: (any Error)? = nil, saveFailure: (any Error)? = nil) {
        self.settings = OSAllocatedUnfairLock(initialState: settings)
        self.loadFailure = loadFailure
        self.saveFailure = saveFailure
    }

    public func load() throws -> AlertSettings? {
        if let loadFailure {
            throw loadFailure
        }
        return settings.withLock { $0 }
    }

    public func save(_ settings: AlertSettings) throws {
        if let saveFailure {
            throw saveFailure
        }
        self.settings.withLock { $0 = settings }
    }
}
