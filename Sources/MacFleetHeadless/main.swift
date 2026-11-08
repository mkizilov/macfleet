import Dispatch
import Foundation
import MacFleetKit

// Exit codes: 0 success, 1 failure or unhealthy, 2 usage or configuration error.
enum Exit {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}

struct UsageError: Error {
    let message: String
}

let usage = """
usage: macfleet-headless <command> [options]

  run --config PATH                    Run the agent until SIGTERM or SIGINT. Exit 0 on a clean stop, 1 on failure.
  status --config PATH                 Print the health report. Exit 0 when healthy, 1 when not, 2 when there is none.
  version                              Print the version and the remote protocol version.
  check --config PATH                  Validate the configuration without starting the agent. Exit 0 when valid.
  addresses                            List this Mac's addresses, for choosing a listenAddress.
  identity show --config PATH          Print the host fingerprint that clients must pin.
  identity passphrase --config PATH    Store the identity passphrase, read from standard input.
  credential add --config PATH --client ID [--replace]
                                       Create a client secret, store it, and print it once.
  credential remove --config PATH --client ID
  fetch --host HOST --port PORT --client ID --pin FINGERPRINT --secret-file PATH [--count N]
                                       Connect as a client and print snapshots as JSON lines.
"""

func say(_ text: String) {
    print(text)
}

func complain(_ text: String) {
    FileHandle.standardError.write(Data("macfleet-headless: \(text)\n".utf8))
}

func flagValue(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

func requiredFlag(_ flag: String, in arguments: [String]) throws -> String {
    guard let value = flagValue(flag, in: arguments) else {
        throw UsageError(message: "\(flag) is required")
    }
    return value
}

func homeDirectoryPath() -> String {
    FileManager.default.homeDirectoryForCurrentUser.path
}

func loadConfiguration(_ arguments: [String]) throws -> HeadlessConfiguration {
    try HeadlessConfiguration.load(from: requiredFlag("--config", in: arguments))
}

func secretStore(for configuration: HeadlessConfiguration) -> any AgentSecretStore {
    switch configuration.secretStore {
    case .keychain:
        KeychainSecretStore()
    case let .protectedFile(path):
        ProtectedFileSecretStore(path: path)
    }
}

func statusPath(for configuration: HeadlessConfiguration) -> String {
    configuration.statusPath ?? "\(homeDirectoryPath())/Library/Application Support/MacFleet/headless/status.json"
}

func logPath(for configuration: HeadlessConfiguration) -> String {
    configuration.logPath ?? "\(homeDirectoryPath())/Library/Logs/MacFleet/headless.log"
}

func runAgent(_ arguments: [String]) async throws -> Int32 {
    let configuration = try loadConfiguration(arguments)
    let log = try StructuredLog(path: logPath(for: configuration))
    let agent = HeadlessAgent(
        configuration: configuration,
        secrets: secretStore(for: configuration),
        log: log,
        samplingProvider: ProcessSystemMetricsProvider(),
        statusPath: statusPath(for: configuration)
    )

    // A SIGTERM or SIGINT is a request to stop, not a crash. The default action is ignored so the dispatch sources see it.
    var signals: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            Task { await agent.requestShutdown() }
        }
        source.resume()
        signals.append(source)
    }

    let result: Int32
    do {
        try await agent.run()
        result = Exit.success
    } catch {
        complain("the agent stopped with an error: \(error)")
        result = Exit.failure
    }
    withExtendedLifetime(signals) {}
    return result
}

func statusCommand(_ arguments: [String]) throws -> Int32 {
    let configuration = try loadConfiguration(arguments)
    guard let health = try HeadlessStatusFile.read(from: statusPath(for: configuration)) else {
        complain("no status report exists yet at \(statusPath(for: configuration))")
        return Exit.usage
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    encoder.dateEncodingStrategy = .iso8601
    say(String(decoding: try encoder.encode(health), as: UTF8.self))
    switch HeadlessHealthEvaluation.verdict(health, now: Date()) {
    case .healthy:
        say("healthy")
        return Exit.success
    case let .unhealthy(reason):
        complain("unhealthy: \(reason)")
        return Exit.failure
    }
}

func addressesCommand() -> Int32 {
    for address in LocalAddresses.current() {
        say("\(address.kind.rawValue)\t\(address.interface)\t\(address.address)")
    }
    return Exit.success
}

func identityCommand(_ arguments: [String]) throws -> Int32 {
    let configuration = try loadConfiguration(arguments)
    let secrets = secretStore(for: configuration)
    switch arguments.dropFirst().first {
    case "show":
        guard let identityPath = configuration.identityPath else {
            throw UsageError(message: "identityPath is not set in the configuration")
        }
        let identity = try ProtectedFile.read(identityPath)
        guard let passphrase = try secrets.secret(for: AgentSecretAccount.identityPassphrase) else {
            throw UsageError(message: "no identity passphrase is stored; run `identity passphrase` first")
        }
        let fingerprint = try RemoteIdentityReader.fingerprint(
            pkcs12: identity,
            passphrase: String(decoding: passphrase, as: UTF8.self)
        )
        say(fingerprint.description)
        return Exit.success
    case "passphrase":
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !text.isEmpty else {
            throw UsageError(message: "the passphrase on standard input is empty")
        }
        try secrets.setSecret(Data(text.utf8), for: AgentSecretAccount.identityPassphrase)
        complain("the identity passphrase is stored")
        return Exit.success
    default:
        throw UsageError(message: "identity needs `show` or `passphrase`")
    }
}

func credentialCommand(_ arguments: [String]) throws -> Int32 {
    let configuration = try loadConfiguration(arguments)
    let secrets = secretStore(for: configuration)
    let clientID = try requiredFlag("--client", in: arguments)
    guard configuration.clientIDs.contains(clientID) else {
        throw UsageError(message: "add \"\(clientID)\" to clientIDs in the configuration first")
    }
    let account = AgentSecretAccount.client(clientID)
    switch arguments.dropFirst().first {
    case "add":
        if try secrets.secret(for: account) != nil, !arguments.contains("--replace") {
            throw UsageError(message: "a secret already exists for \"\(clientID)\"; pass --replace to rotate it")
        }
        let credential = try RemoteCredential.generate(clientID: clientID)
        try secrets.setSecret(credential.secret, for: account)
        say(credential.secret.base64EncodedString())
        complain("copy the secret above into the client's protected secret file; it is shown only once")
        return Exit.success
    case "remove":
        try secrets.removeSecret(for: account)
        complain("the secret for \"\(clientID)\" is removed")
        return Exit.success
    default:
        throw UsageError(message: "credential needs `add` or `remove`")
    }
}

func fetchCommand(_ arguments: [String]) async throws -> Int32 {
    let host = try requiredFlag("--host", in: arguments)
    guard let port = UInt16(try requiredFlag("--port", in: arguments)), port > 0 else {
        throw UsageError(message: "--port must be between 1 and 65535")
    }
    let clientID = try requiredFlag("--client", in: arguments)
    let pinText = try requiredFlag("--pin", in: arguments)
    guard let pin = HostFingerprint(string: pinText) else {
        throw UsageError(message: "--pin must look like SHA256: followed by 64 hexadecimal digits")
    }
    let secretFile = try requiredFlag("--secret-file", in: arguments)
    let encoded = String(decoding: try ProtectedFile.read(secretFile), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let secret = Data(base64Encoded: encoded) else {
        throw UsageError(message: "the secret file does not hold a base64 secret")
    }
    let count = Int(flagValue("--count", in: arguments) ?? "1") ?? 1
    let credential = try RemoteCredential(clientID: clientID, secret: secret)
    let client = RemoteMetricsClient(
        endpoint: RemoteEndpoint(host: host, port: port),
        credential: credential,
        pinnedHost: pin
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .secondsSince1970
    var received = 0
    for try await update in await client.updates(interval: SamplingInterval(seconds: 2)) {
        switch update {
        case let .connected(info):
            complain("connected to \(info.host.displayName) (\(info.host.fingerprint)) using protocol \(info.version)")
        case let .snapshot(snapshot):
            say(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
            received += 1
            if received >= count {
                return Exit.success
            }
        }
    }
    return Exit.success
}

func checkCommand(_ arguments: [String]) throws -> Int32 {
    let configuration = try loadConfiguration(arguments)
    say("configuration is valid: \(configuration.displayName), port \(configuration.port)")
    return Exit.success
}

func dispatch(_ arguments: [String]) async throws -> Int32 {
    switch arguments.first {
    case "run":
        return try await runAgent(arguments)
    case "status":
        return try statusCommand(arguments)
    case "version":
        say(MacFleetVersion.description)
        return Exit.success
    case "check":
        return try checkCommand(arguments)
    case "addresses":
        return addressesCommand()
    case "identity":
        return try identityCommand(arguments)
    case "credential":
        return try credentialCommand(arguments)
    case "fetch":
        return try await fetchCommand(arguments)
    default:
        complain("unknown or missing command")
        say(usage)
        return Exit.usage
    }
}

let commandLine = Array(CommandLine.arguments.dropFirst())
do {
    exit(try await dispatch(commandLine))
} catch let error as UsageError {
    complain(error.message)
    exit(Exit.usage)
} catch let error as HeadlessConfigurationError {
    complain(error.description)
    exit(Exit.usage)
} catch let error as RemoteClientError {
    complain("the connection failed: \(error)")
    exit(Exit.failure)
} catch {
    complain(String(describing: error))
    exit(Exit.failure)
}
