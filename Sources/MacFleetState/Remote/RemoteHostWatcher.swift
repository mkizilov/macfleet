import Foundation
import MacFleetKit

public enum RemoteConnectionState: Equatable, Sendable {
    /// Trying to connect. `attempt` counts the consecutive failures so far, and zero is the first try.
    case connecting(attempt: Int)
    case online
    /// Waiting to try again. `attempt` is the number of consecutive failures, and `retryAt` is when the next try starts.
    case reconnecting(attempt: Int, retryAt: Date, failure: RemoteFailure)
    /// Not retrying. The failure says what the user must do.
    case stopped(RemoteFailure)
}

/// One Mac's connection as the app sees it. The snapshot is the newest one received, and it stays while the Mac is
/// offline, so the card can show it as stale rather than hide it.
public struct RemoteHostStatus: Equatable, Sendable {
    public let hostID: UUID
    public let state: RemoteConnectionState
    /// The name the Mac reports for itself, once a session has connected.
    public let hostName: String?
    public let capabilities: [RemoteCapability]?
    public let snapshot: RemoteSnapshot?
    /// When this app received `snapshot`.
    public let receivedAt: Date?

    public init(
        hostID: UUID,
        state: RemoteConnectionState,
        hostName: String?,
        capabilities: [RemoteCapability]?,
        snapshot: RemoteSnapshot?,
        receivedAt: Date?
    ) {
        self.hostID = hostID
        self.state = state
        self.hostName = hostName
        self.capabilities = capabilities
        self.snapshot = snapshot
        self.receivedAt = receivedAt
    }
}

/// Keeps one Mac connected. It opens a session, publishes each change of state, and retries transient failures with
/// backoff. A fatal failure ends the retries. Each watcher is independent, so one Mac cannot affect another.
public actor RemoteHostWatcher {
    public nonisolated let hostID: UUID
    /// The latest statuses. The stream ends when the watcher stops.
    public nonisolated let statuses: AsyncStream<RemoteHostStatus>

    private let continuation: AsyncStream<RemoteHostStatus>.Continuation
    private let target: RemoteTarget
    private let opener: any RemoteSessionOpening
    private let interval: SamplingInterval
    private let backoff: RemoteBackoff
    private let scheduling: RemoteScheduling
    private let history: (any RemoteHistorySink)?
    private let historyID: HistoryHostID
    private var task: Task<Void, Never>?
    private var isStopped = false
    private var failures = 0
    private var current: RemoteHostStatus

    public init(
        target: RemoteTarget,
        opener: any RemoteSessionOpening,
        interval: SamplingInterval = SamplingInterval(seconds: 5),
        backoff: RemoteBackoff = .standard,
        scheduling: RemoteScheduling = .live,
        history: (any RemoteHistorySink)? = nil
    ) {
        hostID = target.record.id
        historyID = .remote(target.record.id)
        self.history = history
        let stream = AsyncStream.makeStream(of: RemoteHostStatus.self, bufferingPolicy: .bufferingNewest(8))
        statuses = stream.stream
        continuation = stream.continuation
        self.target = target
        self.opener = opener
        self.interval = interval
        self.backoff = backoff
        self.scheduling = scheduling
        current = RemoteHostStatus(
            hostID: target.record.id,
            state: .connecting(attempt: 0),
            hostName: nil,
            capabilities: nil,
            snapshot: nil,
            receivedAt: nil
        )
    }

    /// Starts the connection loop. Calling it again while the loop runs changes nothing, and a stopped watcher never
    /// starts again.
    public func start() {
        guard task == nil, !isStopped else { return }
        task = Task { await self.run() }
    }

    /// Stops the loop and returns once it has finished. The status stream ends.
    public func stop() async {
        isStopped = true
        let running = task
        task = nil
        running?.cancel()
        await running?.value
        continuation.finish()
    }

    private func run() async {
        while !Task.isCancelled {
            publish(.connecting(attempt: failures))
            let failure: RemoteFailure
            do {
                let updates = await opener.open(target, interval: interval)
                for try await update in updates {
                    await apply(update)
                }
                failure = .closed
            } catch {
                failure = RemoteFailure(error)
            }
            guard !Task.isCancelled else { return }

            if failure.isFatal {
                publish(.stopped(failure))
                return
            }
            failures += 1
            let delay = backoff.delay(afterFailures: failures)
            let retryAt = scheduling.now().addingTimeInterval(TimeInterval(delay.components.seconds))
            publish(.reconnecting(attempt: failures, retryAt: retryAt, failure: failure))
            do {
                try await scheduling.sleep(delay)
            } catch {
                return
            }
        }
    }

    /// Publishes a session update. A snapshot is also handed to the history, in the order it arrived, so each host's
    /// rows come from one sequence and never interleave with another host's.
    private func apply(_ update: RemoteUpdate) async {
        switch update {
        case let .connected(info):
            failures = 0
            current = RemoteHostStatus(
                hostID: hostID,
                state: .online,
                hostName: info.host.displayName,
                capabilities: info.capabilities,
                snapshot: current.snapshot,
                receivedAt: current.receivedAt
            )
        case let .snapshot(snapshot):
            let received = scheduling.now()
            current = RemoteHostStatus(
                hostID: hostID,
                state: .online,
                hostName: current.hostName,
                capabilities: current.capabilities,
                snapshot: snapshot,
                receivedAt: received
            )
            _ = await history?.ingest(snapshot, from: historyID, receivedAt: received)
        }
        continuation.yield(current)
    }

    private func publish(_ state: RemoteConnectionState) {
        current = RemoteHostStatus(
            hostID: hostID,
            state: state,
            hostName: current.hostName,
            capabilities: current.capabilities,
            snapshot: current.snapshot,
            receivedAt: current.receivedAt
        )
        continuation.yield(current)
    }
}
