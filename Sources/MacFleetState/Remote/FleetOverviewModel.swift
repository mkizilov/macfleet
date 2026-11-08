import Foundation
import MacFleetKit
import Observation

/// What the pairing form holds. The secret is the base64 text `macfleet-headless credential add` printed. It stays in
/// memory until the pairing is confirmed or cancelled, and it is never written into a record.
public struct PairingDraft: Equatable, Sendable {
    public var label = ""
    public var host = ""
    public var port = String(RemoteProtocol.defaultPort)
    public var clientID = ""
    public var secret = ""
    public var group = ""

    public init() {}
}

public enum PairingField: Equatable, Sendable {
    case label
    case host
    case port
    case clientID
    case secret
    case group
}

/// What a confirmed pairing does.
public enum PairingPurpose: Equatable, Sendable {
    case newMac(label: String, clientID: String, credential: RemoteCredential, group: String? = nil)
    /// Trust the Mac's current certificate, after its certificate changed and the user has checked the new fingerprint.
    case trustAgain(recordID: UUID)
}

/// A probe the user has yet to confirm. Nothing is saved until `confirmPairing` runs.
public struct PendingPairing: Equatable, Sendable {
    public let endpoint: RemoteEndpoint
    public let probe: RemoteProbeResult
    public let purpose: PairingPurpose

    public init(endpoint: RemoteEndpoint, probe: RemoteProbeResult, purpose: PairingPurpose) {
        self.endpoint = endpoint
        self.probe = probe
        self.purpose = purpose
    }
}

public enum PairingProblem: Error, Equatable, Sendable {
    case label
    case address(RemoteHostAddressError)
    case port
    case clientID
    case secret
    case group
    case limitReached(Int)
    case probe(RemoteFailure)
    case notRegistered
    case storage(String)
}

public enum PairingState: Equatable, Sendable {
    case idle
    case probing(RemoteEndpoint)
    case confirming(PendingPairing)
    case failed(PairingProblem)
}

/// The unified dashboard's model. It holds the local Mac's latest sample, the registered remote Macs, and one watcher per
/// Mac. Each remote Mac has its own connection, retry clock, and snapshot. Pairing is two steps: the identity is probed
/// and shown, and only the user's confirmation saves it.
@MainActor
@Observable
public final class FleetOverviewModel {
    /// The most remote Macs the app monitors at once. Each one holds a connection and a retry clock.
    public static let maximumRemoteMacs = 16

    public private(set) var presentation: FleetOverviewPresentation
    public private(set) var draft = PairingDraft()
    public private(set) var pairing = PairingState.idle
    public private(set) var notice: String?
    public private(set) var records: [RemoteHostRecord] = []
    public private(set) var statuses: [UUID: RemoteHostStatus] = [:]

    private let store: any RemoteHostStoring
    private let secrets: any AgentSecretStore
    private let opener: any RemoteSessionOpening
    private let prober: any RemoteHostProbing
    private let scheduling: RemoteScheduling
    private let backoff: RemoteBackoff
    private var localSnapshot: RemoteSnapshot?
    private var watchers: [UUID: RemoteHostWatcher] = [:]
    private var consumers: [UUID: Task<Void, Never>] = [:]
    private var probeTask: Task<Void, Never>?
    private var recordsWritable = true
    private var started = false
    /// How often each registered Mac sends a snapshot. Set from the settings.
    private var remoteInterval = SamplingInterval(seconds: Double(RefreshKind.remote.defaultSeconds))
    private var lastEvaluated: [UUID: Date] = [:]
    private let history: (any FleetHistoryStoring)?
    private let hostAlerts: HostAlertCenter?

    public init(
        store: any RemoteHostStoring,
        secrets: any AgentSecretStore,
        opener: any RemoteSessionOpening,
        prober: any RemoteHostProbing,
        scheduling: RemoteScheduling = .live,
        backoff: RemoteBackoff = .standard,
        history: (any FleetHistoryStoring)? = nil,
        hostAlerts: HostAlertCenter? = nil
    ) {
        self.store = store
        self.secrets = secrets
        self.opener = opener
        self.prober = prober
        self.scheduling = scheduling
        self.backoff = backoff
        self.history = history
        self.hostAlerts = hostAlerts
        presentation = FleetOverviewPresentation(
            local: nil,
            records: [],
            statuses: [:],
            pairing: .idle,
            draft: PairingDraft(),
            notice: nil,
            canAddMore: true
        )
    }

    /// Loads the registered Macs and starts watching each one. Call once, at launch.
    public func start() {
        guard !started else { return }
        started = true
        do {
            records = try store.load()
        } catch RemoteHostStoreError.damaged(let aside) {
            notice = "Saved remote Macs could not be read, so the list starts empty. The damaged data was kept under \(aside)."
        } catch RemoteHostStoreError.unreadable(let reason) {
            recordsWritable = false
            notice = "Saved remote Macs could not be read (\(reason)). New Macs cannot be saved until the list can be read."
        } catch {
            recordsWritable = false
            notice = "Saved remote Macs could not be read: \(error.localizedDescription)"
        }
        for record in records {
            startWatching(record)
        }
        rebuild()
    }

    /// The local Mac's latest sample, which the unified dashboard shows as its own card.
    public func updateLocal(_ snapshot: SystemSnapshot) {
        localSnapshot = RemoteSnapshot(system: snapshot)
        rebuild()
    }

    public func setDraft(_ field: PairingField, _ value: String) {
        switch field {
        case .label: draft.label = value
        case .host: draft.host = value
        case .port: draft.port = value
        case .clientID: draft.clientID = value
        case .secret: draft.secret = value
        case .group: draft.group = value
        }
        rebuild()
    }

    /// Checks the draft and probes the Mac's identity. The result is shown for confirmation before anything is saved.
    public func beginPairing() {
        if case .probing = pairing { return }
        if case .confirming = pairing { return }
        do {
            let valid = try validatedPairing()
            probeTask?.cancel()
            pairing = .probing(valid.endpoint)
            probeTask = Task { [self] in
                do {
                    let result = try await prober.probe(valid.endpoint, clientID: valid.clientID)
                    guard !Task.isCancelled else { return }
                    pairing = .confirming(PendingPairing(
                        endpoint: valid.endpoint,
                        probe: result,
                        purpose: .newMac(label: valid.label, clientID: valid.clientID, credential: valid.credential, group: valid.group)
                    ))
                } catch {
                    guard !Task.isCancelled else { return }
                    pairing = .failed(.probe(RemoteFailure(error)))
                }
                rebuild()
            }
        } catch let problem as PairingProblem {
            pairing = .failed(problem)
        } catch {
            pairing = .failed(.storage(error.localizedDescription))
        }
        rebuild()
    }

    /// Probes a registered Mac again, to trust a certificate that changed. Its saved secret is kept.
    public func beginTrustAgain(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        probeTask?.cancel()
        pairing = .probing(record.endpoint)
        probeTask = Task { [self] in
            do {
                let result = try await prober.probe(record.endpoint, clientID: record.clientID)
                guard !Task.isCancelled else { return }
                pairing = .confirming(PendingPairing(
                    endpoint: record.endpoint,
                    probe: result,
                    purpose: .trustAgain(recordID: id)
                ))
            } catch {
                guard !Task.isCancelled else { return }
                pairing = .failed(.probe(RemoteFailure(error)))
            }
            rebuild()
        }
        rebuild()
    }

    /// Saves the confirmed identity and starts watching the Mac. Only this call writes a new pin.
    public func confirmPairing() {
        guard case let .confirming(pending) = pairing else { return }
        guard recordsWritable else {
            fail(.storage("the saved list cannot be read, so nothing can be saved"))
            return
        }
        switch pending.purpose {
        case let .newMac(label, clientID, credential, group):
            savePairedMac(pending, label: label, clientID: clientID, credential: credential, group: group)
        case let .trustAgain(recordID):
            trustAgain(recordID, pending)
        }
        rebuild()
    }

    public func cancelPairing() {
        probeTask?.cancel()
        probeTask = nil
        pairing = .idle
        draft = PairingDraft()
        rebuild()
    }

    /// Reconnects a Mac whose retries stopped, or retries now after a transient failure.
    public func retry(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        Task { [self] in await restart(record) }
    }

    /// The sources the history can show: this Mac, then every registered Mac.
    public var historyIdentities: [HistoryHostIdentity] {
        [HistoryHostIdentity(id: .local, label: "This Mac")] + records.map {
            HistoryHostIdentity(id: .remote($0.id), label: $0.label)
        }
    }

    /// Stops watching a Mac, forgets its identity and secret, and deletes its history and alert settings. A Mac's history
    /// belongs to its pairing, so it does not outlive it.
    public func remove(_ id: UUID) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        guard recordsWritable else {
            notice = "\(record.label) cannot be removed while the saved list cannot be read."
            rebuild()
            return
        }
        let remaining = records.filter { $0.id != id }
        do {
            try store.save(remaining)
        } catch {
            notice = "\(record.label) could not be removed: \(error.localizedDescription)"
            rebuild()
            return
        }
        records = remaining
        statuses[id] = nil
        lastEvaluated[id] = nil
        do {
            try secrets.removeSecret(for: Self.account(id))
        } catch {
            notice = "The client secret for \(record.label) could not be removed: \(error.localizedDescription)"
        }
        hostAlerts?.remove(.remote(id))
        Task { [self] in
            await stopWatching(id)
            do {
                _ = try await history?.removeHistory(for: .remote(id))
            } catch {
                notice = "The history for \(record.label) could not be deleted. \(error.localizedDescription)"
                rebuild()
            }
        }
        rebuild()
    }

    /// Moves a registered Mac under another group, or out of its group when `group` is nil. The change is saved at once.
    public func setGroup(_ id: UUID, _ group: String?) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let label = records[index].label
        guard recordsWritable else {
            notice = "\(label) cannot be moved while the saved list cannot be read."
            rebuild()
            return
        }
        var saved = records
        saved[index] = saved[index].grouped(group)
        do {
            try store.save(saved)
        } catch {
            notice = "\(label) could not be moved. \(error.localizedDescription)"
            rebuild()
            return
        }
        records = saved
        rebuild()
    }

    /// Changes how often each registered Mac reports. An open session is reopened at the new rate.
    public func setRemoteSampleInterval(_ interval: SamplingInterval) {
        guard interval != remoteInterval else { return }
        remoteInterval = interval
        for record in records where watchers[record.id] != nil {
            Task { [self] in await restart(record) }
        }
    }

    /// Stops every watcher. Call when the app quits.
    public func stopAll() async {
        probeTask?.cancel()
        for id in Array(watchers.keys) {
            await stopWatching(id)
        }
    }

    private struct ValidatedPairing: Sendable {
        let label: String
        let endpoint: RemoteEndpoint
        let clientID: String
        let credential: RemoteCredential
        let group: String?
    }

    private func validatedPairing() throws -> ValidatedPairing {
        let label = draft.label.trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(label.count) else { throw PairingProblem.label }
        let host: String
        do {
            host = try RemoteHostAddress.validate(draft.host)
        } catch let error as RemoteHostAddressError {
            throw PairingProblem.address(error)
        }
        let port: UInt16
        do {
            port = try RemoteHostAddress.validatePort(draft.port)
        } catch {
            throw PairingProblem.port
        }
        let clientID = draft.clientID.trimmingCharacters(in: .whitespaces)
        guard RemoteCredential.isValidClientID(clientID) else { throw PairingProblem.clientID }
        let group = RemoteHostRecord.normalizedGroup(draft.group)
        if let group, group.count > RemoteHostRecord.maximumGroupLength {
            throw PairingProblem.group
        }
        guard let secret = Data(base64Encoded: draft.secret.trimmingCharacters(in: .whitespacesAndNewlines)),
              let credential = try? RemoteCredential(clientID: clientID, secret: secret)
        else {
            throw PairingProblem.secret
        }
        guard records.count < Self.maximumRemoteMacs else {
            throw PairingProblem.limitReached(Self.maximumRemoteMacs)
        }
        return ValidatedPairing(
            label: label,
            endpoint: RemoteEndpoint(host: host, port: port),
            clientID: clientID,
            credential: credential,
            group: group
        )
    }

    private func savePairedMac(
        _ pending: PendingPairing,
        label: String,
        clientID: String,
        credential: RemoteCredential,
        group: String?
    ) {
        guard records.count < Self.maximumRemoteMacs else {
            fail(.limitReached(Self.maximumRemoteMacs))
            return
        }
        let record = RemoteHostRecord(
            label: label,
            host: pending.endpoint.host,
            port: pending.endpoint.port,
            clientID: clientID,
            pinnedFingerprint: pending.probe.presentedFingerprint,
            addedAt: scheduling.now(),
            group: group
        )
        let account = Self.account(record.id)
        do {
            try secrets.setSecret(credential.secret, for: account)
        } catch {
            fail(.storage(error.localizedDescription))
            return
        }
        let saved = records + [record]
        do {
            try store.save(saved)
        } catch {
            try? secrets.removeSecret(for: account)
            fail(.storage(error.localizedDescription))
            return
        }
        records = saved
        draft = PairingDraft()
        pairing = .idle
        launch(RemoteTarget(record: record, credential: credential))
    }

    private func trustAgain(_ recordID: UUID, _ pending: PendingPairing) {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            fail(.notRegistered)
            return
        }
        let updated = records[index].pinned(to: pending.probe.presentedFingerprint)
        var saved = records
        saved[index] = updated
        do {
            try store.save(saved)
        } catch {
            fail(.storage(error.localizedDescription))
            return
        }
        records = saved
        pairing = .idle
        Task { [self] in await restart(updated) }
    }

    private func fail(_ problem: PairingProblem) {
        pairing = .failed(problem)
        rebuild()
    }

    private func startWatching(_ record: RemoteHostRecord) {
        do {
            guard let secret = try secrets.secret(for: Self.account(record.id)) else {
                statuses[record.id] = stopped(record.id, .credentialMissing)
                return
            }
            let credential = try RemoteCredential(clientID: record.clientID, secret: secret)
            launch(RemoteTarget(record: record, credential: credential))
        } catch {
            notice = "The client secret for \(record.label) could not be read: \(error.localizedDescription)"
            statuses[record.id] = stopped(record.id, .credentialMissing)
        }
    }

    private func launch(_ target: RemoteTarget) {
        let id = target.record.id
        let watcher = RemoteHostWatcher(
            target: target,
            opener: opener,
            interval: remoteInterval,
            backoff: backoff,
            scheduling: scheduling,
            history: history
        )
        watchers[id] = watcher
        consumers[id] = Task { [weak self] in
            for await status in watcher.statuses {
                self?.apply(status)
            }
        }
        Task { await watcher.start() }
    }

    private func restart(_ record: RemoteHostRecord) async {
        await stopWatching(record.id)
        startWatching(record)
        rebuild()
    }

    private func stopWatching(_ id: UUID) async {
        consumers.removeValue(forKey: id)?.cancel()
        let watcher = watchers.removeValue(forKey: id)
        await watcher?.stop()
    }

    private func apply(_ status: RemoteHostStatus) {
        guard let record = records.first(where: { $0.id == status.hostID }) else { return }
        statuses[status.hostID] = status
        // A status is published for each state change, so the same reading can arrive twice. It is evaluated once.
        if let snapshot = status.snapshot, let received = status.receivedAt, lastEvaluated[record.id] != received {
            lastEvaluated[record.id] = received
            hostAlerts?.evaluate(host: .remote(record.id), label: record.label, snapshot: snapshot, receivedAt: received)
        }
        rebuild()
    }

    private func stopped(_ id: UUID, _ failure: RemoteFailure) -> RemoteHostStatus {
        RemoteHostStatus(hostID: id, state: .stopped(failure), hostName: nil, capabilities: nil, snapshot: nil, receivedAt: nil)
    }

    private func rebuild() {
        presentation = FleetOverviewPresentation(
            local: localSnapshot,
            records: records,
            statuses: statuses,
            pairing: pairing,
            draft: draft,
            notice: notice,
            canAddMore: records.count < Self.maximumRemoteMacs
        )
    }

    private static func account(_ id: UUID) -> String {
        "remote.\(id.uuidString)"
    }
}
