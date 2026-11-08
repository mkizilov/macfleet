import Foundation

/// Wording for VoiceOver and for compact visible labels that need words instead of symbols.
enum SpokenFormatting {
    private static let words = ["bytes", "kilobytes", "megabytes", "gigabytes", "terabytes", "petabytes"]

    static func bytes(_ value: UInt64, binary: Bool = false) -> String {
        bytes(Double(value), binary: binary)
    }

    static func bytes(_ value: Double, binary: Bool = false) -> String {
        let base = binary ? 1_024.0 : 1_000.0
        var scaled = value
        var unit = 0
        while scaled >= base - 0.5, unit < words.count - 1 {
            scaled /= base
            unit += 1
        }
        if unit == 0 {
            let whole = Int(scaled.rounded())
            return "\(whole) \(whole == 1 ? "byte" : "bytes")"
        }
        return "\(number(scaled)) \(words[unit])"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        "\(bytes(bytesPerSecond)) per second"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) percent"
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return "\(count(days, "day", "days")), \(count(hours, "hour", "hours"))"
        }
        if hours > 0 {
            return "\(count(hours, "hour", "hours")), \(count(minutes, "minute", "minutes"))"
        }
        return count(minutes, "minute", "minutes")
    }

    static func load(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func number(_ scaled: Double) -> String {
        let tenths = (scaled * 10).rounded() / 10
        return tenths < 10 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
    }

    private static func count(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value) \(value == 1 ? one : many)"
    }
}
