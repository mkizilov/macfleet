import MacFleetState
import SwiftUI

extension UsageLevel {
    /// System colors adapt to light and dark mode. Always paired with `title` and `symbolName`.
    var tint: Color {
        switch self {
        case .normal: .green
        case .elevated: .orange
        case .critical: .red
        }
    }

    var symbolName: String {
        switch self {
        case .normal: "checkmark.circle.fill"
        case .elevated: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

extension ChartRole {
    var color: Color {
        switch self {
        case .cpu: .blue
        case .memory: .purple
        case .download: .green
        case .upload: .orange
        }
    }
}
