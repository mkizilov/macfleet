import Foundation
import Network

/// What a host reports about its own operation. Logs and health reports are built from these, and none of them carries
/// a secret.
public enum RemoteHostEvent: Equatable, Sendable {
    case listening(port: UInt16)
    case connectionRejected(reason: ConnectionRejection, remoteAddress: String?)
    case sessionOpened(session: UUID, remoteAddress: String?)
    case authenticated(session: UUID, clientID: String)
    case authenticationFailed(session: UUID, clientID: String?, reason: AuthenticationFailure)
    case sessionClosed(session: UUID, reason: SessionEnd)
    case snapshotFailed(session: UUID, message: String)
}

public enum ConnectionRejection: String, Equatable, Sendable {
    case outsideNetworkPolicy
    case atCapacity
    case wrongLocalAddress
}

/// Why a handshake failed. The client sees the same refusal for every reason, so only the host's logs distinguish them.
public enum AuthenticationFailure: String, Equatable, Sendable {
    case unknownClient
    case wrongProof
    case malformedHello
}

public enum SessionEnd: Equatable, Sendable {
    case clientClosed
    case timedOut
    case refused(RemoteErrorCode)
    case transportFailed(String)
    case stopped
}

/// What a host serves, and who may ask for it.
public struct RemoteHostConfiguration: Sendable {
    public let displayName: String
    public let port: UInt16
    /// The one address the host listens on. It defaults to loopback, so a host never listens widely unless told to.
    public let listenAddress: String
    public let credentials: [RemoteCredential]
    public let networkPolicy: RemoteNetworkPolicy
    public let timings: RemoteTimings
    /// Sessions open at once. A connection beyond this is closed before any byte is exchanged.
    public let maximumSessions: Int
    public let events: @Sendable (RemoteHostEvent) -> Void

    public init(
        displayName: String,
        port: UInt16 = RemoteProtocol.defaultPort,
        listenAddress: String = "127.0.0.1",
        credentials: [RemoteCredential],
        networkPolicy: RemoteNetworkPolicy = .privateNetworks,
        timings: RemoteTimings = .standard,
        maximumSessions: Int = 8,
        events: @escaping @Sendable (RemoteHostEvent) -> Void = { _ in }
    ) {
        let ids = credentials.map(\.clientID)
        precondition(Set(ids).count == ids.count, "each client needs a distinct ID")
        precondition(maximumSessions > 0, "the host must allow at least one session")
        self.displayName = displayName
        self.port = port
        self.listenAddress = listenAddress
        self.credentials = credentials
        self.networkPolicy = networkPolicy
        self.timings = timings
        self.maximumSessions = maximumSessions
        self.events = events
    }
}

/// Serves metric snapshots to authenticated clients over TLS. The listener is bound to one address. A connection from
/// outside the network policy, or one that reached a different local address, is closed before the handshake, and
/// nothing is sent to a client until its proof verifies.
public actor RemoteMetricsHost {
    /// The host's fingerprint. Give it to each client once, so the client can pin it.
    public let fingerprint: HostFingerprint

    private let configuration: RemoteHostConfiguration
    private let identity: SecIdentity
    private let provider: any SystemMetricsProviding
    private var listener: NWListener?
    private var sessions: [UUID: (session: RemoteHostSession, task: Task<Void, Never>)] = [:]

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
        let address = configuration.listenAddress
        guard RemoteNetworkPolicy.isAddressLiteral(address), !RemoteNetworkPolicy.isUnspecified(address) else {
            throw RemoteConfigurationError.invalidListenAddress(address)
        }
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw RemoteConfigurationError.invalidPort
        }
        let parameters = NWParameters(
            tls: try RemoteTLS.serverOptions(identity: identity),
            tcp: NWProtocolTCP.Options()
        )
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(address), port: port)
        let listener = try NWListener(using: parameters)
        let policy = configuration.networkPolicy
        let events = configuration.events
        listener.newConnectionHandler = { [weak self] connection in
            let remote = RemoteNetworkPolicy.address(of: connection.endpoint)
            guard let remote, policy.allows(address: remote) else {
                events(.connectionRejected(reason: .outsideNetworkPolicy, remoteAddress: remote))
                connection.cancel()
                return
            }
            let handle = NetworkConnectionHandle(connection: connection, remoteAddress: remote)
            Task { await self?.accept(handle) }
        }
        try await waitUntilReady(listener)
        self.listener = listener
        events(.listening(port: listener.port?.rawValue ?? configuration.port))
    }

    /// Sessions open now, including those still in the handshake.
    public var activeSessionCount: Int {
        sessions.count
    }

    /// Tells each client the host is shutting down, gives them a moment to read it, then closes every session. Returns
    /// once each session has finished, so every session's close is recorded before `stop` returns.
    public func stop() async {
        listener?.cancel()
        listener = nil
        let live = Array(sessions.values)
        for entry in live {
            await entry.session.announceShutdown()
        }
        if !live.isEmpty {
            try? await Task.sleep(for: RemoteTimings.shutdownGrace)
        }
        for entry in live {
            entry.task.cancel()
        }
        for entry in live {
            await entry.task.value
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
        guard listener != nil else {
            handle.connection.cancel()
            return
        }
        guard sessions.count < configuration.maximumSessions else {
            configuration.events(.connectionRejected(reason: .atCapacity, remoteAddress: handle.remoteAddress))
            handle.connection.cancel()
            return
        }
        let id = UUID()
        let session = RemoteHostSession(
            id: id,
            handle: handle,
            configuration: configuration,
            fingerprint: fingerprint,
            provider: provider
        )
        let task = Task {
            await session.run()
            self.sessionEnded(id)
        }
        sessions[id] = (session, task)
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

    private let id: UUID
    private let connection: RemoteConnection
    private let configuration: RemoteHostConfiguration
    private let fingerprint: HostFingerprint
    private let provider: any SystemMetricsProviding
    private let remoteAddress: String?
    private var version = RemoteProtocol.current
    private var interval = SamplingInterval.interactive

    init(
        id: UUID,
        handle: NetworkConnectionHandle,
        configuration: RemoteHostConfiguration,
        fingerprint: HostFingerprint,
        provider: any SystemMetricsProviding
    ) {
        self.id = id
        connection = RemoteConnection(handle)
        self.configuration = configuration
        self.fingerprint = fingerprint
        self.provider = provider
        remoteAddress = handle.remoteAddress
    }

    func run() async {
        configuration.events(.sessionOpened(session: id, remoteAddress: remoteAddress))
        var end = SessionEnd.clientClosed
        do {
            try await connection.start(within: configuration.timings.handshakeTimeout)
            try await verifyLocalAddress()
            try await handshake()
            try await streamUntilEitherSideFails()
        } catch {
            end = await report(error)
        }
        await connection.close()
        configuration.events(.sessionClosed(session: id, reason: end))
    }

    /// Tells the client the host is stopping. The client may already be gone, so failing to deliver this is expected.
    func announceShutdown() async {
        try? await send(.error(RemoteProtocolError(
            code: .shuttingDown,
            message: "The host is shutting down.",
            retryable: true
        )))
    }

    /// The listener is bound to one address. A connection that arrived on any other local address is closed.
    private func verifyLocalAddress() async throws {
        guard let local = await connection.localAddress(),
              RemoteNetworkPolicy.sameAddress(local, configuration.listenAddress)
        else {
            configuration.events(.connectionRejected(reason: .wrongLocalAddress, remoteAddress: remoteAddress))
            throw RemoteTransportError.connectionFailed("the connection arrived on an unexpected local address")
        }
    }

    /// Hello, negotiation, the host identity, the client's proof, the host's proof, capabilities, then subscribe.
    /// Nothing about the metrics is sent before the client's proof verifies.
    private func handshake() async throws {
        let hello = try await connection.receive(within: configuration.timings.handshakeTimeout)
        guard case let .hello(clientHello) = hello.message else {
            throw refusal(.unexpectedMessage, "The first message must be hello.")
        }
        guard RemoteCredential.isValidClientID(clientHello.clientID) else {
            configuration.events(.authenticationFailed(session: id, clientID: nil, reason: .malformedHello))
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
        guard let credential = configuration.credentials.first(where: { $0.clientID == clientHello.clientID }) else {
            configuration.events(.authenticationFailed(session: id, clientID: clientHello.clientID, reason: .unknownClient))
            throw refusal(.authenticationFailed, "The client could not be authenticated.")
        }
        guard RemoteAuthenticator.isValid(clientProof.proof, for: .client, credential: credential, transcript: transcript) else {
            configuration.events(.authenticationFailed(session: id, clientID: clientHello.clientID, reason: .wrongProof))
            throw refusal(.authenticationFailed, "The client could not be authenticated.")
        }
        configuration.events(.authenticated(session: id, clientID: clientHello.clientID))
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
            configuration.events(.snapshotFailed(session: id, message: error.localizedDescription))
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

    /// Tells the client why the session ends, when there is still a connection to tell, and names the end for the
    /// host's log. A stopped session was cancelled by the host, so it sends nothing more.
    private func report(_ error: Error) async -> SessionEnd {
        if Task.isCancelled {
            return .stopped
        }
        switch error {
        case let refusal as Refusal:
            try? await send(.error(refusal.error))
            return .refused(refusal.error.code)
        case let violation as RemoteProtocolViolation:
            try? await send(.error(RemoteProtocolError(
                code: .malformedMessage,
                message: String(describing: violation),
                retryable: false
            )))
            return .refused(.malformedMessage)
        case RemoteTransportError.timedOut:
            try? await send(.error(RemoteProtocolError(
                code: .timedOut,
                message: "The client stopped responding.",
                retryable: false
            )))
            return .timedOut
        case RemoteTransportError.closed:
            return .clientClosed
        case let RemoteTransportError.connectionFailed(description):
            return .transportFailed(description)
        default:
            return .transportFailed(String(describing: error))
        }
    }
}
