import Foundation
import MacFleetKit
import MacFleetState
import Testing

/// The fleet against real TLS hosts on loopback: the real client, the real identity probe, and the real connection
/// loops. Only the clock is controlled, so each retry happens when a test fires it. Ports come from 21444 to 21450, and
/// the suite runs serially.
@MainActor
@Suite("Multi-Mac fleet over loopback TLS", .serialized, .enabled(if: RemoteTestSupport.memoryOnlyImportAvailable))
struct RemoteFleetIntegrationTests {
    private let timings = RemoteTimings(heartbeatInterval: 0.5, idleTimeout: 5, handshakeTimeout: 5)

    private func startHost(
        port: UInt16,
        identity: RemoteTestSupport.Identity,
        name: String,
        credentials: [RemoteCredential]
    ) async throws -> RemoteMetricsHost {
        let host = try RemoteMetricsHost(
            configuration: RemoteHostConfiguration(
                displayName: name,
                port: port,
                listenAddress: "127.0.0.1",
                credentials: credentials,
                timings: timings
            ),
            pkcs12: identity.pkcs12,
            passphrase: identity.passphrase,
            provider: MockSystemMetricsProvider()
        )
        try await host.start()
        return host
    }

    private func makeModel(scheduler: FleetManualScheduler) -> FleetOverviewModel {
        FleetOverviewModel(
            store: MemoryRemoteHostStore(),
            secrets: MemoryAgentSecretStore(),
            opener: MetricsClientSessionOpener(timings: timings),
            prober: MetricsRemoteHostProber(),
            scheduling: fleetScheduling(scheduler)
        )
    }

    /// Fills the pairing form and waits for the probe. Returns once the identity is shown for confirmation.
    private func probeMac(
        _ model: FleetOverviewModel,
        label: String,
        port: UInt16,
        credential: RemoteCredential
    ) async throws {
        model.setDraft(.label, label)
        model.setDraft(.host, "127.0.0.1")
        model.setDraft(.port, String(port))
        model.setDraft(.clientID, credential.clientID)
        model.setDraft(.secret, credential.secret.base64EncodedString())
        model.beginPairing()
        try await fleetEventually {
            switch model.pairing {
            case .confirming, .failed: true
            default: false
            }
        }
    }

    /// Probes and saves a Mac, and waits until it is connected.
    private func pairAndConnect(
        _ model: FleetOverviewModel,
        label: String,
        port: UInt16,
        credential: RemoteCredential
    ) async throws -> UUID {
        try await probeMac(model, label: label, port: port, credential: credential)
        model.confirmPairing()
        try await fleetEventually { model.records.contains { $0.label == label } }
        let id = try #require(model.records.first { $0.label == label }?.id)
        try await fleetEventually { model.statuses[id]?.state == .online }
        return id
    }

    @Test func aMacIsPairedByProbeAndThenWatchedWithItsMetrics() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let credential = try RemoteCredential.generate(clientID: "laptop-1")
        let host = try await startHost(port: 21444, identity: identity, name: "Integration Mac", credentials: [credential])
        defer { Task { await host.stop() } }
        let scheduler = FleetManualScheduler()
        let model = makeModel(scheduler: scheduler)
        model.start()

        try await probeMac(model, label: "Integration", port: 21444, credential: credential)
        guard case let .confirming(pending) = model.pairing else {
            Issue.record("the probe must show the identity for confirmation, got \(model.pairing)")
            await model.stopAll()
            return
        }
        #expect(pending.probe.presentedFingerprint == HostFingerprint(certificateDER: identity.certificateDER))
        #expect(pending.probe.host.displayName == "Integration Mac")
        #expect(model.records.isEmpty, "nothing is saved before the user confirms")

        model.confirmPairing()
        try await fleetEventually { model.statuses.values.contains { $0.state == .online && $0.snapshot != nil } }
        let id = try #require(model.records.first?.id)
        let status = try #require(model.statuses[id])
        #expect(status.hostName == "Integration Mac")
        #expect(status.snapshot?.memory == RemoteSnapshot(system: MockSystemMetricsProvider.sampleSnapshot).memory)
        #expect(status.capabilities?.count == RemoteMetric.allCases.count)

        let card = try #require(model.presentation.cards.first { $0.hostID == id })
        #expect(card.indicator == .online)
        #expect(card.metrics.count == 5)
        #expect(await scheduler.requested.isEmpty)
        await model.stopAll()
    }

    @Test func aMistypedSecretIsRefusedAndNotRetried() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let real = try RemoteCredential.generate(clientID: "laptop-1")
        let mistyped = try RemoteCredential.generate(clientID: "laptop-1")
        let host = try await startHost(port: 21445, identity: identity, name: "Studio", credentials: [real])
        defer { Task { await host.stop() } }
        let scheduler = FleetManualScheduler()
        let model = makeModel(scheduler: scheduler)
        model.start()

        try await probeMac(model, label: "Studio", port: 21445, credential: mistyped)
        model.confirmPairing()
        try await fleetEventually { model.records.count == 1 }
        let id = try #require(model.records.first?.id)
        try await fleetEventually { model.statuses[id]?.state == .stopped(.authenticationFailed) }

        #expect(await scheduler.requested.isEmpty, "a wrong secret must not be retried")
        let card = try #require(model.presentation.cards.first { $0.hostID == id })
        #expect(card.failureText?.contains("rejected the client secret") == true)
        await model.stopAll()
    }

    @Test func aReplacedCertificateStopsTheConnectionUntilTheNewIdentityIsConfirmed() async throws {
        let original = try RemoteTestSupport.makeIdentity()
        let replacement = try RemoteTestSupport.makeIdentity()
        let credential = try RemoteCredential.generate(clientID: "laptop-1")
        let first = try await startHost(port: 21447, identity: original, name: "Studio", credentials: [credential])
        let scheduler = FleetManualScheduler()
        let model = makeModel(scheduler: scheduler)
        model.start()
        let id = try await pairAndConnect(model, label: "Studio", port: 21447, credential: credential)
        let oldPin = HostFingerprint(certificateDER: original.certificateDER)
        let newPin = HostFingerprint(certificateDER: replacement.certificateDER)

        // The Mac is reinstalled: the address now answers with a different certificate.
        await first.stop()
        try await fleetEventually {
            if case .reconnecting = model.statuses[id]?.state { true } else { false }
        }
        #expect(await scheduler.awaitPending(atLeast: 1))
        let second = try await startHost(port: 21447, identity: replacement, name: "Studio", credentials: [credential])
        defer { Task { await second.stop() } }
        await scheduler.fire()

        try await fleetEventually {
            if case .stopped(.identityChanged) = model.statuses[id]?.state { true } else { false }
        }
        #expect(model.statuses[id]?.state == .stopped(.identityChanged(presented: newPin)))
        #expect(model.records.first?.pinnedFingerprint == oldPin, "the old pin is kept until the user confirms")
        #expect(model.presentation.cards.first { $0.hostID == id }?.actions == [.trustAgain, .remove])

        model.beginTrustAgain(id)
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }
        guard case let .confirming(pending) = model.pairing else { return }
        #expect(pending.probe.presentedFingerprint == newPin)

        model.confirmPairing()
        try await fleetEventually { model.statuses[id]?.state == .online }
        #expect(model.records.first?.pinnedFingerprint == newPin)
        await model.stopAll()
    }

    @Test func aMacThatIsDownIsRetriedWithBackoffUntilItAnswers() async throws {
        let identity = try RemoteTestSupport.makeIdentity()
        let credential = try RemoteCredential.generate(clientID: "laptop-1")
        let host = try await startHost(port: 21448, identity: identity, name: "Studio", credentials: [credential])
        let scheduler = FleetManualScheduler()
        let model = makeModel(scheduler: scheduler)
        model.start()
        let id = try await pairAndConnect(model, label: "Studio", port: 21448, credential: credential)

        await host.stop()
        // The first retry waits the base delay. Each later one waits twice as long.
        try await fleetEventually {
            if case .reconnecting(attempt: 1, _, _) = model.statuses[id]?.state { true } else { false }
        }
        #expect(await scheduler.awaitPending(atLeast: 1))
        await scheduler.fire()

        try await fleetEventually {
            if case .reconnecting(attempt: 2, _, _) = model.statuses[id]?.state { true } else { false }
        }
        #expect(model.presentation.cards.first { $0.hostID == id }?.failureText?.contains("did not answer") == true)
        #expect(await scheduler.awaitPending(atLeast: 1))
        #expect(await scheduler.requested == [.seconds(2), .seconds(4)])

        let back = try await startHost(port: 21448, identity: identity, name: "Studio", credentials: [credential])
        defer { Task { await back.stop() } }
        await scheduler.fire()
        try await fleetEventually { model.statuses[id]?.state == .online }
        await model.stopAll()
    }

    @Test func twoMacsConnectAtOnceAndAFailureInOneLeavesTheOtherOnline() async throws {
        let alphaIdentity = try RemoteTestSupport.makeIdentity()
        let betaIdentity = try RemoteTestSupport.makeIdentity()
        let alphaCredential = try RemoteCredential.generate(clientID: "laptop-1")
        let betaCredential = try RemoteCredential.generate(clientID: "laptop-1")
        let alpha = try await startHost(port: 21449, identity: alphaIdentity, name: "Alpha Mac", credentials: [alphaCredential])
        let beta = try await startHost(port: 21450, identity: betaIdentity, name: "Beta Mac", credentials: [betaCredential])
        defer {
            Task {
                await alpha.stop()
                await beta.stop()
            }
        }
        let scheduler = FleetManualScheduler()
        let model = makeModel(scheduler: scheduler)
        model.start()
        let alphaID = try await pairAndConnect(model, label: "Alpha", port: 21449, credential: alphaCredential)
        let betaID = try await pairAndConnect(model, label: "Beta", port: 21450, credential: betaCredential)

        // Both are online together, each reporting its own name.
        #expect(model.statuses[alphaID]?.hostName == "Alpha Mac")
        #expect(model.statuses[betaID]?.hostName == "Beta Mac")

        await alpha.stop()
        try await fleetEventually {
            if case .reconnecting = model.statuses[alphaID]?.state { true } else { false }
        }
        // Give Beta a moment to be affected if it were going to be. It stays online.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.statuses[betaID]?.state == .online)

        let cards = model.presentation.cards
        #expect(cards.first { $0.hostID == alphaID }?.indicator == .offline)
        #expect(cards.first { $0.hostID == betaID }?.indicator == .online)
        await model.stopAll()
    }
}
