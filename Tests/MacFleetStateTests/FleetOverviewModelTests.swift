import Foundation
import MacFleetKit
import MacFleetState
import Testing

private let modelPin = HostFingerprint(certificateDER: Data("model studio cert".utf8))
private let modelSecret = Data(repeating: 9, count: 32).base64EncodedString()

@MainActor
private func makeFleetModel(
    records: [RemoteHostRecord] = [],
    store: MemoryRemoteHostStore? = nil,
    secrets: MemoryAgentSecretStore = MemoryAgentSecretStore(),
    opener: FleetScriptedOpener = FleetScriptedOpener([:]),
    prober: FleetFakeProber = FleetFakeProber([]),
    scheduler: FleetManualScheduler = FleetManualScheduler()
) -> FleetOverviewModel {
    FleetOverviewModel(
        store: store ?? MemoryRemoteHostStore(records: records),
        secrets: secrets,
        opener: opener,
        prober: prober,
        scheduling: fleetScheduling(scheduler)
    )
}

@MainActor
private func fillValidDraft(_ model: FleetOverviewModel, secret: String = modelSecret) {
    model.setDraft(.label, "Studio")
    model.setDraft(.host, "127.0.0.1")
    model.setDraft(.port, "21440")
    model.setDraft(.clientID, "laptop-1")
    model.setDraft(.secret, secret)
}

private func probeResult(_ fingerprint: HostFingerprint, name: String = "Studio") -> Result<RemoteProbeResult, RemoteClientError> {
    .success(RemoteProbeResult(
        host: HostIdentity(displayName: name, fingerprint: fingerprint),
        presentedFingerprint: fingerprint,
        version: RemoteProtocol.current
    ))
}

private func storedRecord(id: UUID = UUID(), label: String = "Studio", pin: HostFingerprint = modelPin) -> RemoteHostRecord {
    fleetRecord(id: id, label: label, host: "127.0.0.1", port: 21440, clientID: "laptop-1", pin: pin)
}

@MainActor
@Suite("Fleet overview model: pairing")
struct FleetPairingTests {
    @Test func theIdentityIsShownAndNothingIsSavedUntilTheUserConfirms() async throws {
        let prober = FleetFakeProber([probeResult(modelPin)])
        let store = MemoryRemoteHostStore()
        let secrets = MemoryAgentSecretStore()
        let model = makeFleetModel(store: store, secrets: secrets, prober: prober)
        model.start()
        fillValidDraft(model)

        model.beginPairing()
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }
        #expect(await prober.probed == [RemoteEndpoint(host: "127.0.0.1", port: 21440)])
        #expect(model.records.isEmpty)
        #expect(try store.load().isEmpty)
        #expect(secrets.accounts().isEmpty)
        guard case let .confirming(pending) = model.pairing else { return }
        #expect(pending.probe.presentedFingerprint == modelPin)

        model.confirmPairing()
        try await fleetEventually { !model.records.isEmpty }
        let record = try #require(model.records.first)
        #expect(record.pinnedFingerprint == modelPin)
        #expect(record.host == "127.0.0.1")
        #expect(record.port == 21440)
        #expect(record.clientID == "laptop-1")
        #expect(record.label == "Studio")
        #expect(try store.load() == [record])
        #expect(secrets.accounts() == ["remote.\(record.id.uuidString)"])
        #expect(model.pairing == .idle)
        #expect(model.presentation.draft.secret.isEmpty)
        await model.stopAll()
    }

    @Test func aSavedRecordNeverHoldsTheSecret() async throws {
        let store = MemoryRemoteHostStore()
        let model = makeFleetModel(store: store, prober: FleetFakeProber([probeResult(modelPin)]))
        model.start()
        fillValidDraft(model)
        model.beginPairing()
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }
        model.confirmPairing()
        try await fleetEventually { !model.records.isEmpty }

        let text = String(decoding: try JSONEncoder().encode(try store.load()), as: UTF8.self)
        #expect(!text.contains(modelSecret))
        await model.stopAll()
    }

    @Test func invalidDraftsAreRefusedBeforeAnyProbeIsSent() async throws {
        let cases: [(PairingField, String, PairingProblem)] = [
            (.label, "   ", .label),
            (.host, "8.8.8.8", .address(.publicAddress)),
            (.host, "bad host", .address(.invalidName)),
            (.port, "0", .port),
            (.clientID, "bad id", .clientID),
            (.secret, "not base64!!", .secret),
            (.secret, Data(repeating: 1, count: 5).base64EncodedString(), .secret),
        ]
        for (field, value, expected) in cases {
            let prober = FleetFakeProber([probeResult(modelPin)])
            let model = makeFleetModel(prober: prober)
            model.start()
            fillValidDraft(model)
            model.setDraft(field, value)
            model.beginPairing()
            #expect(model.pairing == .failed(expected), "\(field) with \(value)")
            #expect(await prober.probed.isEmpty)
        }
    }

    @Test func aFailedProbeIsReportedAndNothingIsSaved() async throws {
        let store = MemoryRemoteHostStore()
        let secrets = MemoryAgentSecretStore()
        let model = makeFleetModel(store: store, secrets: secrets, prober: FleetFakeProber([.failure(.connectionFailed("refused"))]))
        model.start()
        fillValidDraft(model)
        model.beginPairing()
        try await fleetEventually { if case .failed = model.pairing { true } else { false } }
        #expect(model.pairing == .failed(.probe(.unreachable("refused"))))
        #expect(model.records.isEmpty)
        #expect(try store.load().isEmpty)
        #expect(secrets.accounts().isEmpty)
    }

    @Test func cancellingForgetsTheDraftAndTheSecret() async throws {
        let model = makeFleetModel(prober: FleetFakeProber([probeResult(modelPin)]))
        model.start()
        fillValidDraft(model)
        model.beginPairing()
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }

        model.cancelPairing()
        #expect(model.pairing == .idle)
        #expect(model.draft == PairingDraft())
        #expect(model.records.isEmpty)
    }

    @Test func aFailedSaveLeavesNoSecretBehind() async throws {
        let store = MemoryRemoteHostStore(saveFailure: CocoaError(.fileWriteNoPermission))
        let secrets = MemoryAgentSecretStore()
        let model = makeFleetModel(store: store, secrets: secrets, prober: FleetFakeProber([probeResult(modelPin)]))
        model.start()
        fillValidDraft(model)
        model.beginPairing()
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }

        model.confirmPairing()
        guard case .failed(.storage) = model.pairing else {
            Issue.record("a failed save must be reported, got \(model.pairing)")
            return
        }
        #expect(model.records.isEmpty)
        #expect(secrets.accounts().isEmpty)
    }

    @Test func theLimitOnRemoteMacsIsEnforced() async throws {
        let records = (0..<FleetOverviewModel.maximumRemoteMacs).map { index in
            storedRecord(label: "Mac \(index)")
        }
        let model = makeFleetModel(records: records)
        model.start()
        #expect(model.presentation.canAddMore == false)
        fillValidDraft(model)
        model.beginPairing()
        #expect(model.pairing == .failed(.limitReached(FleetOverviewModel.maximumRemoteMacs)))
    }

    @Test func aDamagedSavedListStartsEmptyWithANoticeAndStillAllowsPairing() async throws {
        let store = MemoryRemoteHostStore(loadFailure: .damaged(movedAside: "MacFleet.remoteHosts.damaged.1"))
        let model = makeFleetModel(store: store, prober: FleetFakeProber([probeResult(modelPin)]))
        model.start()
        #expect(model.records.isEmpty)
        #expect(model.notice?.contains("MacFleet.remoteHosts.damaged.1") == true)
        #expect(model.presentation.notice == model.notice)

        fillValidDraft(model)
        model.beginPairing()
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }
        model.confirmPairing()
        try await fleetEventually { !model.records.isEmpty }
        await model.stopAll()
    }

    @Test func anUnreadableSavedListBlocksSavingSoNothingIsOverwritten() async throws {
        let store = MemoryRemoteHostStore(loadFailure: .unreadable("the file is locked"))
        let secrets = MemoryAgentSecretStore()
        let model = makeFleetModel(store: store, secrets: secrets, prober: FleetFakeProber([probeResult(modelPin)]))
        model.start()
        #expect(model.notice?.contains("the file is locked") == true)

        fillValidDraft(model)
        model.beginPairing()
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }
        model.confirmPairing()
        guard case .failed(.storage) = model.pairing else {
            Issue.record("confirming must be refused while the list is unreadable")
            return
        }
        #expect(secrets.accounts().isEmpty)
    }
}

@MainActor
@Suite("Fleet overview model: registered Macs")
struct FleetRegisteredMacTests {
    @Test func removingAMacForgetsItsSecretAndItsConnection() async throws {
        let record = storedRecord()
        let secrets = MemoryAgentSecretStore([
            "remote.\(record.id.uuidString)": Data(repeating: 9, count: 32),
        ])
        let opener = FleetScriptedOpener([record.id: [.run([
            fleetConnected(name: "Studio", fingerprint: modelPin),
        ], end: .hold)]])
        let model = makeFleetModel(records: [record], secrets: secrets, opener: opener)
        model.start()
        try await fleetEventually { model.statuses[record.id]?.state == .online }

        model.remove(record.id)
        #expect(model.records.isEmpty)
        #expect(model.statuses[record.id] == nil)
        #expect(secrets.accounts().isEmpty)
        #expect(model.presentation.cards.map(\.title) == ["This Mac"])
        await model.stopAll()
    }

    @Test func aMacWithoutASavedSecretIsStoppedWithoutAnyAttempt() async throws {
        let record = storedRecord()
        let opener = FleetScriptedOpener([:])
        let model = makeFleetModel(records: [record], opener: opener)
        model.start()
        #expect(model.statuses[record.id]?.state == .stopped(.credentialMissing))
        #expect(await opener.attempts[record.id] == nil)
    }

    @Test func everySavedMacReconnectsWhenTheAppLaunches() async throws {
        let alpha = storedRecord(label: "Alpha")
        let beta = storedRecord(label: "Beta")
        let secrets = MemoryAgentSecretStore([
            "remote.\(alpha.id.uuidString)": Data(repeating: 9, count: 32),
            "remote.\(beta.id.uuidString)": Data(repeating: 9, count: 32),
        ])
        let opener = FleetScriptedOpener([
            alpha.id: [.run([fleetConnected(name: "Alpha", fingerprint: modelPin)], end: .hold)],
            beta.id: [.run([fleetConnected(name: "Beta", fingerprint: modelPin)], end: .hold)],
        ])
        let model = makeFleetModel(records: [alpha, beta], secrets: secrets, opener: opener)
        model.start()
        try await fleetEventually { model.statuses[alpha.id]?.state == .online && model.statuses[beta.id]?.state == .online }
        #expect(model.presentation.cards.map(\.title) == ["This Mac", "Alpha", "Beta"])
        await model.stopAll()
    }

    @Test func eachMacHasItsOwnStatusAndItsOwnFailure() async throws {
        let failing = storedRecord(label: "Failing")
        let healthy = storedRecord(label: "Healthy")
        let secrets = MemoryAgentSecretStore([
            "remote.\(failing.id.uuidString)": Data(repeating: 9, count: 32),
            "remote.\(healthy.id.uuidString)": Data(repeating: 9, count: 32),
        ])
        let opener = FleetScriptedOpener([
            failing.id: [.fail(.hostRejected(RemoteProtocolError(code: .authenticationFailed, message: "no", retryable: false)))],
            healthy.id: [.run([fleetConnected(name: "Healthy", fingerprint: modelPin)], end: .hold)],
        ])
        let model = makeFleetModel(records: [failing, healthy], secrets: secrets, opener: opener)
        model.start()
        try await fleetEventually {
            model.statuses[failing.id]?.state == .stopped(.authenticationFailed) && model.statuses[healthy.id]?.state == .online
        }
        let cards = model.presentation.cards
        #expect(cards.first { $0.title == "Failing" }?.indicator == .attention)
        #expect(cards.first { $0.title == "Healthy" }?.indicator == .online)
        await model.stopAll()
    }

    @Test func aStoppedMacCanBeRetriedAfterTheUserFixesIt() async throws {
        let record = storedRecord()
        let secrets = MemoryAgentSecretStore([
            "remote.\(record.id.uuidString)": Data(repeating: 9, count: 32),
        ])
        let opener = FleetScriptedOpener([record.id: [
            .fail(.hostRejected(RemoteProtocolError(code: .authenticationFailed, message: "no", retryable: false))),
            .run([fleetConnected(name: "Studio", fingerprint: modelPin)], end: .hold),
        ]])
        let model = makeFleetModel(records: [record], secrets: secrets, opener: opener)
        model.start()
        try await fleetEventually { model.statuses[record.id]?.state == .stopped(.authenticationFailed) }

        model.retry(record.id)
        try await fleetEventually { model.statuses[record.id]?.state == .online }
        await model.stopAll()
    }

    @Test func aLocalSampleFillsTheLocalCard() throws {
        let model = makeFleetModel()
        model.start()
        #expect(model.presentation.cards.first?.metrics.isEmpty == true)
        model.updateLocal(MockSystemMetricsProvider.sampleSnapshot)
        let local = try #require(model.presentation.cards.first)
        #expect(local.title == "This Mac")
        #expect(local.metrics.count == 5)
    }
}

@MainActor
@Suite("Fleet overview model: certificate changes")
struct FleetCertificateChangeTests {
    @Test func aChangedCertificateIsNotTrustedUntilTheUserConfirmsTheNewOne() async throws {
        let replacement = HostFingerprint(certificateDER: Data("replacement cert".utf8))
        let record = storedRecord()
        let secrets = MemoryAgentSecretStore([
            "remote.\(record.id.uuidString)": Data(repeating: 9, count: 32),
        ])
        let store = MemoryRemoteHostStore(records: [record])
        let opener = FleetScriptedOpener([record.id: [
            .fail(.identityMismatch(presented: replacement)),
            .run([fleetConnected(name: "Studio", fingerprint: replacement)], end: .hold),
        ]])
        let prober = FleetFakeProber([probeResult(replacement)])
        let model = makeFleetModel(records: [record], store: store, secrets: secrets, opener: opener, prober: prober)
        model.start()

        try await fleetEventually { model.statuses[record.id]?.state == .stopped(.identityChanged(presented: replacement)) }
        #expect(model.records.first?.pinnedFingerprint == modelPin)
        #expect(try store.load().first?.pinnedFingerprint == modelPin)
        #expect(model.presentation.cards.first { $0.hostID == record.id }?.actions == [.trustAgain, .remove])

        model.beginTrustAgain(record.id)
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }
        #expect(model.records.first?.pinnedFingerprint == modelPin)
        #expect(await prober.probed == [record.endpoint])

        model.confirmPairing()
        try await fleetEventually { model.statuses[record.id]?.state == .online }
        #expect(model.records.first?.pinnedFingerprint == replacement)
        #expect(try store.load().first?.pinnedFingerprint == replacement)
        #expect(secrets.accounts() == ["remote.\(record.id.uuidString)"])
        await model.stopAll()
    }

    @Test func cancellingATrustDecisionKeepsTheOldPin() async throws {
        let replacement = HostFingerprint(certificateDER: Data("replacement cert".utf8))
        let record = storedRecord()
        let secrets = MemoryAgentSecretStore([
            "remote.\(record.id.uuidString)": Data(repeating: 9, count: 32),
        ])
        let opener = FleetScriptedOpener([record.id: [.fail(.identityMismatch(presented: replacement))]])
        let model = makeFleetModel(
            records: [record],
            secrets: secrets,
            opener: opener,
            prober: FleetFakeProber([probeResult(replacement)])
        )
        model.start()
        try await fleetEventually { model.statuses[record.id]?.state == .stopped(.identityChanged(presented: replacement)) }

        model.beginTrustAgain(record.id)
        try await fleetEventually { if case .confirming = model.pairing { true } else { false } }
        model.cancelPairing()
        #expect(model.records.first?.pinnedFingerprint == modelPin)
        #expect(model.pairing == .idle)
        await model.stopAll()
    }
}
