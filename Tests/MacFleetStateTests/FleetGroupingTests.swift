import Foundation
import MacFleetKit
import MacFleetState
import Testing

private let grpPin = HostFingerprint(certificateDER: Data("grouping pin".utf8))
private let grpSecret = Data(repeating: 7, count: 32).base64EncodedString()

@MainActor
private func grpModel(
    records: [RemoteHostRecord] = [],
    store: MemoryRemoteHostStore? = nil,
    opener: FleetScriptedOpener = FleetScriptedOpener([:]),
    prober: FleetFakeProber = FleetFakeProber([]),
    secrets: MemoryAgentSecretStore = MemoryAgentSecretStore()
) -> FleetOverviewModel {
    FleetOverviewModel(
        store: store ?? MemoryRemoteHostStore(records: records),
        secrets: secrets,
        opener: opener,
        prober: prober,
        scheduling: fleetScheduling(FleetManualScheduler())
    )
}

private func grpRecord(_ label: String, group: String?) -> RemoteHostRecord {
    fleetRecord(id: UUID(), label: label, pin: grpPin).grouped(group)
}

@MainActor
private func grpFillDraft(_ model: FleetOverviewModel, group: String) {
    model.setDraft(.label, "Studio")
    model.setDraft(.host, "127.0.0.1")
    model.setDraft(.port, "21440")
    model.setDraft(.clientID, "laptop-1")
    model.setDraft(.secret, grpSecret)
    model.setDraft(.group, group)
}

@MainActor
@Suite("Fleet groups: sections")
struct FleetGroupSectionTests {
    @Test func sectionsFollowTheGroupNamesWithThisMacFirstAndUngroupedLast() async {
        let model = grpModel(records: [grpRecord("Beta", group: nil), grpRecord("Alpha", group: "Office"), grpRecord("Gamma", group: "Lab")])
        model.start()
        #expect(model.presentation.groups.map(\.title) == ["This Mac", "Lab", "Office", "Other Macs"])
        #expect(model.presentation.groups.first { $0.title == "Lab" }?.cards.map(\.title) == ["Gamma"])
        #expect(model.presentation.groups.last?.cards.map(\.title) == ["Beta"])
        await model.stopAll()
    }

    @Test func withoutNamedGroupsTheUngroupedMacsAreTheRemoteMacs() async {
        let model = grpModel(records: [grpRecord("Beta", group: nil)])
        model.start()
        #expect(model.presentation.groups.map(\.title) == ["This Mac", "Remote Macs"])
        await model.stopAll()
    }

    @Test func theFlatCardListIsTheSectionsInOrder() async {
        let model = grpModel(records: [grpRecord("Beta", group: nil), grpRecord("Alpha", group: "Office")])
        model.start()
        #expect(model.presentation.groups.flatMap(\.cards) == model.presentation.cards)
        await model.stopAll()
    }

    @Test func eachRemoteCardShowsItsOwnGroupAndOffersTheGroupsInUse() async {
        let model = grpModel(records: [grpRecord("Alpha", group: "Office"), grpRecord("Beta", group: nil), grpRecord("Gamma", group: "Lab")])
        model.start()
        let alpha = model.presentation.cards.first { $0.title == "Alpha" }
        #expect(alpha?.group == "Office")
        #expect(alpha?.groupChoices == ["Lab", "Office"])
        #expect(model.presentation.cards.first { $0.title == "Beta" }?.group == nil)
        #expect(model.presentation.cards.first { $0.hostID == nil }?.groupChoices == [])
        await model.stopAll()
    }
}

@MainActor
@Suite("Fleet groups: changing and saving")
struct FleetGroupSavingTests {
    @Test func movingAMacSavesTheGroupAndShowsItUnderThatGroup() async throws {
        let beta = grpRecord("Beta", group: nil)
        let store = MemoryRemoteHostStore(records: [beta])
        let model = grpModel(store: store)
        model.start()
        model.setGroup(beta.id, "Lab")
        #expect(model.records.first?.group == "Lab")
        #expect(try store.load().first?.group == "Lab")
        #expect(model.presentation.groups.map(\.title).contains("Lab"))
        model.setGroup(beta.id, "   ")
        #expect(model.records.first?.group == nil)
        await model.stopAll()
    }

    @Test func aSaveFailureKeepsTheOldGroupAndSaysSo() async {
        let beta = grpRecord("Beta", group: "Office")
        let model = grpModel(store: MemoryRemoteHostStore(records: [beta], saveFailure: CocoaError(.fileWriteNoPermission)))
        model.start()
        model.setGroup(beta.id, "Lab")
        #expect(model.records.first?.group == "Office")
        #expect(model.notice?.contains("could not be moved") == true)
        await model.stopAll()
    }

    @Test func aGroupGivenWithANewPairingIsSaved() async throws {
        let prober = FleetFakeProber([.success(RemoteProbeResult(
            host: HostIdentity(displayName: "Studio", fingerprint: grpPin),
            presentedFingerprint: grpPin,
            version: RemoteProtocol.current
        ))])
        let model = grpModel(prober: prober)
        model.start()
        grpFillDraft(model, group: "  Lab  ")
        model.beginPairing()
        try await fleetEventually {
            if case .confirming = model.pairing { true } else { false }
        }
        model.confirmPairing()
        try await fleetEventually { !model.records.isEmpty }
        #expect(model.records.first?.group == "Lab")
        await model.stopAll()
    }

    @Test func aGroupNameOverTheLimitIsRefusedBeforeAnyProbe() async throws {
        let prober = FleetFakeProber([])
        let model = grpModel(prober: prober)
        model.start()
        grpFillDraft(model, group: String(repeating: "g", count: RemoteHostRecord.maximumGroupLength + 1))
        model.beginPairing()
        #expect(model.pairing == .failed(.group))
        #expect(await prober.probed.isEmpty)
        #expect(model.presentation.draft.canSubmit)
        await model.stopAll()
    }

    @Test func groupingAMacThatIsNotRegisteredChangesNothing() async {
        let model = grpModel()
        model.start()
        model.setGroup(UUID(), "Lab")
        #expect(model.records.isEmpty)
        await model.stopAll()
    }
}

@MainActor
@Suite("Fleet: empty state and remote rate")
struct FleetEmptyAndRateTests {
    @Test func anEmptyFleetExplainsHowToAddAMac() async {
        let model = grpModel()
        model.start()
        #expect(model.presentation.emptyText == FleetOverviewPresentation.emptyFleetText)
        #expect(model.presentation.emptyText?.contains("Tailscale name") == true)
        await model.stopAll()
    }

    @Test func theEmptyStateGoesOnceAMacIsRegistered() async {
        let model = grpModel(records: [grpRecord("Beta", group: nil)])
        model.start()
        #expect(model.presentation.emptyText == nil)
        await model.stopAll()
    }

    @Test func theRemoteRateStartsAtItsDefaultAndAChangeReachesTheOpenSessions() async throws {
        let record = grpRecord("Studio", group: nil)
        let secrets = MemoryAgentSecretStore(["remote.\(record.id.uuidString)": Data(repeating: 9, count: 32)])
        let session = FleetScriptedSession.run([fleetConnected(name: "Studio", fingerprint: grpPin)], end: .hold)
        let opener = FleetScriptedOpener([record.id: [session, session]])
        let model = grpModel(records: [record], opener: opener, secrets: secrets)
        model.start()
        try await fleetEventuallyAsync {
            ((await opener.intervals[record.id]?.count) ?? 0) >= 1
        }
        #expect(await opener.intervals[record.id]?.first?.seconds == Double(RefreshKind.remote.defaultSeconds))

        model.setRemoteSampleInterval(SamplingInterval(seconds: 30))
        try await fleetEventuallyAsync {
            ((await opener.intervals[record.id]?.count) ?? 0) >= 2
        }
        #expect(await opener.intervals[record.id]?.last?.seconds == 30)
        await model.stopAll()
    }
}
