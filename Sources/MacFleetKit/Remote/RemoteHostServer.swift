import Foundation
import Network

/// What a host serves, and who may ask for it.
public struct RemoteHostConfiguration: Sendable {
    public let displayName: String
    public let port: UInt16
    public let credentials: [RemoteCredential]
    public let networkPolicy: RemoteNetworkPolicy
    public let timings: RemoteTimings
    /// Sessions open at once. A connection beyond this is closed before any byte is exchanged.
    public let maximumSessions: Int

    public init(
        displayName: String,
        port: UInt16 = RemoteProtocol.defaultPort,
        credentials: [RemoteCredential],
        networkPolicy: RemoteNetworkPolicy = .privateNetworks,
        timings: RemoteTimings = .standard,
        maximumSessions: Int = 8
    ) {
        let ids = credentials.map(\.clientID)
        precondition(Set(ids).count == ids.count, "each client needs a distinct ID")
        precondition(maximumSessions > 0, "the host must allow at least one session")
        self.displayName = displayName
        self.port = port
        self.credentials = credentials
        self.networkPolicy = networkPolicy
        self.timings = timings
        self.maximumSessions = maximumSessions
    }
}

/// Serves metric snapshots to authenticated clients over TLS. A connection from outside the network policy is closed
/// before the handshake, and nothing is sent to a client until its proof verifies.
public actor RemoteMetricsHost {
    /// The host's fingerprint. Give it to each client once, so the client can pin it.
    public let fingerprint: HostFingerprint

    private let configuration: RemoteHostConfiguration
    private let identity: SecIdentity
    private let provider: any SystemMetricsProviding
    private var listener: NWListener?
    private var sessions: [UUID: Task<Void, Never>] = [:]

    /// Loads the identity from a PKCS#12 bundle in memory. The bundle is the host's private key and certificate, so
    /// keep it readable only by the account that runs the host.
    public init(
        configuration: RemoteHostConfiguration,
        pkcs12: Data,
        passphrase: String,
        provider: any SystemMetricsProviding
    ) throws {
        let imported = try RemoteHostIdentityImport.importIdentity(pkcs12: pkcs12, passphrase: passphrase)
        self.configuration = configuration
        identity = imported.identity
        fingerprint = imported.fingerprint
        self.provider = provider
    }

    public func start() async throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RemoteConfigurationError.invalidPort
        }
        let parameters = NWParameters(
            tls: try RemoteTLS.serverOptions(identity: identity),
            tcp: NWProtocolTCP.Options()
        )
        let listener = try NWListener(using: parameters, on: port)
        let policy = configuration.networkPolicy
        listener.newConnectionHandler = { [weak self] connection in
            guard let address = RemoteNetworkPolicy.address(of: connection.endpoint), policy.allows(address: address) else {
                connection.cancel()
                return
            }
            let handle = NetworkConnectionHandle(connection: connection)
            Task { await self?.accept(handle) }
        }
        try await waitUntilReady(listener)
        self.listener = listener
    }

    /// Sessions open now, including those still in the handshake.
    public var activeSessionCount: Int {
        sessions.count
    }

    /// Stops listening and closes every session.
    public func stop() {
        listener?.cancel()
        listener = nil
        for session in sessions.values {
            session.cancel()
        }
        sessions.removeAll()
    }

    private func waitUntilReady(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: RemoteTransportError.connectionFailed("\(error)"))
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "macfleet.remote.listener"))
        }
    }

    private func accept(_ handle: NetworkConnectionHandle) {
        guard listener != nil, sessions.count < configuration.maximumSessions else {
            handle.connection.cancel()
            return
        }
        let id = UUID()
        let session = RemoteHostSession(
            handle: handle,
            configuration: configuration,
            fingerprint: fingerprint,
            provider: provider
        )
        sessions[id] = Task {
            await session.run()
            self.sessionEnded(id)
        }
    }

    private func sessionEnded(_ id: UUID) {
        sessions[id] = nil
    }
}

/// One client's session: the handshake, then snapshots and heartbeats until either side closes.
actor RemoteHostSession {
    /// A failure the host reports to the client before it closes.
    private struct Refusal: Error {
        let error: RemoteProtocolError
    }

    private let connection: RemoteConnection
    private let configuration: RemoteHostConfiguration
    private let fingerprint: HostFingerprint
    private let provider: any SystemMetricsProviding
    private var version = RemoteProtocol.current
    private var interval = SamplingInterval.interactive

    init(
        handle: NetworkConnectionHandle,
        configuration: RemoteHostConfiguration,
        fingerprint: HostFingerprint,
        provider: any SystemMetricsProviding
    ) {
        connection = RemoteConnection(handle)
        self.configuration = configuration
        self.fingerprint = fingerprint
        self.provider = provider
    }

    func run() async {
        do {
            try await connection.start(within: configuration.timings.handshakeTimeout)
            try await handshake()
            try await streamUntilEitherSideFails()
        } catch {
            await report(error)
        }
        await connection.close()
    }

    /// Hello, negotiation, the host identity, the client's proof, the host's proof, capabilities, then subscribe.
    /// Nothing about the metrics is sent before the client's proof verifies.
    private func handshake() async throws {
        let hello = try await connection.receive(within: configuration.timings.handshakeTimeout)
        guard case let .hello(clientHello) = hello.message else {
            throw refusal(.unexpectedMessage, "The first message must be hello.")
        }
        guard RemoteCredential.isValidClientID(clientHello.clientID) else {
            throw refusal(.malformedMessage, "The client ID is not valid.")
        }
        guard let selected = RemoteNegotiation.select(
            offered: clientHello.supportedVersions,
            supported: RemoteProtocol.supportedVersions
        ) else {
            throw Refusal(error: RemoteProtocolError(
                code: .unsupportedVersion,
                message: "No common protocol version. This host speaks \(RemoteProtocol.supportedVersions.map(\.description).joined(separator: ", ")).",
                retryable: false,
                supportedVersions: RemoteProtocol.supportedVersions
            ))
        }
        version = selected

        let serverNonce = RemoteNonce.random(RemoteProtocol.nonceBytes)
        let identity = HostIdentity(displayName: configuration.displayName, fingerprint: fingerprint)
        try await send(.helloAccepted(HostHello(host: identity, serverNonce: serverNonce)))

        let authentication = try await connection.receive(within: configuration.timings.handshakeTimeout)
        guard case let .authenticate(clientProof) = authentication.message else {
            throw refusal(.unexpectedMessage, "The client must authenticate next.")
        }
        guard let binding = await connection.channelBinding() else {
            throw refusal(.internalError, "The secure channel is not ready.")
        }
        let transcript = RemoteTranscript(
            version: selected,
            clientID: clientHello.clientID,
            clientNonce: clientHello.clientNonce,
            serverNonce: serverNonce,
            hostFingerprint: fingerprint,
            channelBinding: binding
        )
        guard let credential = configuration.credentials.first(where: { $0.clientID == clientHello.clientID }),
              RemoteAuthenticator.isValid(clientProof.proof, for: .client, credential: credential, transcript: transcript)
        else {
            throw refusal(.authenticationFailed, "The client could not be authenticated.")
        }
        try await send(.authenticated(HostProof(
            proof: RemoteAuthenticator.proof(for: .host, credential: credential, transcript: transcript)
        )))

        let capabilities: [RemoteCapability]
        do {
            capabilities = try await sampleSnapshot().capabilities
        } catch {
            capabilities = RemoteMetric.allCases.map {
                RemoteCapability(metric: $0, state: .unavailable(reason: "The host could not take a snapshot."))
            }
        }
        try await send(.capabilities(CapabilityReport(capabilities: capabilities)))

        let subscription = try await connection.receive(within: configuration.timings.handshakeTimeout)
        guard case let .subscribe(request) = subscription.message else {
            throw refusal(.unexpectedMessage, "The client must subscribe after authenticating.")
        }
        interval = SamplingInterval(seconds: request.intervalSeconds)
    }

    /// Reads and writes concurrently. When either side fails, the other is cancelled and the session ends.
    private func streamUntilEitherSideFails() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.readLoop() }
            group.addTask { try await self.writeLoop() }
            try await group.next()
            group.cancelAll()
        }
    }

    private func readLoop() async throws {
        while true {
            let envelope = try await connection.receive(within: configuration.timings.idleTimeout)
            guard envelope.version == version else {
                throw refusal(.malformedMessage, "A message used a version other than the negotiated one.")
            }
            switch envelope.message {
            case let .subscribe(request):
                interval = SamplingInterval(seconds: request.intervalSeconds)
            case .heartbeat, .unknown:
                continue
            case .error:
                return
            default:
                throw refusal(.unexpectedMessage, "This message is not expected from a client.")
            }
        }
    }

    private func writeLoop() async throws {
        var sequence: UInt64 = 0
        var nextSnapshot = MonotonicTime.awakeSeconds()
        var nextHeartbeat = nextSnapshot
        while true {
            try Task.checkCancellation()
            let now = MonotonicTime.awakeSeconds()
            if now >= nextSnapshot {
                try await sendSnapshot()
                nextSnapshot = now + interval.seconds
            }
            if now >= nextHeartbeat {
                sequence += 1
                try await send(.heartbeat(Heartbeat(sequence: sequence, sentAt: Date())))
                nextHeartbeat = now + configuration.timings.heartbeatInterval
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A failed sample is reported as a retryable error, and the session continues.
    private func sendSnapshot() async throws {
        let message: RemoteMessage
        do {
            message = .snapshot(try await sampleSnapshot())
        } catch {
            message = .error(RemoteProtocolError(
                code: .snapshotUnavailable,
                message: error.localizedDescription,
                retryable: true
            ))
        }
        try await send(message)
    }

    private func sampleSnapshot() async throws -> RemoteSnapshot {
        RemoteSnapshot(system: try await provider.snapshot(selection: .default))
    }

    private func send(_ message: RemoteMessage) async throws {
        try await connection.send(message, version: version)
    }

    private func refusal(_ code: RemoteErrorCode, _ message: String) -> Refusal {
        Refusal(error: RemoteProtocolError(code: code, message: message, retryable: false))
    }

    /// Tells the client why the session ends, when there is still a connection to tell. The client may already be gone,
    /// so a failure to deliver this last message is expected and is not an error for the session.
    private func report(_ error: Error) async {
        let final: RemoteProtocolError
        switch error {
        case let refusal as Refusal:
            final = refusal.error
        case let violation as RemoteProtocolViolation:
            final = RemoteProtocolError(
                code: .malformedMessage,
                message: String(describing: violation),
                retryable: false
            )
        case RemoteTransportError.timedOut:
            final = RemoteProtocolError(code: .timedOut, message: "The client stopped responding.", retryable: false)
        default:
            return
        }
        try? await send(.error(final))
    }
}
