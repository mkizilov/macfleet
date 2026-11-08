import Darwin
import Foundation
import os

public enum LogLevel: String, Codable, Sendable, Comparable {
    case debug
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A field value. Only text, numbers, and flags exist, so every record has the same easy-to-read shape.
public enum LogValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case flag(Bool)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .text(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .flag(value): try container.encode(value)
        }
    }
}

/// Log times are ISO 8601 with milliseconds, in UTC. The formatter is made per call, because formatters are not `Sendable`.
enum LogTime {
    static func text(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    static func date(_ text: String) throws -> Date {
        try Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }
}

/// One diagnostic record, written as a single JSON line.
public struct LogRecord: Codable, Equatable, Sendable {
    public let time: Date
    public let level: LogLevel
    public let event: String
    public let fields: [String: LogValue]
}

/// Structured diagnostic logging to a JSON-lines file. Each record is one line with a time, a level, an event name,
/// and fields. The file is owner-only, and it moves to `<path>.1` when it grows past `maximumBytes`, so the log is
/// bounded. Writing never throws: a record that cannot be written is reported on standard error, not dropped.
public final class StructuredLog: Sendable {
    private struct State {
        var handle: FileHandle?
        var size: UInt64
    }

    private let path: String
    private let minimumLevel: LogLevel
    private let maximumBytes: UInt64
    private let state: OSAllocatedUnfairLock<State>

    public init(path: String, minimumLevel: LogLevel = .info, maximumBytes: UInt64 = 5_000_000) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let handle = try Self.openForAppending(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        self.path = path
        self.minimumLevel = minimumLevel
        self.maximumBytes = maximumBytes
        state = OSAllocatedUnfairLock(initialState: State(handle: handle, size: size))
    }

    public func write(
        _ level: LogLevel,
        _ event: String,
        _ fields: [String: LogValue] = [:],
        at time: Date = Date()
    ) {
        guard level >= minimumLevel else { return }
        let record = LogRecord(time: time, level: level, event: event, fields: fields)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LogTime.text(date))
        }
        let line: Data
        do {
            line = try encoder.encode(record) + Data("\n".utf8)
        } catch {
            Self.reportToStandardError("a log record could not be encoded: \(error)")
            return
        }
        state.withLock { state in
            if state.size > 0, state.size + UInt64(line.count) > maximumBytes {
                rotate(&state)
            }
            do {
                try state.handle?.write(contentsOf: line)
                state.size += UInt64(line.count)
            } catch {
                Self.reportToStandardError("a log record could not be written: \(error.localizedDescription)")
            }
        }
    }

    /// Reads every record in a log file, in order. Lines that are not records are reported and skipped by the caller.
    public static func read(path: String) throws -> [LogRecord] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try LogTime.date(try decoder.singleValueContainer().decode(String.self))
        }
        return try text.split(separator: "\n").map { line in
            try decoder.decode(LogRecord.self, from: Data(line.utf8))
        }
    }

    private func rotate(_ state: inout State) {
        state.handle = nil
        let backup = path + ".1"
        if rename(path, backup) != 0, errno != ENOENT {
            Self.reportToStandardError("the log could not be rotated: \(String(cString: strerror(errno)))")
        }
        do {
            state.handle = try Self.openForAppending(path)
            state.size = 0
        } catch {
            Self.reportToStandardError("the log could not be reopened: \(error.localizedDescription)")
        }
    }

    private static func openForAppending(_ path: String) throws -> FileHandle {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else {
            throw AgentSecretError.writeFailed(path: path, reason: String(cString: strerror(errno)))
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func reportToStandardError(_ message: String) {
        FileHandle.standardError.write(Data("macfleet-headless: \(message)\n".utf8))
    }
}
