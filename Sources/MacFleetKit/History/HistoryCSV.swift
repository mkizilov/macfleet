import Foundation

/// Writes history rows as CSV. Fields that hold a comma, a quote, or a line break are quoted, with quotes doubled. A
/// missing value is an empty field, never zero, so an export cannot show a gap as a reading.
public enum HistoryCSV {
    public static let header = "time_utc,resolution,host_id,host,metric,mean,maximum,observations,snapshots"

    public static func render(_ rows: [HistoryExportRow], labels: [HistoryHostID: String]) -> String {
        var lines = [header]
        lines.reserveCapacity(rows.count + 1)
        for row in rows {
            lines.append([
                timestamp(row.time),
                row.resolution.label,
                field(row.host.rawValue),
                field(labels[row.host] ?? row.host.rawValue),
                field(row.metric),
                number(row.mean),
                number(row.maximum),
                String(row.observations),
                String(row.snapshots),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func number(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
