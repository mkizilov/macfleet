import Foundation

public enum HeadlessConfigurationError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(path: String, reason: String)
    case invalid(field: String, reason: String)

    public var description: String {
        switch self {
        case let .unreadable(path, reason): "The configuration at \(path) could not be read: \(reason)"
        case let .invalid(field, reason): "\(field): \(reason)"
        }
    }
}

/// Where the agent keeps its secrets: client secrets and the identity passphrase.
public enum SecretStoreChoice: Equatable, Sendable {
    /// The login keychain, under the service `com.macfleet.headless`. Use this for a LaunchAgent.
    case keychain
    /// A JSON file that only the owning account can read. It is checked on every use.
    case protectedFile(path: String)
}

extension SecretStoreChoice: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "keychain":
            self = .keychain
        case "file":
            self = .protectedFile(path: try container.decode(String.self, forKey: .path))
        case let other:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\"\(other)\" is not a secret store; use \"keychain\" or \"file\""
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keychain:
            try container.encode("keychain", forKey: .kind)
        case let .protectedFile(path):
            try container.encode("file", forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

/// The agent's settings. The file holds no secrets. It names where they are kept.
///
/// The agent listens only on `listenAddress`. With no address, it listens nowhere, and it still samples and reports
/// its health. An address must be numeric, must not be a wildcard, and must lie inside `allowedNetworks`, which
/// defaults to loopback and the Tailscale ranges.
public struct HeadlessConfiguration: Codable, Equatable, Sendable {
    public var displayName: String
    public var listenAddress: String?
    public var port: UInt16
    public var identityPath: String?
    public var clientIDs: [String]
    public var secretStore: SecretStoreChoice
    public var samplingIntervalSeconds: Double
    public var allowedNetworks: [String]?
    /// Where the health report is written. Nil uses `~/Library/Application Support/MacFleet/headless/status.json`.
    public var statusPath: String?
    /// Where the diagnostic log is written. Nil uses `~/Library/Logs/MacFleet/headless.log`.
    public var logPath: String?

    private enum CodingKeys: String, CodingKey {
        case displayName, listenAddress, port, identityPath, clientIDs, secretStore
        case samplingIntervalSeconds, allowedNetworks, statusPath, logPath
    }

    /// The fields the documentation lists as optional take the documented defaults when they are absent. Only
    /// `displayName` and `secretStore` are required.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            displayName: try container.decode(String.self, forKey: .displayName),
            listenAddress: try container.decodeIfPresent(String.self, forKey: .listenAddress),
            port: try container.decodeIfPresent(UInt16.self, forKey: .port) ?? RemoteProtocol.defaultPort,
            identityPath: try container.decodeIfPresent(String.self, forKey: .identityPath),
            clientIDs: try container.decodeIfPresent([String].self, forKey: .clientIDs) ?? [],
            secretStore: try container.decode(SecretStoreChoice.self, forKey: .secretStore),
            samplingIntervalSeconds: try container.decodeIfPresent(Double.self, forKey: .samplingIntervalSeconds) ?? 10,
            allowedNetworks: try container.decodeIfPresent([String].self, forKey: .allowedNetworks),
            statusPath: try container.decodeIfPresent(String.self, forKey: .statusPath),
            logPath: try container.decodeIfPresent(String.self, forKey: .logPath)
        )
    }

    public init(
        displayName: String,
        listenAddress: String? = nil,
        port: UInt16 = RemoteProtocol.defaultPort,
        identityPath: String? = nil,
        clientIDs: [String] = [],
        secretStore: SecretStoreChoice,
        samplingIntervalSeconds: Double = 10,
        allowedNetworks: [String]? = nil,
        statusPath: String? = nil,
        logPath: String? = nil
    ) {
        self.displayName = displayName
        self.listenAddress = listenAddress
        self.port = port
        self.identityPath = identityPath
        self.clientIDs = clientIDs
        self.secretStore = secretStore
        self.samplingIntervalSeconds = samplingIntervalSeconds
        self.allowedNetworks = allowedNetworks
        self.statusPath = statusPath
        self.logPath = logPath
    }

    /// Reads and checks a configuration file. A problem is reported with the field it concerns.
    public static func load(from path: String) throws -> HeadlessConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw HeadlessConfigurationError.unreadable(path: path, reason: error.localizedDescription)
        }
        let configuration: HeadlessConfiguration
        do {
            configuration = try JSONDecoder().decode(HeadlessConfiguration.self, from: data)
        } catch {
            throw HeadlessConfigurationError.unreadable(path: path, reason: String(describing: error))
        }
        try configuration.validate()
        return configuration
    }

    /// The networks clients may reach the listener from, and the listener may bind to.
    public func resolvedNetworkPolicy() throws -> RemoteNetworkPolicy {
        guard let allowedNetworks else { return .privateNetworks }
        do {
            return try RemoteNetworkPolicy(cidrs: allowedNetworks)
        } catch {
            throw HeadlessConfigurationError.invalid(field: "allowedNetworks", reason: "every entry must be a CIDR block such as 100.64.0.0/10")
        }
    }

    public func validate() throws {
        guard (1...64).contains(displayName.count) else {
            throw HeadlessConfigurationError.invalid(field: "displayName", reason: "must be 1 to 64 characters")
        }
        guard port > 0 else {
            throw HeadlessConfigurationError.invalid(field: "port", reason: "must be between 1 and 65535")
        }
        guard samplingIntervalSeconds.isFinite, SamplingInterval.allowedRange.contains(samplingIntervalSeconds) else {
            throw HeadlessConfigurationError.invalid(field: "samplingIntervalSeconds", reason: "must be between 0.5 and 3600")
        }
        let policy = try resolvedNetworkPolicy()
        if let listenAddress {
            guard RemoteNetworkPolicy.isAddressLiteral(listenAddress), !RemoteNetworkPolicy.isUnspecified(listenAddress) else {
                throw HeadlessConfigurationError.invalid(
                    field: "listenAddress",
                    reason: "must be one numeric address such as the Tailscale address; a wildcard is not accepted"
                )
            }
            guard policy.allows(address: listenAddress) else {
                throw HeadlessConfigurationError.invalid(
                    field: "listenAddress",
                    reason: "\(listenAddress) is outside allowedNetworks"
                )
            }
            guard identityPath != nil else {
                throw HeadlessConfigurationError.invalid(field: "identityPath", reason: "is required when listenAddress is set")
            }
            guard !clientIDs.isEmpty else {
                throw HeadlessConfigurationError.invalid(field: "clientIDs", reason: "lists no clients, so nothing could connect")
            }
        }
        for clientID in clientIDs where !RemoteCredential.isValidClientID(clientID) {
            throw HeadlessConfigurationError.invalid(field: "clientIDs", reason: "\"\(clientID)\" is not a valid client ID")
        }
        guard Set(clientIDs).count == clientIDs.count else {
            throw HeadlessConfigurationError.invalid(field: "clientIDs", reason: "client IDs must be unique")
        }
    }
}

extension SamplingInterval {
    /// The range a configured sampling interval must fall in. Values outside it are refused, not clamped, so a typo is
    /// visible.
    static let allowedRange: ClosedRange<Double> = minimumSeconds...maximumSeconds
}
