import Foundation

/// The host's identity as a client sees it: a display name and the fingerprint of its certificate.
public struct HostIdentity: Codable, Equatable, Sendable {
    public let displayName: String
    public let fingerprint: HostFingerprint

    public init(displayName: String, fingerprint: HostFingerprint) {
        self.displayName = displayName
        self.fingerprint = fingerprint
    }
}

/// First message from a client. Its envelope carries the highest version the client supports.
public struct ClientHello: Codable, Equatable, Sendable {
    public let clientID: String
    public let supportedVersions: [ProtocolVersion]
    public let clientNonce: Data

    public init(clientID: String, supportedVersions: [ProtocolVersion], clientNonce: Data) {
        self.clientID = clientID
        self.supportedVersions = supportedVersions
        self.clientNonce = clientNonce
    }
}

/// The host's answer to `hello`. Its envelope carries the negotiated version.
public struct HostHello: Codable, Equatable, Sendable {
    public let host: HostIdentity
    public let serverNonce: Data

    public init(host: HostIdentity, serverNonce: Data) {
        self.host = host
        self.serverNonce = serverNonce
    }
}

/// The client's proof that it holds its secret for this session.
public struct ClientProof: Codable, Equatable, Sendable {
    public let proof: Data

    public init(proof: Data) {
        self.proof = proof
    }
}

/// The host's proof that it also holds the secret. The client checks it before it trusts anything the host sends.
public struct HostProof: Codable, Equatable, Sendable {
    public let proof: Data

    public init(proof: Data) {
        self.proof = proof
    }
}

public struct CapabilityReport: Codable, Equatable, Sendable {
    public let capabilities: [RemoteCapability]

    public init(capabilities: [RemoteCapability]) {
        self.capabilities = capabilities
    }
}

public struct SubscribeRequest: Codable, Equatable, Sendable {
    public let intervalSeconds: Double

    public init(intervalSeconds: Double) {
        self.intervalSeconds = intervalSeconds
    }
}

public struct Heartbeat: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let sentAt: Date

    public init(sequence: UInt64, sentAt: Date) {
        self.sequence = sequence
        self.sentAt = sentAt
    }
}

/// Why a peer refused or failed. Retryable errors leave the session open.
public struct RemoteProtocolError: Codable, Equatable, Sendable {
    public let code: RemoteErrorCode
    public let message: String
    public let retryable: Bool
    /// Set with `unsupportedVersion`, so the client can say which versions the host speaks.
    public let supportedVersions: [ProtocolVersion]?

    public init(code: RemoteErrorCode, message: String, retryable: Bool, supportedVersions: [ProtocolVersion]? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.supportedVersions = supportedVersions
    }
}

public enum RemoteErrorCode: String, Codable, Equatable, Sendable {
    case unsupportedVersion
    case authenticationFailed
    case malformedMessage
    case unexpectedMessage
    case frameTooLarge
    case snapshotUnavailable
    case timedOut
    case internalError
    /// A code from a newer peer. It is reported as-is and never treated as fatal by itself.
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RemoteErrorCode(rawValue: raw) ?? .unrecognized
    }
}

/// One message on the wire, after its envelope has been decoded.
public enum RemoteMessage: Equatable, Sendable {
    case hello(ClientHello)
    case helloAccepted(HostHello)
    case authenticate(ClientProof)
    case authenticated(HostProof)
    case capabilities(CapabilityReport)
    case subscribe(SubscribeRequest)
    case snapshot(RemoteSnapshot)
    case heartbeat(Heartbeat)
    case error(RemoteProtocolError)
    /// A message type this build does not know. It is ignored after the handshake, so a newer peer can add messages.
    case unknown(type: String)
}

/// A decoded message with the version its envelope carried.
public struct RemoteEnvelope: Equatable, Sendable {
    public let version: ProtocolVersion
    public let message: RemoteMessage

    public init(version: ProtocolVersion, message: RemoteMessage) {
        self.version = version
        self.message = message
    }
}
