import Foundation

/// A protocol version as "major.minor". Peers negotiate exact versions. A new minor version can add messages and
/// optional fields that older peers ignore. A new major version is a different protocol, and peers never negotiate
/// across majors.
public struct ProtocolVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses "major.minor". Both parts are non-empty decimal digits.
    public init?(string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
        self.init(major: major, minor: minor)
    }

    public var description: String {
        "\(major).\(minor)"
    }

    public static func < (lhs: ProtocolVersion, rhs: ProtocolVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

extension ProtocolVersion: Codable {
    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let version = ProtocolVersion(string: string) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\"\(string)\" is not a protocol version"
            ))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Constants of protocol version 1.0 and the limits every peer applies.
public enum RemoteProtocol {
    public static let current = ProtocolVersion(major: 1, minor: 0)
    public static let supportedVersions = [current]
    /// The default port for the host. It is not registered with IANA.
    public static let defaultPort: UInt16 = 21440
    /// The largest frame either side accepts. A frame over this size is refused before its body is read.
    public static let maximumFrameBytes = 1_048_576
    public static let nonceBytes = 32
    public static let secretBytes = 32
}

/// Configuration errors, raised when a caller builds a remote configuration with values the protocol cannot use.
public enum RemoteConfigurationError: Error, Equatable, Sendable {
    case invalidTimings
    case invalidNetworkBlock(String)
    case invalidPort
}

/// How often each side speaks and how long it waits. A heartbeat must arrive well inside the idle timeout.
public struct RemoteTimings: Equatable, Sendable {
    public let heartbeatInterval: Double
    public let idleTimeout: Double
    public let handshakeTimeout: Double

    public static let standard = RemoteTimings(heartbeatInterval: 5, idleTimeout: 15, handshakeTimeout: 10)

    public init(heartbeatInterval: Double, idleTimeout: Double, handshakeTimeout: Double) {
        precondition(
            heartbeatInterval > 0 && heartbeatInterval < idleTimeout && handshakeTimeout > 0,
            "heartbeats must be sent before the idle timeout, and the handshake needs a positive deadline"
        )
        self.heartbeatInterval = heartbeatInterval
        self.idleTimeout = idleTimeout
        self.handshakeTimeout = handshakeTimeout
    }
}

/// Chooses the version two peers will speak.
public enum RemoteNegotiation {
    /// The highest version both peers support. Nil when they share none, and the host then reports `unsupportedVersion`
    /// with the versions it does support.
    public static func select(offered: [ProtocolVersion], supported: [ProtocolVersion]) -> ProtocolVersion? {
        Set(offered).intersection(supported).max()
    }
}
