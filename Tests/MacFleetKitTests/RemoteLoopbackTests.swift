import Foundation
import Network
import Testing
@testable import MacFleetKit

/// End-to-end sessions over real loopback TLS. Each test takes its own port from 21401 to 21420, and the suite runs one
/// test at a time, so no two listeners overlap.
@Suite("Remote protocol over loopback TLS", .serialized, .timeLimit(.minutes(1)), .enabled(if: RemoteTestSupport.memoryOnlyImportAvailable))
struct RemoteLoopbackTests {
    private func withHost<T>(
        port: UInt16,
        identity: RemoteTestSupport.Identity,
        credentials: [RemoteCredential],
        policy: RemoteNetworkPolicy = .privateNetworks,
        timings: RemoteTimings = .standard,
        _ body: (RemoteMetricsHost) async throws -> T
    ) async throws -> T {
        let configuration = RemoteHostConfiguration(
            displayName: "test-host",
            port: port,
            credentials: credentials,
            networkPolicy: policy,
            timings: timings
        )
        let host = try RemoteMetricsHost(
            configuration: configuration,
            pkcs12: identity.pkcs12,
            passphrase: identity.passphrase,
            provider: MockSystemMetricsProvider()
        )
        try await host.start()
        do {
            let result = try await body(host)
            await host.stop()
            return result
        } catch {
            await host.stop()
            throw error
        }
    }

    private func client(
        port: UInt16,
        credential: RemoteCredential,
        pin: HostFingerprint,
        timings: RemoteTimings = .standard,
        versions: [ProtocolVersion] = RemoteProtocol.supportedVersions
    ) -> RemoteMetricsClient {
        RemoteMetricsClient(
            endpoint: RemoteEndpoint(host: "127.0.0.1", port: port),
            credential: credential,
            pinnedHost: pin,
            timings: timings,
            supportedVersions: versions
        )
    }

    /// Takes the first `count` updates. Leaving the loop cancels the stream, which closes the session.
    private func updates(
        _ count: Int,
        from client: RemoteMetricsClient,
        interval: Double = 0.5
    ) async throws -> [RemoteUpdate] {
        var received: [RemoteUpdate] = []
        for try await update in await client.updates(interval: SamplingInterval(seconds: interval)) {
            received.append(update)
            if received.count == count { break }
        }
        return received
    }

    /// The error that ends a session that should be refused. Fails the test if the session delivers an update.
    private func refusal(from client: RemoteMetricsClient) async throws -> any Error {
        do {
            for try await update in await client.updates(interval: SamplingInterval(seconds: 0.5)) {
                Issue.record("a refused session delivered \(update)")
            }
        } catch {
            return error
        }
        throw RemoteClientError.closed
    }

    private func rawConnection(port: UInt16, pin: HostFingerprint) -> RemoteConnection {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: RemoteTLS.clientOptions(pinned: pin), tcp: NWProtocolTCP.Options())
        )
        return RemoteConnection(NetworkConnectionHandle(connection: connection))
    }

    /// Completes the handshake by hand, so a test can then misbehave on purpose.
    private func authenticateByHand(_ raw: RemoteConnection, credential: RemoteCredential) async throws {
        try await raw.start(within: 5)
        let clientNonce = RemoteNonce.random(RemoteProtocol.nonceBytes)
        try await raw.send(.hello(ClientHello(
            clientID: credential.clientID,
            supportedVersions: RemoteProtocol.supportedVersions,
            clientNonce: clientNonce
        )), version: RemoteProtocol.current)
        let accepted = try await raw.receive(within: 5)
        guard case let .helloAccepted(hostHello) = accepted.message else {
            throw RemoteClientError.protocolViolation("expected helloAccepted")
        }
        let binding = try #require(await raw.channelBinding())
        let transcript = RemoteTranscript(
            version: accepted.version,
            clientID: credential.clientID,
            clientNonce: clientNonce,
            serverNonce: hostHello.serverNonce,
            hostFingerprint: hostHello.host.fingerprint,
            channelBinding: binding
        )
        try await raw.send(.authenticate(ClientProof(
            proof: RemoteAuthenticator.proof(for: .client, credential: credential, transcript: transcript)
        )), version: accepted.version)
        _ = try await raw.receive(within: 5)
        _ = try await raw.receive(within: 5)
        try await raw.send(.subscribe(SubscribeRequest(intervalSeconds: 0.5)), version: accepted.version)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func aPinnedClientReceivesTheHostIdentityCapabilitiesAndSnapshots() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        try await withHost(port: 21401, identity: identity, credentials: [key]) { host in
            #expect(await host.fingerprint == pin)
            let received = try await updates(3, from: client(port: 21401, credential: key, pin: pin))

            guard case let .connected(info)? = received.first else {
                Issue.record("the first update must describe the session")
                return
            }
            #expect(info.host == HostIdentity(displayName: "test-host", fingerprint: pin))
            #expect(info.version == RemoteProtocol.current)
            #expect(info.capabilities == RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot).capabilities)
            #expect(received.dropFirst().first == .snapshot(RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot)))
        }
    }

    @Test func aWrongSecretIsRefusedAndNoMetricsArrive() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let imposter = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        try await withHost(port: 21402, identity: identity, credentials: [key]) { _ in
            let error = try await refusal(from: client(port: 21402, credential: imposter, pin: pin))
            #expect(error as? RemoteClientError == .hostRejected(RemoteProtocolError(
                code: .authenticationFailed,
                message: "The client could not be authenticated.",
                retryable: false
            )))
        }
    }

    @Test func anUnknownClientIsRefusedWithTheSameMessageAsAWrongSecret() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let stranger = try RemoteCredential.generate(clientID: "stranger")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        try await withHost(port: 21403, identity: identity, credentials: [key]) { _ in
            let error = try await refusal(from: client(port: 21403, credential: stranger, pin: pin))
            #expect(error as? RemoteClientError == .hostRejected(RemoteProtocolError(
                code: .authenticationFailed,
                message: "The client could not be authenticated.",
                retryable: false
            )))
        }
    }

    @Test func aWrongPinFailsTheTLSHandshakeBeforeAnythingIsSent() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let wrongPin = HostFingerprint(certificateDER: Data("a different certificate".utf8))
        try await withHost(port: 21404, identity: identity, credentials: [key]) { _ in
            let error = try await refusal(from: client(port: 21404, credential: key, pin: wrongPin))
            // The host showed its real certificate, so the failure names the identity change and the certificate shown.
            guard case let .identityMismatch(presented)? = error as? RemoteClientError else {
                Issue.record("a pin mismatch must report an identity change, got \(error)")
                return
            }
            #expect(presented == HostFingerprint(certificateDER: identity.certificateDER))
        }
    }

    @Test func aClientOutsideTheNetworkPolicyIsDisconnectedBeforeTheHandshake() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        let officeOnly = try RemoteNetworkPolicy(cidrs: ["10.0.0.0/8"])
        try await withHost(port: 21405, identity: identity, credentials: [key], policy: officeOnly) { _ in
            let error = try await refusal(from: client(port: 21405, credential: key, pin: pin))
            switch error as? RemoteClientError {
            case .connectionFailed?, .closed?:
                break
            default:
                Issue.record("a refused network must end the connection, got \(error)")
            }
        }
    }

    @Test func aClientWithNoSharedVersionIsToldWhichVersionsTheHostSpeaks() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        let future = ProtocolVersion(major: 2, minor: 0)
        try await withHost(port: 21406, identity: identity, credentials: [key]) { _ in
            let error = try await refusal(from: client(
                port: 21406,
                credential: key,
                pin: pin,
                versions: [future]
            ))
            guard case let .hostRejected(protocolError)? = error as? RemoteClientError else {
                Issue.record("expected the host to reject the version, got \(error)")
                return
            }
            #expect(protocolError.code == .unsupportedVersion)
            #expect(protocolError.supportedVersions == RemoteProtocol.supportedVersions)
        }
    }

    @Test func aClientThatSendsSubscribeBeforeAuthenticatingGetsNoMetrics() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        try await withHost(port: 21407, identity: identity, credentials: [key]) { _ in
            let raw = rawConnection(port: 21407, pin: pin)
            try await raw.start(within: 5)
            try await raw.send(.subscribe(SubscribeRequest(intervalSeconds: 0.5)), version: RemoteProtocol.current)

            var received: [RemoteMessage] = []
            do {
                while true {
                    received.append(try await raw.receive(within: 5).message)
                }
            } catch {
                // The host closes the session after refusing it, which ends the loop.
            }
            #expect(received.contains { message in
                if case .error = message { true } else { false }
            })
            #expect(!received.contains { message in
                switch message {
                case .snapshot, .capabilities, .helloAccepted, .authenticated: true
                default: false
                }
            })
            await raw.close()
        }
    }

    @Test func aClientThatSaysHelloAndThenWaitsReceivesNoMetrics() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        try await withHost(port: 21408, identity: identity, credentials: [key]) { _ in
            let raw = rawConnection(port: 21408, pin: pin)
            try await raw.start(within: 5)
            try await raw.send(.hello(ClientHello(
                clientID: key.clientID,
                supportedVersions: RemoteProtocol.supportedVersions,
                clientNonce: RemoteNonce.random(RemoteProtocol.nonceBytes)
            )), version: RemoteProtocol.current)
            let accepted = try await raw.receive(within: 5)
            guard case .helloAccepted = accepted.message else {
                Issue.record("expected helloAccepted first")
                return
            }
            // Without a proof there is nothing more to send, so a quiet second is the expected outcome.
            do {
                let next = try await raw.receive(within: 1)
                Issue.record("the host sent \(next.message) before authentication")
            } catch RemoteTransportError.timedOut {
                // The host sent nothing, as required.
            }
            await raw.close()
        }
    }

    @Test func aClientThatGoesSilentIsDisconnectedAfterTheIdleTimeout() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        let timings = RemoteTimings(heartbeatInterval: 0.2, idleTimeout: 1, handshakeTimeout: 5)
        try await withHost(port: 21409, identity: identity, credentials: [key], timings: timings) { _ in
            let raw = rawConnection(port: 21409, pin: pin)
            try await authenticateByHand(raw, credential: key)

            // Send nothing more. The host should close within its idle timeout, well before this read's own deadline.
            let started = MonotonicTime.awakeSeconds()
            do {
                while true {
                    _ = try await raw.receive(within: 5)
                }
            } catch {
                // The host has closed the session, which is the outcome under test.
            }
            let elapsed = MonotonicTime.awakeSeconds() - started
            #expect(elapsed < 4, "the host closed after \(elapsed) seconds of silence")
            await raw.close()
        }
    }

    @Test func heartbeatsKeepAQuietHealthySessionOpenPastTheIdleTimeout() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        let timings = RemoteTimings(heartbeatInterval: 0.2, idleTimeout: 1, handshakeTimeout: 5)
        try await withHost(port: 21410, identity: identity, credentials: [key], timings: timings) { host in
            // Snapshots come every five seconds here, so only heartbeats can keep the session alive for two and a half.
            var iterator = await client(port: 21410, credential: key, pin: pin, timings: timings)
                .updates(interval: SamplingInterval(seconds: 5))
                .makeAsyncIterator()
            _ = try await iterator.next()
            _ = try await iterator.next()
            try await Task.sleep(for: .seconds(2.5))
            #expect(await host.activeSessionCount == 1)
        }
    }

    @Test func cancellingTheStreamEndsTheSessionOnTheHost() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let key = try RemoteCredential.generate(clientID: "laptop-1")
        let pin = HostFingerprint(certificateDER: identity.certificateDER)
        try await withHost(port: 21411, identity: identity, credentials: [key]) { host in
            _ = try await updates(1, from: client(port: 21411, credential: key, pin: pin))
            try await waitUntil { await host.activeSessionCount == 0 }
            #expect(await host.activeSessionCount == 0)
        }
    }
}
