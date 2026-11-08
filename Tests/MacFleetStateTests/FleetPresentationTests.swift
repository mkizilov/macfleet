import Foundation
import MacFleetKit
import MacFleetState
import Testing

private let presentedPin = HostFingerprint(certificateDER: Data("presentation host".utf8))
private let replacedPin = HostFingerprint(certificateDER: Data("presentation replacement".utf8))

private func clock(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .standard)
}

private func record(_ label: String, id: UUID = UUID(), pin: HostFingerprint = presentedPin) -> RemoteHostRecord {
    fleetRecord(id: id, label: label, host: "studio.tail1234.ts.net", port: 21440, clientID: "laptop-1", pin: pin)
}

private func status(
    _ id: UUID,
    _ state: RemoteConnectionState,
    name: String? = nil,
    snapshot: RemoteSnapshot? = nil
) -> RemoteHostStatus {
    RemoteHostStatus(
        hostID: id,
        state: state,
        hostName: name,
        capabilities: nil,
        snapshot: snapshot,
        receivedAt: snapshot == nil ? nil : fleetEpoch
    )
}

private func overview(
    local: RemoteSnapshot? = nil,
    records: [RemoteHostRecord] = [],
    statuses: [UUID: RemoteHostStatus] = [:],
    pairing: PairingState = .idle,
    draft: PairingDraft = PairingDraft(),
    notice: String? = nil,
    canAddMore: Bool = true
) -> FleetOverviewPresentation {
    FleetOverviewPresentation(
        local: local,
        records: records,
        statuses: statuses,
        pairing: pairing,
        draft: draft,
        notice: notice,
        canAddMore: canAddMore
    )
}

@Suite("Fleet presentation: the unified dashboard")
struct FleetDashboardPresentationTests {
    @Test func theLocalMacIsFirstAndRemoteMacsFollowInNameOrder() {
        let beta = record("beta")
        let alpha = record("Alpha")
        let gamma = record("gamma")
        let cards = overview(records: [beta, gamma, alpha]).cards
        #expect(cards.map(\.title) == ["This Mac", "Alpha", "beta", "gamma"])
        #expect(cards.first?.hostID == nil)
        #expect(cards.dropFirst().compactMap(\.hostID) == [alpha.id, beta.id, gamma.id])
    }

    @Test func theLocalCardWaitsForItsFirstSampleThenShowsFiveMetrics() {
        let waiting = overview().cards[0]
        #expect(waiting.statusText == "Waiting for the first sample")
        #expect(waiting.metrics.isEmpty)

        let sampled = overview(local: fleetSnapshot(cpu: 0.25)).cards[0]
        #expect(sampled.indicator == .local)
        #expect(sampled.metrics.map(\.title) == ["CPU", "Memory", "Pressure", "Network", "Thermal"])
        #expect(sampled.metrics[0].value == UsageValue(fraction: 0.25).text)
        #expect(sampled.sampleText == "Sampled \(clock(fleetEpoch))")
        #expect(sampled.actions.isEmpty)
    }

    @Test func aMacWithoutAStatusIsShownAsConnecting() {
        let studio = record("Studio")
        let card = overview(records: [studio]).cards[1]
        #expect(card.indicator == .connecting)
        #expect(card.indicatorText == "Connecting")
        #expect(card.statusText == "Connecting to studio.tail1234.ts.net:21440…")
        #expect(card.actions == [.remove])
    }

    @Test func aConnectedMacShowsItsNameAndItsMetrics() {
        let studio = record("Studio")
        let card = overview(
            records: [studio],
            statuses: [studio.id: status(studio.id, .online, name: "Studio", snapshot: fleetSnapshot(cpu: 0.4))]
        ).cards[1]
        #expect(card.indicator == .online)
        #expect(card.indicatorText == "Online")
        #expect(card.statusText == "Reports as Studio")
        #expect(card.failureText == nil)
        #expect(card.sampleText == "Sampled \(clock(fleetEpoch))")
        #expect(card.metrics.first?.value == UsageValue(fraction: 0.4).text)
        #expect(card.actions == [.remove])
    }

    @Test func anOfflineMacSaysWhyAndWhenItWillTryAgain() {
        let studio = record("Studio")
        let retryAt = fleetEpoch.addingTimeInterval(4)
        let card = overview(records: [studio], statuses: [studio.id: status(
            studio.id,
            .reconnecting(attempt: 2, retryAt: retryAt, failure: .unreachable("connection refused"))
        )]).cards[1]
        #expect(card.indicator == .offline)
        #expect(card.indicatorText == "Offline")
        #expect(card.statusText == "Attempt 2 failed. Next try at \(clock(retryAt)).")
        #expect(card.failureText?.contains("did not answer at this address") == true)
        #expect(card.failureText?.contains("(connection refused)") == true)
        #expect(card.actions == [.reconnect, .remove])
    }

    @Test func aMacThatStoppedForAWrongSecretTellsTheUserToPairAgain() {
        let studio = record("Studio")
        let card = overview(records: [studio], statuses: [studio.id: status(studio.id, .stopped(.authenticationFailed))]).cards[1]
        #expect(card.indicator == .attention)
        #expect(card.statusText == "Retries have stopped until you act.")
        #expect(card.failureText?.contains("rejected the client secret") == true)
        #expect(card.failureText?.contains("macfleet-headless credential add") == true)
        #expect(card.actions == [.reconnect, .remove])
    }

    @Test func aChangedCertificateOffersTrustAgainAndShowsTheFingerprintShown() {
        let studio = record("Studio")
        let card = overview(records: [studio], statuses: [studio.id: status(
            studio.id,
            .stopped(.identityChanged(presented: replacedPin))
        )]).cards[1]
        #expect(card.failureText?.contains("certificate has changed") == true)
        #expect(card.failureText?.contains(replacedPin.description) == true)
        #expect(card.actions == [.trustAgain, .remove])
    }

    @Test func anExpiredCertificateSaysWhyAndOffersReconnectNotTrust() {
        let studio = record("Studio")
        let card = overview(records: [studio], statuses: [studio.id: status(
            studio.id,
            .stopped(.certificateRejected(reason: "certificate has expired"))
        )]).cards[1]
        #expect(card.failureText?.hasPrefix("The Mac's certificate was rejected: certificate has expired.") == true)
        #expect(card.actions == [.reconnect, .remove])
    }

    @Test func aStaleSnapshotStaysVisibleButIsLabelledNotCurrent() {
        let studio = record("Studio")
        let card = overview(records: [studio], statuses: [studio.id: RemoteHostStatus(
            hostID: studio.id,
            state: .reconnecting(attempt: 1, retryAt: fleetEpoch, failure: .timedOut),
            hostName: "Studio",
            capabilities: nil,
            snapshot: fleetSnapshot(cpu: 0.6),
            receivedAt: fleetEpoch
        )]).cards[1]
        #expect(card.sampleText == "Last sample \(clock(fleetEpoch)). Not current.")
        #expect(card.metrics.first?.value == UsageValue(fraction: 0.6).text)
    }

    @Test func aMetricThatCouldNotBeReadShowsADashAndTheReason() {
        let unavailable = RemoteSnapshot(
            capturedAt: fleetEpoch,
            cpuTotal: .unavailable(.notSampled),
            memory: .unavailable(.permissionDenied(resource: "memory statistics")),
            memoryPressure: .available(.critical),
            storage: .available([]),
            network: .unavailable(.counterReset),
            thermal: .available(.serious),
            loadAverage: .available(LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0))
        )
        let tiles = overview(local: unavailable).cards[0].metrics
        #expect(tiles[0].value == "–")
        #expect(tiles[0].level == nil)
        #expect(tiles[0].spokenValue.hasPrefix("CPU unavailable"))
        #expect(tiles[1].value == "–")
        #expect(tiles[3].value == "–")
        #expect(tiles[2].value == "Critical")
        #expect(tiles[2].level == .critical)
        #expect(tiles[4].value == "Serious")
        #expect(tiles[4].level == .critical)
    }

    @Test func severityFollowsTheSameBandsAsTheLocalDashboard() {
        let high = RemoteSnapshot(
            capturedAt: fleetEpoch,
            cpuTotal: .available(0.95),
            memory: .available(MemoryUsage(totalBytes: 100, usedBytes: 80, availableBytes: 20)),
            memoryPressure: .available(.warning),
            storage: .available([]),
            network: .available([]),
            thermal: .available(.fair),
            loadAverage: .available(LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0))
        )
        let tiles = overview(local: high).cards[0].metrics
        #expect(tiles[0].level == .critical)
        #expect(tiles[1].level == .elevated)
        #expect(tiles[2].level == .elevated)
        #expect(tiles[4].level == .elevated)
    }

    @Test func aNoticeReachesThePresentation() {
        #expect(overview(notice: "Saved remote Macs could not be read.").notice == "Saved remote Macs could not be read.")
    }
}

@Suite("Fleet presentation: pairing")
struct FleetPairingPresentationTests {
    private func pending(_ fingerprint: HostFingerprint, purpose: PairingPurpose) -> PendingPairing {
        PendingPairing(
            endpoint: RemoteEndpoint(host: "studio.tail1234.ts.net", port: 21440),
            probe: RemoteProbeResult(
                host: HostIdentity(displayName: "Studio", fingerprint: fingerprint),
                presentedFingerprint: fingerprint,
                version: RemoteProtocol.current
            ),
            purpose: purpose
        )
    }

    @Test func aNewMacAsksForConfirmationWithTheFingerprintAndHowToCheckIt() {
        let state = PairingState.confirming(pending(presentedPin, purpose: .newMac(
            label: "Studio",
            clientID: "laptop-1",
            credential: try! RemoteCredential(clientID: "laptop-1", secret: Data(repeating: 1, count: 32))
        )))
        guard case let .confirming(confirmation) = overview(pairing: state).pairing else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(confirmation.title == "Trust this Mac?")
        #expect(confirmation.reportedName == "Studio")
        #expect(confirmation.address == "studio.tail1234.ts.net:21440")
        #expect(confirmation.fingerprint == presentedPin.description)
        #expect(confirmation.instructions.contains("macfleet-headless identity show"))
        #expect(confirmation.confirmLabel == "Trust and Save")
    }

    @Test func aTrustAgainWithAChangedCertificateSaysSoAndWithTheSameOneSaysNothingChanged() {
        let studio = record("Studio", pin: presentedPin)
        let changed = overview(
            records: [studio],
            pairing: .confirming(pending(replacedPin, purpose: .trustAgain(recordID: studio.id)))
        ).pairing
        guard case let .confirming(newCertificate) = changed else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(newCertificate.title == "Trust the new certificate?")
        #expect(newCertificate.confirmLabel == "Trust New Certificate")

        let unchanged = overview(
            records: [studio],
            pairing: .confirming(pending(presentedPin, purpose: .trustAgain(recordID: studio.id)))
        ).pairing
        guard case let .confirming(same) = unchanged else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(same.title == "Trust this Mac again?")
        #expect(same.instructions.contains("nothing changes"))
    }

    @Test func aProbeInProgressNamesTheAddress() {
        let state = PairingState.probing(RemoteEndpoint(host: "studio.tail1234.ts.net", port: 21440))
        #expect(overview(pairing: state).pairing == .probing("Contacting studio.tail1234.ts.net:21440…"))
    }

    @Test func everyPairingProblemHasItsOwnWording() {
        #expect(overview(pairing: .failed(.label)).pairing == .failed("Enter a name for this Mac, up to 64 characters."))
        #expect(overview(pairing: .failed(.address(.publicAddress))).pairing
            == .failed("Public IP addresses are refused. Use the Mac's Tailscale name or a private address."))
        #expect(overview(pairing: .failed(.address(.invalidName))).pairing
            == .failed("Use a name such as studio or studio.tailnet.ts.net, or a private IP address."))
        #expect(overview(pairing: .failed(.secret)).pairing
            == .failed("The client secret must be the base64 text that `macfleet-headless credential add` printed."))
        #expect(overview(pairing: .failed(.limitReached(16))).pairing
            == .failed("MacFleet monitors at most 16 remote Macs. Remove one before adding another."))
        #expect(overview(pairing: .failed(.probe(.unreachable("refused")))).pairing
            == .failed("The Mac did not answer at this address. Check that Tailscale is connected on both Macs and that its monitoring agent is running. (refused)"))
    }

    @Test func theFormMirrorsTheDraftAndOnlySubmitsWhenComplete() {
        var draft = PairingDraft()
        #expect(overview(draft: draft).draft.canSubmit == false)
        draft.label = "Studio"
        draft.host = "studio.tail1234.ts.net"
        draft.clientID = "laptop-1"
        draft.secret = "c2VjcmV0"
        let presented = overview(draft: draft).draft
        #expect(presented.label == "Studio")
        #expect(presented.port == String(RemoteProtocol.defaultPort))
        #expect(presented.canSubmit)
        draft.host = "   "
        #expect(overview(draft: draft).draft.canSubmit == false)
    }
}
