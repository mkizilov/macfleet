import Foundation
import Network

/// Where a host listens. The host name may be a tailnet address or a MagicDNS name. The pinned fingerprint, not the
/// name, decides whether the host is trusted.
public struct RemoteEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = RemoteProtocol.defaultPort) {
        self.host = host
        self.port = port
    }
}

/// What the host reported about itself once the session was up.
public struct RemoteSessionInfo: Equatable, Sendable {
    public let host: HostIdentity
    public let version: ProtocolVersion
    public let capabilities: [RemoteCapability]

    public init(host: HostIdentity, version: ProtocolVersion, capabilities: [RemoteCapability]) {
        self.host = host
        self.version = version
        self.capabilities = capabilities
    }
}

public enum RemoteUpdate: Equatable, Sendable {
    case connected(RemoteSessionInfo)
    case snapshot(RemoteSnapshot)
}

/// Why a session ended. A TLS verification failure appears as `connectionFailed`, unless the host showed a certificate
/// other than the pinned one, which is `identityMismatch` with the certificate that was shown.
public enum RemoteClientError: Error, Equatable, Sendable {
    case invalidEndpoint
    case connectionFailed(String)
    /// The host's certificate is not the one this client pinned. `presented` is the certificate it showed.
    case identityMismatch(presented: HostFingerprint?)
    /// The pinned certificate failed its own checks, such as its validity dates. `reason` says which check failed.
    case certificateRejected(reason: String)
    case hostRejected(RemoteProtocolError)
    /// The host's proof did not verify, so the host does not hold the shared secret. The client trusts nothing it sent.
    case hostNotAuthenticated
    case protocolViolation(String)
    case timedOut
    case closed
}

/// Connects to a host, proves the client's identity, checks the host's proof, and streams its snapshots.
public actor RemoteMetricsClient {
    private let endpoint: RemoteEndpoint
    private let credential: RemoteCredential
    private let pinnedHost: HostFingerprint
    private let timings: RemoteTimings
    private let supportedVersions: [ProtocolVersion]

    public init(
        endpoint: RemoteEndpoint,
        credential: RemoteCredential,
        pinnedHost: HostFingerprint,
        timings: RemoteTimings = .standard,
        supportedVersions: [ProtocolVersion] = RemoteProtocol.supportedVersions
    ) {
        precondition(!supportedVersions.isEmpty, "a client must offer at least one protocol version")
        self.endpoint = endpoint
        self.credential = credential
        self.pinnedHost = pinnedHost
        self.timings = timings
        self.supportedVersions = supportedVersions
    }

    /// Connects, authenticates, and yields the session and then each snapshot. Cancelling the stream closes the
    /// connection, and the stream ends with the error that stopped the session.
    public func updates(interval: SamplingInterval) -> AsyncThrowingStream<RemoteUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(interval: interval, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        interval: SamplingInterval,
        into continuation: AsyncThrowingStream<RemoteUpdate, any Error>.Continuation
    ) async {
        let observation = FingerprintObservation()
        do {
            let connection = try makeConnection(observation: observation)
            defer { Task { await connection.close() } }
            try await session(connection: connection, interval: interval, continuation: continuation)
            continuation.finish()
        } catch {
            continuation.finish(throwing: RemoteClientError.translating(error, observation: observation, pinned: pinnedHost))
        }
    }

    private func makeConnection(observation: FingerprintObservation) throws -> RemoteConnection {
        guard !endpoint.host.isEmpty, let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw RemoteClientError.invalidEndpoint
        }
        let parameters = NWParameters(
            tls: RemoteTLS.clientOptions(pinned: pinnedHost, observation: observation),
            tcp: NWProtocolTCP.Options()
        )
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        return RemoteConnection(NetworkConnectionHandle(connection: connection))
    }

    /// Hello, the host's identity, the client's proof, the host's proof, capabilities, subscribe, then the stream.
    private func session(
        connection: RemoteConnection,
        interval: SamplingInterval,
        continuation: AsyncThrowingStream<RemoteUpdate, any Error>.Continuation
    ) async throws {
        try await connection.start(within: timings.handshakeTimeout)

        let clientNonce = RemoteNonce.random(RemoteProtocol.nonceBytes)
        let highest = supportedVersions.max() ?? RemoteProtocol.current
        try await connection.send(.hello(ClientHello(
            clientID: credential.clientID,
            supportedVersions: supportedVersions,
            clientNonce: clientNonce
        )), version: highest)

        let accepted = try await expect(connection)
        guard case let .helloAccepted(hostHello) = accepted.message else { throw Self.unexpected() }
        guard supportedVersions.contains(accepted.version) else {
            throw RemoteClientError.protocolViolation("the host chose a version this client does not offer")
        }
        guard hostHello.host.fingerprint == pinnedHost else {
            throw RemoteClientError.identityMismatch(presented: hostHello.host.fingerprint)
        }
        guard let binding = await connection.channelBinding() else {
            throw RemoteClientError.protocolViolation("the secure channel is not ready")
        }

        let transcript = RemoteTranscript(
            version: accepted.version,
            clientID: credential.clientID,
            clientNonce: clientNonce,
            serverNonce: hostHello.serverNonce,
            hostFingerprint: pinnedHost,
            channelBinding: binding
        )
        try await connection.send(.authenticate(ClientProof(
            proof: RemoteAuthenticator.proof(for: .client, credential: credential, transcript: transcript)
        )), version: accepted.version)

        let authenticated = try await expect(connection)
        guard case let .authenticated(hostProof) = authenticated.message else { throw Self.unexpected() }
        guard RemoteAuthenticator.isValid(hostProof.proof, for: .host, credential: credential, transcript: transcript) else {
            throw RemoteClientError.hostNotAuthenticated
        }

        let capabilities = try await expect(connection)
        guard case let .capabilities(report) = capabilities.message else { throw Self.unexpected() }
        continuation.yield(.connected(RemoteSessionInfo(
            host: hostHello.host,
            version: accepted.version,
            capabilities: report.capabilities
        )))

        try await connection.send(
            .subscribe(SubscribeRequest(intervalSeconds: interval.seconds)),
            version: accepted.version
        )
        try await streamUntilEitherSideFails(connection, version: accepted.version, continuation: continuation)
    }

    /// Reads snapshots and sends heartbeats concurrently. Silence from the host for the idle timeout ends the session.
    private func streamUntilEitherSideFails(
        _ connection: RemoteConnection,
        version: ProtocolVersion,
        continuation: AsyncThrowingStream<RemoteUpdate, any Error>.Continuation
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    let envelope = try await connection.receive(within: self.timings.idleTimeout)
                    guard envelope.version == version else {
                        throw RemoteClientError.protocolViolation("a message used a version other than the negotiated one")
                    }
                    switch envelope.message {
                    case let .snapshot(snapshot):
                        continuation.yield(.snapshot(snapshot))
                    case let .error(error) where error.code == .shuttingDown || !error.retryable:
                        throw RemoteClientError.hostRejected(error)
                    case .error, .heartbeat, .unknown, .capabilities:
                        continue
                    default:
                        throw RemoteClientError.protocolViolation("the host sent a message that is not allowed here")
                    }
                }
            }
            group.addTask {
                var sequence: UInt64 = 0
                while true {
                    try await Task.sleep(for: .seconds(self.timings.heartbeatInterval))
                    sequence += 1
                    try await connection.send(.heartbeat(Heartbeat(sequence: sequence, sentAt: Date())), version: version)
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// The next message, which must arrive within the handshake timeout. A host error replaces the expected message.
    private func expect(_ connection: RemoteConnection) async throws -> RemoteEnvelope {
        let envelope = try await connection.receive(within: timings.handshakeTimeout)
        if case let .error(error) = envelope.message {
            throw RemoteClientError.hostRejected(error)
        }
        return envelope
    }

    private static func unexpected() -> RemoteClientError {
        RemoteClientError.protocolViolation("the host sent a message out of order")
    }

}

extension RemoteClientError {
    /// Maps the errors below the client onto the client's own error, so callers see one vocabulary. A connection that
    /// failed because the host showed another certificate is an identity change, and one that failed because the pinned
    /// certificate did not pass its checks is a rejected certificate. Neither is a generic failure.
    static func translating(_ error: Error, observation: FingerprintObservation, pinned: HostFingerprint?) -> RemoteClientError {
        switch error {
        case let clientError as RemoteClientError:
            return clientError
        case let transport as RemoteTransportError:
            switch transport {
            case let .connectionFailed(description):
                if let presented = observation.value, let pinned, presented != pinned {
                    return .identityMismatch(presented: presented)
                }
                if let reason = observation.rejection {
                    return .certificateRejected(reason: reason)
                }
                return .connectionFailed(description)
            case .closed:
                return .closed
            case .timedOut:
                return .timedOut
            }
        case let violation as RemoteProtocolViolation:
            return .protocolViolation(String(describing: violation))
        default:
            return .connectionFailed(error.localizedDescription)
        }
    }
}
