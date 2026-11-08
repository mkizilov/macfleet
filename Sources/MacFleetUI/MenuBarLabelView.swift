import MacFleetState
import SwiftUI

/// The menu bar label: the icon, then the metrics the user chose. With none chosen it is the icon alone. Values that
/// could not be read show a dash, and VoiceOver reads the full label.
public struct MenuBarLabelView: View {
    private let presentation: MenuBarLabelPresentation?

    public init(presentation: MenuBarLabelPresentation?) {
        self.presentation = presentation
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
            if let presentation, !presentation.items.isEmpty {
                Text(presentation.visibleText)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation?.accessibilityLabel ?? "MacFleet. Waiting for the first sample.")
    }
}
