import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite library, which ships in the macOS SDK and needs no installation.
/// Each instance has exactly one owner (`MetricHistoryStore`, an actor) and is never shared between threads.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var connection: OpaquePointer?
        let code = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard code == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            sqlite3_close_v2(connection)
            throw HistoryError.sqlite(message)
        }
        handle = connection
    }

    deinit {
        close()
    }

    /// Closes the connection. An open transaction is rolled back, as it would be after a crash.
    func close() {
        sqlite3_close_v2(handle)
        handle = nil
    }

    /// Rows changed by the most recent statement.
    var changes: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw HistoryError.sqlite("database is closed") }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw HistoryError.sqlite(message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw HistoryError.sqlite("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HistoryError.sqlite(message)
        }
        return SQLiteStatement(handle: statement, connection: handle)
    }

    /// Runs `body` in one transaction. If the body or the commit fails, nothing it wrote is kept.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        let value: T
        do {
            value = try body()
            try execute("COMMIT")
        } catch {
            do {
                try execute("ROLLBACK")
            } catch let rollbackError {
                throw HistoryError.sqlite("\(describeStorageError(error)); rollback also failed: \(describeStorageError(rollbackError))")
            }
            throw error
        }
        return value
    }

    /// `PRAGMA quick_check` output. A healthy file reports "ok".
    func integrityStatus() throws -> String {
        let statement = try prepare("PRAGMA quick_check")
        var lines: [String] = []
        while try statement.step() {
            lines.append(statement.text(at: 0))
        }
        return lines.joined(separator: "; ")
    }

    func userVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version")
        guard try statement.step() else { throw HistoryError.sqlite("user_version is missing") }
        return statement.int(at: 0)
    }

    private var message: String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

/// One prepared statement, finalized when released. Parameters are 1-based.
final class SQLiteStatement {
    private let handle: OpaquePointer
    private let connection: OpaquePointer

    fileprivate init(handle: OpaquePointer, connection: OpaquePointer) {
        self.handle = handle
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ value: Int, at index: Int32) throws {
        try check(sqlite3_bind_int64(handle, index, Int64(value)))
    }

    func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(handle, index, value))
    }

    func bind(_ value: Double?, at index: Int32) throws {
        if let value {
            try bind(value, at: index)
        } else {
            try check(sqlite3_bind_null(handle, index))
        }
    }

    func bind(_ value: String, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(sqlite3_bind_text(handle, index, value, -1, transient))
    }

    /// Advances the statement. Returns true when a row is available and false when it has finished.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW:
            true
        case SQLITE_DONE:
            false
        default:
            throw HistoryError.sqlite(message)
        }
    }

    /// Makes the statement reusable and clears its parameters.
    func reset() throws {
        try check(sqlite3_reset(handle))
        try check(sqlite3_clear_bindings(handle))
    }

    func int(at column: Int32) -> Int {
        Int(sqlite3_column_int64(handle, column))
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    func optionalDouble(at column: Int32) -> Double? {
        sqlite3_column_type(handle, column) == SQLITE_NULL ? nil : sqlite3_column_double(handle, column)
    }

    func text(at column: Int32) -> String {
        guard let pointer = sqlite3_column_text(handle, column) else { return "" }
        return String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw HistoryError.sqlite(message) }
    }

    private var message: String {
        String(cString: sqlite3_errmsg(connection))
    }
}

/// Human-readable text for an error thrown inside the storage layer.
func describeStorageError(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
