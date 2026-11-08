import Foundation
import Testing
@testable import MacFleetKit

private func valid(
    listenAddress: String? = nil,
    identityPath: String? = nil,
    clientIDs: [String] = [],
    displayName: String = "studio",
    port: UInt16 = 21440,
    interval: Double = 10,
    allowedNetworks: [String]? = nil
) -> HeadlessConfiguration {
    HeadlessConfiguration(
        displayName: displayName,
        listenAddress: listenAddress,
        port: port,
        identityPath: identityPath,
        clientIDs: clientIDs,
        secretStore: .keychain,
        samplingIntervalSeconds: interval,
        allowedNetworks: allowedNetworks
    )
}

private func expectInvalid(_ field: String, _ configuration: HeadlessConfiguration, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try configuration.validate()
        Issue.record("\(field) should be refused", sourceLocation: sourceLocation)
    } catch let HeadlessConfigurationError.invalid(reported, _) {
        #expect(reported == field, sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

@Suite("Headless configuration")
struct HeadlessConfigurationTests {
    @Test func noListenAddressIsValidAndMeansNoListener() throws {
        try valid().validate()
    }

    @Test func loopbackAndTailscaleAddressesAreAccepted() throws {
        try valid(listenAddress: "127.0.0.1", identityPath: "/x", clientIDs: ["laptop-1"]).validate()
        try valid(listenAddress: "100.100.20.30", identityPath: "/x", clientIDs: ["laptop-1"]).validate()
    }

    @Test func aWildcardListenAddressIsRefused() {
        expectInvalid("listenAddress", valid(listenAddress: "0.0.0.0", identityPath: "/x", clientIDs: ["laptop-1"]))
        expectInvalid("listenAddress", valid(listenAddress: "::", identityPath: "/x", clientIDs: ["laptop-1"]))
    }

    @Test func aPublicAddressIsRefusedUnlessAllowedNetworksPermitsIt() throws {
        expectInvalid("listenAddress", valid(listenAddress: "8.8.8.8", identityPath: "/x", clientIDs: ["laptop-1"]))
        try valid(
            listenAddress: "8.8.8.8",
            identityPath: "/x",
            clientIDs: ["laptop-1"],
            allowedNetworks: ["8.8.8.0/24"]
        ).validate()
    }

    @Test func aListenerNeedsAnIdentityAndAtLeastOneClient() {
        expectInvalid("identityPath", valid(listenAddress: "127.0.0.1", clientIDs: ["laptop-1"]))
        expectInvalid("clientIDs", valid(listenAddress: "127.0.0.1", identityPath: "/x"))
    }

    @Test func clientIDsMustBeSafeAndUnique() {
        expectInvalid("clientIDs", valid(clientIDs: ["bad id"]))
        expectInvalid("clientIDs", valid(clientIDs: ["laptop-1", "laptop-1"]))
    }

    @Test func displayNameAndPortAreChecked() {
        expectInvalid("displayName", valid(displayName: ""))
        expectInvalid("displayName", valid(displayName: String(repeating: "x", count: 65)))
        expectInvalid("port", valid(port: 0))
    }

    @Test func samplingIntervalOutsideItsRangeIsRefusedNotClamped() {
        expectInvalid("samplingIntervalSeconds", valid(interval: 0.1))
        expectInvalid("samplingIntervalSeconds", valid(interval: 4_000))
        expectInvalid("samplingIntervalSeconds", valid(interval: .nan))
    }

    @Test func badNetworkBlocksAreRefused() {
        expectInvalid("allowedNetworks", valid(allowedNetworks: ["10.0.0.0/33"]))
    }

    @Test func secretStoreChoicesDecodeAndUnknownKindsAreRefused() throws {
        let keychain = try JSONDecoder().decode(SecretStoreChoice.self, from: Data(#"{"kind":"keychain"}"#.utf8))
        #expect(keychain == .keychain)
        let file = try JSONDecoder().decode(SecretStoreChoice.self, from: Data(#"{"kind":"file","path":"/p/s.json"}"#.utf8))
        #expect(file == .protectedFile(path: "/p/s.json"))
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SecretStoreChoice.self, from: Data(#"{"kind":"plaintext"}"#.utf8))
        }
    }

    @Test func aConfigurationFileLoadsAndIsValidated() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        let path = directory.appendingPathComponent("headless.json").path
        let json = """
        {
          "displayName": "studio",
          "listenAddress": "127.0.0.1",
          "port": 21440,
          "identityPath": "/tmp/identity.p12",
          "clientIDs": ["laptop-1"],
          "secretStore": {"kind": "file", "path": "/tmp/secrets.json"},
          "samplingIntervalSeconds": 5
        }
        """
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        let loaded = try HeadlessConfiguration.load(from: path)
        #expect(loaded.listenAddress == "127.0.0.1")
        #expect(loaded.samplingIntervalSeconds == 5)
        #expect(loaded.secretStore == .protectedFile(path: "/tmp/secrets.json"))
    }

    @Test func aMissingOrMalformedFileIsReportedAsUnreadable() throws {
        let directory = try HeadlessScratch.make()
        defer { HeadlessScratch.remove(directory) }
        #expect(throws: HeadlessConfigurationError.self) {
            try HeadlessConfiguration.load(from: directory.appendingPathComponent("absent.json").path)
        }
        let path = directory.appendingPathComponent("broken.json").path
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: path))
        do {
            _ = try HeadlessConfiguration.load(from: path)
            Issue.record("a malformed file must not load")
        } catch HeadlessConfigurationError.unreadable {
            // Expected: the file exists but is not a configuration.
        }
    }
}
