import Foundation
import MacFleetKit
import MacFleetState
import Testing

/// The fixed clock for fleet tests. Every timestamp comes from here, so retry times are exact.
let fleetEpoch = Date(timeIntervalSince1970: 1_700_000_000)

/// One scripted session for a Mac: what it yields, and how it ends.
enum FleetScriptedSession: Sendable {
    /// Connects, yields these updates, then ends.
    case run([RemoteUpdate], end: FleetScriptEnd)
    /// Fails before any update.
    case fail(RemoteClientError)
}

enum FleetScriptEnd: Sendable {
    /// The session stays open until the watcher stops it.
    case hold
    case closed
    case fail(RemoteClientError)
}

/// Serves each Mac its own script, so independent connections never race for one queue. A Mac with no script left
/// fails, which keeps a broken test from hanging.
actor FleetScriptedOpener: RemoteSessionOpening {
    private var scripts: [UUID: [FleetScriptedSession]]
    private(set) var attempts: [UUID: Int] = [:]

    init(_ scripts: [UUID: [FleetScriptedSession]]) {
        self.scripts = scripts
    }

    func open(_ target: RemoteTarget, interval: SamplingInterval) async -> AsyncThrowingStream<RemoteUpdate, any Error> {
        let id = target.record.id
        attempts[id, default: 0] += 1
        var queue = scripts[id] ?? []
        let next = queue.isEmpty ? FleetScriptedSession.fail(.connectionFailed("no script left")) : queue.removeFirst()
        scripts[id] = queue
        return AsyncThrowingStream { continuation in
            switch next {
            case let .fail(error):
                continuation.finish(throwing: error)
            case let .run(updates, end):
                for update in updates {
                    continuation.yield(update)
                }
                switch end {
                case .hold:
                    break
                case .closed:
                    continuation.finish()
                case let .fail(error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

/// A clock for retries. A test fires a pending wait when it is ready, and every requested delay is recorded.
actor FleetManualScheduler {
    private(set) var requested: [Duration] = []
    private var waiting: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var cancelledIDs: Set<Int> = []
    private var nextID = 0

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledIDs.contains(id) {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Lets the oldest pending wait finish.
    func fire() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().continuation.resume()
    }

    /// Waits until at least `count` waits are pending. Returns false if they never are, so a test fails instead of hanging.
    func awaitPending(atLeast count: Int) async -> Bool {
        for _ in 0..<2_000 {
            if waiting.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private func cancel(_ id: Int) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        } else {
            cancelledIDs.insert(id)
        }
    }
}

/// Answers probes from a script, and records which addresses were probed.
actor FleetFakeProber: RemoteHostProbing {
    private var results: [Result<RemoteProbeResult, RemoteClientError>]
    private(set) var probed: [RemoteEndpoint] = []

    init(_ results: [Result<RemoteProbeResult, RemoteClientError>]) {
        self.results = results
    }

    func probe(_ endpoint: RemoteEndpoint, clientID: String) async throws -> RemoteProbeResult {
        probed.append(endpoint)
        let next = results.isEmpty ? Result<RemoteProbeResult, RemoteClientError>.failure(.connectionFailed("no probe scripted")) : results.removeFirst()
        return try next.get()
    }
}

func fleetRecord(
    id: UUID = UUID(),
    label: String = "Studio",
    host: String = "studio.tail1234.ts.net",
    port: UInt16 = 21440,
    clientID: String = "laptop-1",
    pin: HostFingerprint
) -> RemoteHostRecord {
    RemoteHostRecord(
        id: id,
        label: label,
        host: host,
        port: port,
        clientID: clientID,
        pinnedFingerprint: pin,
        addedAt: fleetEpoch
    )
}

func fleetSnapshot(cpu: Double = 0.25, at time: Date = fleetEpoch) -> RemoteSnapshot {
    RemoteSnapshot(
        capturedAt: time,
        cpuTotal: .available(cpu),
        memory: .available(MemoryUsage(totalBytes: 16_000_000_000, usedBytes: 8_000_000_000, availableBytes: 8_000_000_000)),
        memoryPressure: .available(.normal),
        storage: .available([]),
        network: .available([
            NetworkInterfaceMetrics(
                name: "en0",
                isUp: true,
                isLoopback: false,
                ipv4Addresses: ["100.70.82.25"],
                totals: .unavailable(.notSampled),
                rates: .available(NetworkRate(receivedPerSecond: 1_200_000, sentPerSecond: 40_000))
            ),
        ]),
        thermal: .available(.nominal),
        loadAverage: .available(LoadAverage(oneMinute: 1, fiveMinutes: 1, fifteenMinutes: 1))
    )
}

func fleetConnected(name: String, fingerprint: HostFingerprint) -> RemoteUpdate {
    .connected(RemoteSessionInfo(
        host: HostIdentity(displayName: name, fingerprint: fingerprint),
        version: RemoteProtocol.current,
        capabilities: RemoteSnapshot.allSupportedCapabilities
    ))
}

extension RemoteSnapshot {
    /// Every metric supported, as a host reports after a successful sample.
    static var allSupportedCapabilities: [RemoteCapability] {
        fleetSnapshot().capabilities
    }
}

/// Waits for a condition on the main actor, polling briefly. It fails the test rather than hanging.
@MainActor
func fleetEventually(_ condition: () -> Bool) async throws {
    for _ in 0..<2_000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("the condition was not met in time")
}

/// Waits for a condition that needs an actor to answer.
func fleetEventuallyAsync(_ condition: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("the condition was not met in time")
}

/// The real-clock-free scheduling used by every fleet test that needs retries.
func fleetScheduling(_ scheduler: FleetManualScheduler) -> RemoteScheduling {
    RemoteScheduling(now: { fleetEpoch }, sleep: { try await scheduler.sleep($0) })
}
