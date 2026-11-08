import MacFleetKit

/// A value ready for display, or the reason it cannot be shown.
public enum Presented<Value: Equatable & Sendable>: Equatable, Sendable {
    case available(Value)
    case unavailable(String)

    public var availableValue: Value? {
        if case let .available(value) = self { value } else { nil }
    }
}

/// Visible text paired with the wording VoiceOver should speak.
public struct Readout: Equatable, Sendable {
    public let visible: String
    public let spoken: String

    public init(visible: String, spoken: String) {
        self.visible = visible
        self.spoken = spoken
    }
}

/// Severity for color and icon. Always shown with a label, so color is never the only signal.
public enum UsageLevel: Equatable, Sendable {
    case normal
    case elevated
    case critical

    public static func forFraction(_ fraction: Double) -> UsageLevel {
        if fraction >= 0.9 { .critical } else if fraction >= 0.75 { .elevated } else { .normal }
    }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .elevated: "Elevated"
        case .critical: "Critical"
        }
    }
}

public struct UsageValue: Equatable, Sendable {
    /// Clamped to 0...1.
    public let fraction: Double
    public let text: String
    public let spokenText: String
    public let level: UsageLevel

    public init(fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        self.fraction = clamped
        text = ByteFormatting.percent(clamped)
        spokenText = "\(Int((clamped * 100).rounded())) percent"
        level = UsageLevel.forFraction(clamped)
    }
}

public enum ChartRole: Equatable, Sendable {
    case cpu
    case memory
    case download
    case upload
    case disk
}

public struct ChartSeries: Equatable, Sendable {
    public let role: ChartRole
    public let name: String
    public let samples: [Double?]

    public init(role: ChartRole, name: String, samples: [Double?]) {
        self.role = role
        self.name = name
        self.samples = samples
    }
}

/// Everything a chart view needs. Nothing in it depends on SwiftUI.
public struct ChartPresentation: Equatable, Sendable {
    public let title: String
    public let series: [ChartSeries]
    /// Value that maps to the top edge. Always greater than zero.
    public let ceiling: Double
    public let spokenSummary: String

    public init(title: String, series: [ChartSeries], ceiling: Double, spokenSummary: String) {
        self.title = title
        self.series = series
        self.ceiling = max(ceiling, .leastNonzeroMagnitude)
        self.spokenSummary = spokenSummary
    }
}

func presented<Input: Equatable & Sendable, Output: Equatable & Sendable>(
    _ reading: MetricReading<Input>,
    _ transform: (Input) -> Output
) -> Presented<Output> {
    switch reading {
    case let .available(value):
        .available(transform(value))
    case let .unavailable(issue):
        .unavailable(issue.errorDescription ?? "Unavailable")
    }
}
