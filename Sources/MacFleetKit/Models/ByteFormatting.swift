import Foundation

/// Decimal (SI) units, matching how Finder shows disk capacity.
public enum ByteFormatting {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func string(bytes: Double) -> String {
        var scaled = bytes
        var unit = 0
        while scaled >= 999.5, unit < units.count - 1 {
            scaled /= 1_000
            unit += 1
        }
        guard unit > 0 else { return "\(Int(scaled.rounded())) B" }
        let tenths = (scaled * 10).rounded() / 10
        let text = tenths < 10 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
        return "\(text) \(units[unit])"
    }

    public static func string(bytes: UInt64) -> String {
        string(bytes: Double(bytes))
    }

    public static func rate(bytesPerSecond: Double) -> String {
        string(bytes: bytesPerSecond) + "/s"
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
