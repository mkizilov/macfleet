import Foundation
import Network

/// What a probe learned about a host before the user decides to trust it.
public struct RemoteProbeResult: Equatable, Sendable {
    public let host: HostIdentity
    /// The certificate the TLS connection presented. The user compares this with `macfleet-headless identity show`.
    public let presentedFingerprint: HostFingerprint
    public let version: ProtocolVersion

    public init(host: HostIdentity, presentedFingerprint: HostFingerprint, version: ProtocolVersion) {
        self.host = host
        self.presentedFingerprint = presentedFingerprint
        self.version = version
    }
}

/// Reads a host's identity for trust-on-first-use pairing. The probe accepts whatever certificate the host presents, so
/// the user can see it, and it sends only the client ID and a nonce. It never sends a proof, so a host that is not the
/// one the user expects learns nothing it could use.
public enum RemoteHostProbe {
    public static func probe(
        endpoint: RemoteEndpoint,
        clientID: String,
        timings: RemoteTimings = .standard
    ) async throws -> RemoteProbeResult {
        guard RemoteCredential.isValidClientID(clientID) else {
            throw RemoteAuthenticationError.invalidClientID
        }
        guard !endpoint.host.isEmpty, let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw RemoteClientError.invalidEndpoint
        }
        let observation = FingerprintObservation()
        let parameters = NWParameters(
            tls: RemoteTLS.clientOptions(pinned: nil, observation: observation),
            tcp: NWProtocolTCP.Options()
        )
        let connection = RemoteConnection(NetworkConnectionHandle(
            connection: NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: parameters)
        ))
        do {
            let result = try await exchange(connection, clientID: clientID, observation: observation, timings: timings)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw RemoteClientError.translating(error, observation: observation, pinned: nil)
        }
    }

    private static func exchange(
        _ connection: RemoteConnection,
        clientID: String,
        observation: FingerprintObservation,
        timings: RemoteTimings
    ) async throws -> RemoteProbeResult {
        try await connection.start(within: timings.handshakeTimeout)
        try await connection.send(.hello(ClientHello(
            clientID: clientID,
            supportedVersions: RemoteProtocol.supportedVersions,
            clientNonce: RemoteNonce.random(RemoteProtocol.nonceBytes)
        )), version: RemoteProtocol.current)

        let envelope = try await connection.receive(within: timings.handshakeTimeout)
        switch envelope.message {
        case let .helloAccepted(hello):
            guard RemoteProtocol.supportedVersions.contains(envelope.version) else {
                throw RemoteClientError.protocolViolation("the host chose a version this client does not offer")
            }
            guard let presented = observation.value else {
                throw RemoteClientError.protocolViolation("the host presented no certificate")
            }
            guard hello.host.fingerprint == presented else {
                throw RemoteClientError.protocolViolation("the host reported an identity that does not match its certificate")
            }
            return RemoteProbeResult(host: hello.host, presentedFingerprint: presented, version: envelope.version)
        case let .error(error):
            throw RemoteClientError.hostRejected(error)
        default:
            throw RemoteClientError.protocolViolation("the host sent a message out of order")
        }
    }
}
