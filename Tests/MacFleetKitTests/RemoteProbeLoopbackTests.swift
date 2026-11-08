import Foundation
import os
import Testing
@testable import MacFleetKit

/// Probes against real TLS hosts on loopback. Ports come from 21441 to 21443, and the suite runs serially.
@Suite("Remote host probe over loopback TLS", .serialized, .enabled(if: RemoteTestSupport.memoryOnlyImportAvailable))
struct RemoteProbeLoopbackTests {
    private func startHost(
        port: UInt16,
        identity: RemoteTestSupport.Identity,
        credential: RemoteCredential,
        events: @escaping @Sendable (RemoteHostEvent) -> Void = { _ in }
    ) async throws -> RemoteMetricsHost {
        let host = try RemoteMetricsHost(
            configuration: RemoteHostConfiguration(
                displayName: "studio-test",
                port: port,
                listenAddress: "127.0.0.1",
                credentials: [credential],
                events: events
            ),
            pkcs12: identity.pkcs12,
            passphrase: identity.passphrase,
            provider: MockSystemMetricsProvider()
        )
        try await host.start()
        return host
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the condition was not met in time")
    }

    @Test func aProbeLearnsTheHostsNameAndCertificateWithoutSendingAProof() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let credential = try RemoteCredential.generate(clientID: "laptop-1")
        let events = OSAllocatedUnfairLock<[RemoteHostEvent]>(initialState: [])
        let host = try await startHost(port: 21441, identity: identity, credential: credential) { event in
            events.withLock { $0.append(event) }
        }
        defer { Task { await host.stop() } }

        let result = try await RemoteHostProbe.probe(
            endpoint: RemoteEndpoint(host: "127.0.0.1", port: 21441),
            clientID: "laptop-1"
        )
        let expected = HostFingerprint(certificateDER: identity.certificateDER)
        #expect(result.host == HostIdentity(displayName: "studio-test", fingerprint: expected))
        #expect(result.presentedFingerprint == expected)
        #expect(result.version == RemoteProtocol.current)

        // The host saw the session open and close, and never saw an authentication attempt.
        try await waitUntil { events.withLock { $0.contains { if case .sessionClosed = $0 { true } else { false } } } }
        let seen = events.withLock { $0 }
        #expect(seen.contains { if case .sessionOpened = $0 { true } else { false } })
        #expect(!seen.contains { if case .authenticated = $0 { true } else { false } })
        #expect(!seen.contains { if case .authenticationFailed = $0 { true } else { false } })
    }

    @Test func aProbeOfAnUnreachableHostFailsAsConnectionFailed() async throws {
        do {
            _ = try await RemoteHostProbe.probe(
                endpoint: RemoteEndpoint(host: "127.0.0.1", port: 21442),
                clientID: "laptop-1"
            )
            Issue.record("nothing listens on 21442, so the probe must fail")
        } catch let error as RemoteClientError {
            guard case .connectionFailed = error else {
                Issue.record("expected connectionFailed, got \(error)")
                return
            }
        }
    }

    @Test func anExpiredHostCertificateIsRejectedByNameNotReportedAsUnreachable() async throws {
        let expired = try RemoteTestSupport.makeExpiredIdentity()
        let credential = try RemoteCredential.generate(clientID: "laptop-1")
        let host = try await startHost(port: 21453, identity: expired, credential: credential)
        defer { Task { await host.stop() } }
        let pin = HostFingerprint(certificateDER: expired.certificateDER)

        // The probe still reads the identity, so the user can see which certificate is expired.
        let probed = try await RemoteHostProbe.probe(endpoint: RemoteEndpoint(host: "127.0.0.1", port: 21453), clientID: "laptop-1")
        #expect(probed.presentedFingerprint == pin)

        // A client that pinned this certificate refuses it, and says which check failed.
        let client = RemoteMetricsClient(
            endpoint: RemoteEndpoint(host: "127.0.0.1", port: 21453),
            credential: credential,
            pinnedHost: pin,
            timings: RemoteTimings(heartbeatInterval: 0.5, idleTimeout: 5, handshakeTimeout: 5)
        )
        do {
            for try await _ in await client.updates(interval: SamplingInterval(seconds: 0.5)) {
                Issue.record("an expired certificate must not connect")
            }
            Issue.record("the session must end with an error")
        } catch let error as RemoteClientError {
            guard case let .certificateRejected(reason) = error else {
                Issue.record("expected certificateRejected, got \(error)")
                return
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test func aProbeRefusesAnInvalidClientIDBeforeConnecting() async throws {
        await #expect(throws: RemoteAuthenticationError.invalidClientID) {
            try await RemoteHostProbe.probe(endpoint: RemoteEndpoint(host: "127.0.0.1", port: 21443), clientID: "bad id")
        }
    }

    @Test func aReplacedCertificateIsVisibleOnTheNextProbe() async throws {
        let before = try RemoteTestSupport.makeIdentity()
        let after = try RemoteTestSupport.makeIdentity()
        let credential = try RemoteCredential.generate(clientID: "laptop-1")

        let first = try await startHost(port: 21443, identity: before, credential: credential)
        let seenBefore = try await RemoteHostProbe.probe(
            endpoint: RemoteEndpoint(host: "127.0.0.1", port: 21443),
            clientID: "laptop-1"
        ).presentedFingerprint
        await first.stop()

        // The same address now serves a different certificate, as after a reinstall.
        let second = try await startHost(port: 21443, identity: after, credential: credential)
        defer { Task { await second.stop() } }
        let seenAfter = try await RemoteHostProbe.probe(
            endpoint: RemoteEndpoint(host: "127.0.0.1", port: 21443),
            clientID: "laptop-1"
        ).presentedFingerprint

        #expect(seenBefore == HostFingerprint(certificateDER: before.certificateDER))
        #expect(seenAfter == HostFingerprint(certificateDER: after.certificateDER))
        #expect(seenBefore != seenAfter)
    }
}
