import MacFleetState
import SwiftUI

/// Compact status for the menu bar: CPU, memory, and network rates. Missing values show a dash.
public struct MenuBarLabelView: View {
    private let presentation: MenuBarPresentation?

    public init(presentation: MenuBarPresentation?) {
        self.presentation = presentation
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "server.rack")
            if let presentation {
                Text("\(presentation.cpuText) · \(presentation.memoryText)")
                    .monospacedDigit()
                Text(presentation.networkText)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation?.accessibilityLabel ?? "MacFleet. Waiting for the first sample.")
    }
}
