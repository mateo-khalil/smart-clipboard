import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite \(code): \(message)" }
}

private var transientDestructor: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// Thin wrapper over the system SQLite. Each instance is confined to one queue.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close_v2(handle)
            handle = nil
            throw SQLiteError(code: status, message: message)
        }
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw lastError(status) }
    }

    func statement(_ sql: String) throws -> Statement {
        var pointer: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &pointer, nil)
        guard status == SQLITE_OK, let pointer else { throw lastError(status) }
        return Statement(pointer: pointer, database: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        let query = try statement(sql)
        return try query.step() ? query.int(0) : 0
    }

    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    func lastError(_ status: Int32) -> SQLiteError {
        SQLiteError(code: status, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")
    }
}

final class Statement {
    private let pointer: OpaquePointer
    private let database: Database

    fileprivate init(pointer: OpaquePointer, database: Database) {
        self.pointer = pointer
        self.database = database
    }

    deinit {
        sqlite3_finalize(pointer)
    }

    func bind(_ index: Int32, _ value: Int64?) {
        if let value { sqlite3_bind_int64(pointer, index, value) } else { sqlite3_bind_null(pointer, index) }
    }

    func bind(_ index: Int32, _ value: Double) {
        sqlite3_bind_double(pointer, index, value)
    }

    func bind(_ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(pointer, index, value, -1, transientDestructor)
        } else {
            sqlite3_bind_null(pointer, index)
        }
    }

    func bind(_ index: Int32, _ value: Data?) {
        guard let value else {
            sqlite3_bind_null(pointer, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            // An empty blob still needs a non-null pointer to stay distinct from NULL.
            if bytes.count == 0 {
                sqlite3_bind_zeroblob(pointer, index, 0)
            } else {
                sqlite3_bind_blob(pointer, index, bytes.baseAddress, Int32(bytes.count), transientDestructor)
            }
        }
    }

    /// Returns `true` while there is a row to read.
    func step() throws -> Bool {
        let status = sqlite3_step(pointer)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.lastError(status)
        }
    }

    func reset() {
        sqlite3_reset(pointer)
        sqlite3_clear_bindings(pointer)
    }

    func run() throws {
        _ = try step()
        reset()
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(pointer, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(pointer, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(pointer, column) }

    func string(_ column: Int32) -> String? {
        guard let text = sqlite3_column_text(pointer, column) else { return nil }
        return String(cString: text)
    }

    func data(_ column: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(pointer, column) else { return isNull(column) ? nil : Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(pointer, column)))
    }

    /// Zero-copy view of a text column, valid only until the next step.
    func withTextBytes<T>(_ column: Int32, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        let text = sqlite3_column_text(pointer, column)
        let count = Int(sqlite3_column_bytes(pointer, column))
        return body(UnsafeBufferPointer(start: text, count: count))
    }
}
