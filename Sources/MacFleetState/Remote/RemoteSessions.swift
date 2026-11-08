import Foundation
import MacFleetKit

/// One registered Mac and the credential to reach it. The credential is read from the secret store each time a
/// connection starts, and it is never written into a record.
public struct RemoteTarget: Sendable {
    public let record: RemoteHostRecord
    public let credential: RemoteCredential

    public init(record: RemoteHostRecord, credential: RemoteCredential) {
        self.record = record
        self.credential = credential
    }
}

/// Opens a metrics session. The stream yields the session and then each snapshot, and it ends with the error that stopped
/// the session.
public protocol RemoteSessionOpening: Sendable {
    func open(_ target: RemoteTarget, interval: SamplingInterval) async -> AsyncThrowingStream<RemoteUpdate, any Error>
}

/// Opens sessions over the network with `RemoteMetricsClient`, pinned to the target's saved identity.
public struct MetricsClientSessionOpener: RemoteSessionOpening {
    private let timings: RemoteTimings

    public init(timings: RemoteTimings = .standard) {
        self.timings = timings
    }

    public func open(_ target: RemoteTarget, interval: SamplingInterval) async -> AsyncThrowingStream<RemoteUpdate, any Error> {
        let client = RemoteMetricsClient(
            endpoint: target.record.endpoint,
            credential: target.credential,
            pinnedHost: target.record.pinnedFingerprint,
            timings: timings
        )
        return await client.updates(interval: interval)
    }
}

/// Reads a host's identity before the user decides to trust it. Sends no secret.
public protocol RemoteHostProbing: Sendable {
    func probe(_ endpoint: RemoteEndpoint, clientID: String) async throws -> RemoteProbeResult
}

public struct MetricsRemoteHostProber: RemoteHostProbing {
    public init() {}

    public func probe(_ endpoint: RemoteEndpoint, clientID: String) async throws -> RemoteProbeResult {
        try await RemoteHostProbe.probe(endpoint: endpoint, clientID: clientID)
    }
}

/// The clock the connection loops use. Tests replace it, so retries happen when a test says so.
public struct RemoteScheduling: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let live = RemoteScheduling(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}
