import Foundation
import MacFleetKit

/// One value in the menu bar: what is drawn, and what VoiceOver reads for it.
public struct MenuBarItem: Equatable, Sendable, Identifiable {
    public let metric: MenuBarMetric
    public let text: String
    public let spokenText: String

    public var id: MenuBarMetric {
        metric
    }
}

/// The menu bar label for the metrics the user chose. Built when a sample arrives, never in a view body. With no metrics
/// chosen it is the icon alone.
public struct MenuBarLabelPresentation: Equatable, Sendable {
    public let items: [MenuBarItem]
    /// What is drawn: the items joined with a middle dot.
    public let visibleText: String
    public let accessibilityLabel: String

    public init(menuBar: MenuBarPresentation, metrics: [MenuBarMetric]) {
        items = metrics.map(menuBar.item(for:))
        visibleText = items.map(\.text).joined(separator: " · ")
        accessibilityLabel = (["MacFleet."] + items.map(\.spokenText)).joined(separator: " ")
    }
}
