import MacFleetState
import SwiftUI

/// The unified dashboard: the local Mac, every registered remote Mac, and the form that adds one. It takes presentation
/// values and action closures only, so it holds no state of its own.
public struct FleetOverviewView: View {
    private let presentation: FleetOverviewPresentation
    private let onField: @Sendable (PairingField, String) -> Void
    private let onCheck: @Sendable () -> Void
    private let onConfirm: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    private let onAction: @Sendable (UUID, MacCardAction) -> Void

    public init(
        presentation: FleetOverviewPresentation,
        onField: @escaping @Sendable (PairingField, String) -> Void,
        onCheck: @escaping @Sendable () -> Void,
        onConfirm: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void,
        onAction: @escaping @Sendable (UUID, MacCardAction) -> Void
    ) {
        self.presentation = presentation
        self.onField = onField
        self.onCheck = onCheck
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onAction = onAction
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Fleet")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let notice = presentation.notice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(presentation.cards) { card in
                    MacCardView(card: card, onAction: onAction)
                }
                PairingFormView(
                    draft: presentation.draft,
                    pairing: presentation.pairing,
                    canAddMore: presentation.canAddMore,
                    onField: onField,
                    onCheck: onCheck,
                    onConfirm: onConfirm,
                    onCancel: onCancel
                )
            }
            .padding()
        }
        .frame(minWidth: 460, minHeight: 600)
    }
}

/// One Mac: its reachability, why it is not connected, its metrics, and the actions that apply to it.
struct MacCardView: View {
    let card: MacCardPresentation
    let onAction: @Sendable (UUID, MacCardAction) -> Void

    var body: some View {
        SectionCard(card.title) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: card.indicator))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(card.indicatorText)
                    .font(.caption.weight(.semibold))
                if let address = card.address {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(card.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure = card.failureText {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sample = card.sampleText {
                Text(sample)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !card.metrics.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
                    ForEach(card.metrics) { tile in
                        MetricTileView(tile: tile)
                    }
                }
            }
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let hostID = card.hostID, !card.actions.isEmpty {
            HStack {
                ForEach(card.actions, id: \.self) { action in
                    switch action {
                    case .reconnect:
                        Button("Reconnect") { onAction(hostID, .reconnect) }
                    case .trustAgain:
                        Button("Review New Certificate") { onAction(hostID, .trustAgain) }
                    case .remove:
                        Button("Remove", role: .destructive) { onAction(hostID, .remove) }
                    }
                }
            }
        }
    }

    private func color(for indicator: ConnectionIndicator) -> Color {
        switch indicator {
        case .local: .blue
        case .online: .green
        case .connecting: .yellow
        case .offline: .orange
        case .attention: .red
        }
    }
}

private struct MetricTileView: View {
    let tile: MetricTile

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tile.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text(tile.value)
                    .font(.caption.monospacedDigit())
                if let level = tile.level, level != .normal {
                    Text(level.title)
                        .font(.caption2.weight(.semibold))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tile.spokenValue)
    }
}

/// The add-a-Mac form. Checking an address shows the identity it presents, and nothing is saved until the user confirms.
struct PairingFormView: View {
    let draft: DraftPresentation
    let pairing: PairingPresentation
    let canAddMore: Bool
    let onField: @Sendable (PairingField, String) -> Void
    let onCheck: @Sendable () -> Void
    let onConfirm: @Sendable () -> Void
    let onCancel: @Sendable () -> Void

    var body: some View {
        SectionCard("Add a Mac") {
            if canAddMore {
                TextField("Name", text: binding(draft.label) { onField(.label, $0) })
                TextField("Tailscale name or private IP address", text: binding(draft.host) { onField(.host, $0) })
                TextField("Port", text: binding(draft.port) { onField(.port, $0) })
                TextField("Client ID", text: binding(draft.clientID) { onField(.clientID, $0) })
                SecureField("Client secret", text: binding(draft.secret) { onField(.secret, $0) })
                Text("Create the secret on that Mac with `macfleet-headless credential add`.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Check Identity", action: onCheck)
                    .disabled(!draft.canSubmit)
            } else {
                Text("Remove a Mac before adding another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            pairingBody
        }
    }

    @ViewBuilder
    private var pairingBody: some View {
        switch pairing {
        case .idle:
            EmptyView()
        case let .probing(text):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
                    .font(.caption)
            }
        case let .confirming(confirmation):
            VStack(alignment: .leading, spacing: 6) {
                Text(confirmation.title)
                    .font(.subheadline.weight(.semibold))
                Text("Reports as \(confirmation.reportedName) at \(confirmation.address)")
                    .font(.caption)
                Text(confirmation.fingerprint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(confirmation.instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(confirmation.confirmLabel, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                    Button("Cancel", action: onCancel)
                }
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(_ value: String, _ change: @escaping @Sendable (String) -> Void) -> Binding<String> {
        Binding(get: { value }, set: change)
    }
}
