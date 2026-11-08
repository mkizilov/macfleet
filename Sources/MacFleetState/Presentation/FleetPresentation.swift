import Foundation
import MacFleetKit

/// The dot and word that show whether a Mac is reachable. Color is never the only signal, so each state has a word.
public enum ConnectionIndicator: Equatable, Sendable {
    case local
    case online
    case connecting
    case offline
    case attention
}

public enum MacCardAction: Equatable, Hashable, Sendable {
    case reconnect
    case trustAgain
    case remove
}

public struct MetricTile: Equatable, Sendable, Identifiable {
    public let title: String
    /// Visible text. An unavailable reading shows a dash, never zero.
    public let value: String
    public let spokenValue: String
    public let level: UsageLevel?

    public var id: String {
        title
    }
}

/// One Mac in the unified dashboard: the local Mac or a registered remote Mac.
public struct MacCardPresentation: Equatable, Sendable, Identifiable {
    public let id: String
    /// Nil for the local Mac.
    public let hostID: UUID?
    public let title: String
    public let address: String?
    public let indicator: ConnectionIndicator
    public let indicatorText: String
    public let statusText: String
    /// Why the Mac is not connected, and what to do about it. Nil while the Mac is connected.
    public let failureText: String?
    public let sampleText: String?
    public let metrics: [MetricTile]
    public let actions: [MacCardAction]
}

public struct DraftPresentation: Equatable, Sendable {
    public let label: String
    public let host: String
    public let port: String
    public let clientID: String
    public let secret: String
    public let canSubmit: Bool

    init(_ draft: PairingDraft) {
        label = draft.label
        host = draft.host
        port = draft.port
        clientID = draft.clientID
        secret = draft.secret
        canSubmit = [draft.label, draft.host, draft.port, draft.clientID, draft.secret].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// The identity a probe found, with what the user must check before trusting it.
public struct ConfirmationPresentation: Equatable, Sendable {
    public let title: String
    public let reportedName: String
    public let address: String
    public let fingerprint: String
    public let instructions: String
    public let confirmLabel: String
}

public enum PairingPresentation: Equatable, Sendable {
    case idle
    case probing(String)
    case confirming(ConfirmationPresentation)
    case failed(String)

    init(_ state: PairingState, records: [RemoteHostRecord]) {
        switch state {
        case .idle:
            self = .idle
        case let .probing(endpoint):
            self = .probing("Contacting \(endpoint.host):\(endpoint.port)…")
        case let .confirming(pending):
            self = .confirming(ConfirmationPresentation(pending, records: records))
        case let .failed(problem):
            self = .failed(PairingProblemWording.text(problem))
        }
    }
}

/// Everything the unified dashboard shows. Built when the state changes, never inside a view body.
public struct FleetOverviewPresentation: Equatable, Sendable {
    public let cards: [MacCardPresentation]
    public let draft: DraftPresentation
    public let pairing: PairingPresentation
    public let canAddMore: Bool
    public let notice: String?

    public init(
        local: RemoteSnapshot?,
        records: [RemoteHostRecord],
        statuses: [UUID: RemoteHostStatus],
        pairing: PairingState,
        draft: PairingDraft,
        notice: String?,
        canAddMore: Bool
    ) {
        let remote = records
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            .map { MacCardPresentation.remote($0, statuses[$0.id]) }
        cards = [MacCardPresentation.local(local)] + remote
        self.draft = DraftPresentation(draft)
        self.pairing = PairingPresentation(pairing, records: records)
        self.canAddMore = canAddMore
        self.notice = notice
    }
}

extension MacCardPresentation {
    static func local(_ snapshot: RemoteSnapshot?) -> MacCardPresentation {
        guard let snapshot else {
            return MacCardPresentation(
                id: "local",
                hostID: nil,
                title: "This Mac",
                address: nil,
                indicator: .local,
                indicatorText: "This Mac",
                statusText: "Waiting for the first sample",
                failureText: nil,
                sampleText: nil,
                metrics: [],
                actions: []
            )
        }
        return MacCardPresentation(
            id: "local",
            hostID: nil,
            title: "This Mac",
            address: nil,
            indicator: .local,
            indicatorText: "This Mac",
            statusText: "Sampling on this Mac",
            failureText: nil,
            sampleText: TimeText.sampled(snapshot.capturedAt, current: true),
            metrics: MetricTiles.all(snapshot),
            actions: []
        )
    }

    static func remote(_ record: RemoteHostRecord, _ status: RemoteHostStatus?) -> MacCardPresentation {
        let address = "\(record.host):\(record.port)"
        let state = status?.state ?? .connecting(attempt: 0)
        var failureText: String?
        let indicator: ConnectionIndicator
        let indicatorText: String
        let statusText: String
        let actions: [MacCardAction]

        switch state {
        case let .connecting(attempt):
            indicator = .connecting
            indicatorText = "Connecting"
            statusText = attempt == 0 ? "Connecting to \(address)…" : "Reconnecting to \(address)…"
            actions = [.remove]
        case .online:
            indicator = .online
            indicatorText = "Online"
            statusText = status?.hostName.map { "Reports as \($0)" } ?? "Connected"
            actions = [.remove]
        case let .reconnecting(attempt, retryAt, failure):
            indicator = .offline
            indicatorText = "Offline"
            statusText = "Attempt \(attempt) failed. Next try at \(TimeText.clock(retryAt))."
            failureText = RemoteFailureWording.text(failure)
            actions = [.reconnect, .remove]
        case let .stopped(failure):
            indicator = .attention
            indicatorText = "Stopped"
            statusText = "Retries have stopped until you act."
            failureText = RemoteFailureWording.text(failure)
            if case .identityChanged = failure {
                actions = [.trustAgain, .remove]
            } else {
                actions = [.reconnect, .remove]
            }
        }

        let isOnline: Bool
        if case .online = state {
            isOnline = true
        } else {
            isOnline = false
        }
        return MacCardPresentation(
            id: record.id.uuidString,
            hostID: record.id,
            title: record.label,
            address: address,
            indicator: indicator,
            indicatorText: indicatorText,
            statusText: statusText,
            failureText: failureText,
            sampleText: status?.snapshot.map { TimeText.sampled($0.capturedAt, current: isOnline) },
            metrics: status?.snapshot.map(MetricTiles.all) ?? [],
            actions: actions
        )
    }
}

extension ConfirmationPresentation {
    init(_ pending: PendingPairing, records: [RemoteHostRecord]) {
        let fingerprint = pending.probe.presentedFingerprint.description
        reportedName = pending.probe.host.displayName
        address = "\(pending.endpoint.host):\(pending.endpoint.port)"
        self.fingerprint = fingerprint
        switch pending.purpose {
        case .newMac:
            title = "Trust this Mac?"
            instructions = "Compare this fingerprint with `macfleet-headless identity show` on that Mac. Trust it only if they match. Trusting saves this certificate for future connections."
            confirmLabel = "Trust and Save"
        case let .trustAgain(recordID):
            let pinned = records.first { $0.id == recordID }?.pinnedFingerprint
            if pinned == pending.probe.presentedFingerprint {
                title = "Trust this Mac again?"
                instructions = "This is the certificate already trusted for this Mac, so nothing changes if you confirm."
                confirmLabel = "Keep Trusting"
            } else {
                title = "Trust the new certificate?"
                instructions = "This Mac's certificate changed since you paired it. Compare this fingerprint with `macfleet-headless identity show` on that Mac. Trust it only if they match."
                confirmLabel = "Trust New Certificate"
            }
        }
    }
}

/// The wording for every way a remote Mac can be down. Each message says what the user can do.
enum RemoteFailureWording {
    static func text(_ failure: RemoteFailure) -> String {
        switch failure {
        case let .unreachable(detail):
            "The Mac did not answer at this address. Check that Tailscale is connected on both Macs and that its monitoring agent is running. (\(detail))"
        case .timedOut:
            "The Mac stopped responding."
        case .hostRestarting:
            "The Mac is shutting down or restarting its monitoring agent."
        case let .hostError(message):
            "The Mac reported an error: \(message)"
        case .closed:
            "The connection closed."
        case let .certificateRejected(reason):
            "The Mac's certificate was rejected: \(reason). Replace or renew the certificate on that Mac, then reconnect."
        case .authenticationFailed:
            "The Mac rejected the client secret. Remove this Mac and pair it again with the secret from `macfleet-headless credential add`."
        case let .identityChanged(presented):
            "The Mac's certificate has changed." + (presented.map { " It now shows \($0.description)." } ?? "")
                + " Compare that fingerprint with `macfleet-headless identity show` on the Mac, then trust it only if they match."
        case .hostNotProven:
            "The Mac did not prove that it holds the client secret, so it was not trusted."
        case let .versionMismatch(supported):
            "No common protocol version. The Mac speaks \(supported.isEmpty ? "a version this app does not know" : supported.map(\.description).joined(separator: ", "))."
        case let .protocolError(detail):
            "The Mac sent a message this app cannot accept: \(detail)"
        case .credentialMissing:
            "No client secret is saved for this Mac. Remove it and pair it again."
        case .invalidAddress:
            "The saved address is not valid. Remove it and pair it again."
        }
    }
}

enum PairingProblemWording {
    static func text(_ problem: PairingProblem) -> String {
        switch problem {
        case .label:
            "Enter a name for this Mac, up to 64 characters."
        case let .address(error):
            switch error {
            case .empty: "Enter the Mac's Tailscale name or a private IP address."
            case .tooLong: "The address is too long."
            case .invalidName: "Use a name such as studio or studio.tailnet.ts.net, or a private IP address."
            case .publicAddress: "Public IP addresses are refused. Use the Mac's Tailscale name or a private address."
            case .invalidPort: "The port must be a number from 1 to 65535."
            }
        case .port:
            "The port must be a number from 1 to 65535."
        case .clientID:
            "The client ID can use letters, digits, dots, underscores, and hyphens, up to 64 characters."
        case .secret:
            "The client secret must be the base64 text that `macfleet-headless credential add` printed."
        case let .limitReached(limit):
            "MacFleet monitors at most \(limit) remote Macs. Remove one before adding another."
        case let .probe(failure):
            RemoteFailureWording.text(failure)
        case .notRegistered:
            "That Mac is no longer registered."
        case let .storage(detail):
            "The Mac could not be saved: \(detail)"
        }
    }
}

/// The metric tiles for one snapshot. Every reading that failed says why, and shows a dash.
enum MetricTiles {
    static func all(_ snapshot: RemoteSnapshot) -> [MetricTile] {
        [
            cpu(snapshot.cpuTotal),
            memory(snapshot.memory),
            pressure(snapshot.memoryPressure),
            network(snapshot.network),
            thermal(snapshot.thermal),
        ]
    }

    static func cpu(_ reading: MetricReading<Double>) -> MetricTile {
        switch reading {
        case let .available(total):
            usage("CPU", UsageValue(fraction: total))
        case let .unavailable(issue):
            unavailable("CPU", issue)
        }
    }

    static func memory(_ reading: MetricReading<MemoryUsage>) -> MetricTile {
        switch reading {
        case let .available(memory):
            guard let fraction = memory.usedFraction else {
                return unavailableText("Memory", "the total memory size is unknown")
            }
            return usage("Memory", UsageValue(fraction: fraction))
        case let .unavailable(issue):
            return unavailable("Memory", issue)
        }
    }

    static func pressure(_ reading: MetricReading<MemoryPressureLevel>) -> MetricTile {
        switch reading {
        case let .available(level):
            let title: String
            let severity: UsageLevel
            switch level {
            case .normal:
                title = "Normal"
                severity = .normal
            case .warning:
                title = "Warning"
                severity = .elevated
            case .critical:
                title = "Critical"
                severity = .critical
            }
            return MetricTile(title: "Pressure", value: title, spokenValue: "Memory pressure \(title.lowercased())", level: severity)
        case let .unavailable(issue):
            return unavailable("Pressure", issue)
        }
    }

    static func network(_ reading: MetricReading<[NetworkInterfaceMetrics]>) -> MetricTile {
        if let rate = AggregateNetworkRate.rate(reading) {
            return MetricTile(
                title: "Network",
                value: "↓ \(ByteFormatting.rate(bytesPerSecond: rate.receivedPerSecond)) ↑ \(ByteFormatting.rate(bytesPerSecond: rate.sentPerSecond))",
                spokenValue: "Download \(SpokenFormatting.rate(rate.receivedPerSecond)), upload \(SpokenFormatting.rate(rate.sentPerSecond))",
                level: nil
            )
        }
        switch reading {
        case let .unavailable(issue):
            return unavailable("Network", issue)
        case .available:
            return unavailableText("Network", "a monitored interface has no rate yet")
        }
    }

    static func thermal(_ reading: MetricReading<ThermalState>) -> MetricTile {
        switch reading {
        case let .available(state):
            let display = ThermalDisplay(state)
            return MetricTile(title: "Thermal", value: display.title, spokenValue: display.spokenText, level: display.level)
        case let .unavailable(issue):
            return unavailable("Thermal", issue)
        }
    }

    private static func usage(_ title: String, _ value: UsageValue) -> MetricTile {
        MetricTile(title: title, value: value.text, spokenValue: "\(title) \(value.spokenText)", level: value.level)
    }

    private static func unavailable(_ title: String, _ issue: MetricIssue) -> MetricTile {
        unavailableText(title, issue.errorDescription ?? "not available")
    }

    private static func unavailableText(_ title: String, _ reason: String) -> MetricTile {
        MetricTile(title: title, value: "–", spokenValue: "\(title) unavailable: \(reason)", level: nil)
    }
}

enum TimeText {
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func sampled(_ date: Date, current: Bool) -> String {
        current ? "Sampled \(clock(date))" : "Last sample \(clock(date)). Not current."
    }
}
