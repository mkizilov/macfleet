import Foundation

/// Byte, rate, and percentage text. Disk and network use decimal units (KB = 1,000 bytes), matching
/// Finder. Memory uses binary units (KB = 1,024 bytes), matching macOS memory displays.
public enum ByteFormatting {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    private static let compactUnits = ["B", "K", "M", "G", "T"]

    public static func string(bytes: Double) -> String {
        plain(bytes, base: 1_000)
    }

    public static func string(bytes: UInt64) -> String {
        string(bytes: Double(bytes))
    }

    public static func binary(bytes: UInt64) -> String {
        plain(Double(bytes), base: 1_024)
    }

    public static func rate(bytesPerSecond: Double) -> String {
        string(bytes: bytesPerSecond) + "/s"
    }

    /// Short form for tight spaces such as the menu bar: "512B", "40K", "1.2M".
    public static func compact(bytesPerSecond: Double) -> String {
        let (scaled, unit) = scale(bytesPerSecond, base: 1_000, unitCount: compactUnits.count)
        let number = unit == 0 ? "\(Int(scaled.rounded()))" : numberText(scaled)
        return number + compactUnits[unit]
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func plain(_ value: Double, base: Double) -> String {
        let (scaled, unit) = scale(value, base: base, unitCount: units.count)
        guard unit > 0 else { return "\(Int(scaled.rounded())) B" }
        return "\(numberText(scaled)) \(units[unit])"
    }

    /// Divides until the value would print with four or more digits, so rounding never shows "1000".
    private static func scale(_ value: Double, base: Double, unitCount: Int) -> (Double, Int) {
        var scaled = value
        var unit = 0
        while scaled >= base - 0.5, unit < unitCount - 1 {
            scaled /= base
            unit += 1
        }
        return (scaled, unit)
    }

    private static func numberText(_ scaled: Double) -> String {
        let tenths = (scaled * 10).rounded() / 10
        return tenths < 10 ? String(format: "%.1f", scaled) : String(format: "%.0f", scaled)
    }
}
