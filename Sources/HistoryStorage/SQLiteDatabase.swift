import Foundation
import HistoryCore
import SQLite3

/// V2-09 §4/§6: one actor owns each connection and all its statements.
/// This concrete, non-Sendable type exposes SQL, not a second model layer.
internal enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

/// Codes stay internal; public failures never contain SQL or clipboard bytes.
internal struct SQLiteFailure: Error, Equatable, Sendable {
    internal let code: Int32
    internal var primaryCode: Int32 { code & 0xFF }
    internal var isConstraint: Bool { primaryCode == SQLITE_CONSTRAINT }

    internal var historyFailure: HistoryFailure {
        switch primaryCode {
        case SQLITE_FULL:
            return .temporarilyUnavailable(.insufficientDiskSpace)
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .persistence(.corruptStoredValue)
        default:
            return .persistence(.transaction)
        }
    }

    internal var openFailure: HistoryFailure {
        switch primaryCode {
        case SQLITE_FULL, SQLITE_CORRUPT, SQLITE_NOTADB:
            return historyFailure
        default:
            return .persistence(.openStore)
        }
    }
}

internal final class SQLiteDatabase {
    private var handle: OpaquePointer?

    internal init(url: URL?, readOnly: Bool = false) throws {
        if let url, !url.isFileURL {
            throw HistoryFailure.persistence(.openStore)
        }
        guard !readOnly || url != nil else {
            throw HistoryFailure.persistence(.openStore)
        }
        var opened: OpaquePointer?
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(
            url?.path ?? ":memory:", &opened,
            flags | SQLITE_OPEN_NOMUTEX, nil
        )
        guard result == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw HistoryFailure.persistence(.openStore)
        }
        handle = opened
        do {
            try check(sqlite3_extended_result_codes(opened, 1))
            // A released owner's final GC batch can close its last connection
            // while this connection configures WAL. SQLite briefly excludes
            // new readers during that close/checkpoint (WAL documentation §9).
            // Let SQLite wait only during construction, with a finite limit.
            try check(sqlite3_busy_timeout(opened, 1_000))
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA cache_size = -4096")
            try execute("PRAGMA mmap_size = 0")
            if url != nil, !readOnly {
                let journal = try prepare("PRAGMA journal_mode = WAL")
                guard try journal.step(), try journal.text(at: 0) == "wal" else {
                    throw HistoryFailure.persistence(.openStore)
                }
                journal.finalize()
                try execute("PRAGMA synchronous = FULL")
                try execute("PRAGMA wal_autocheckpoint = 256")
            }
            // Ordinary reads/transactions still report BUSY immediately; this
            // is not a second writer coordinator or an application retry loop.
            try check(sqlite3_busy_timeout(opened, 0))
        } catch {
            sqlite3_close_v2(opened)
            handle = nil
            if let failure = error as? SQLiteFailure {
                throw failure.openFailure
            }
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Explicit close refuses live statements instead of invalidating their
    /// pointers. A statement retains its connection until it is finalized.
    internal func close() throws {
        guard let handle else { return }
        try check(sqlite3_close(handle))
        self.handle = nil
    }

    internal var lastInsertedRowID: Int64 {
        get throws { sqlite3_last_insert_rowid(try openHandle()) }
    }

    internal var changedRowCount: Int64 {
        get throws { sqlite3_changes64(try openHandle()) }
    }

    /// Each call executes one statement. Schema owners call this once per DDL
    /// statement, allowing bindings everywhere without string interpolation.
    internal func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { statement.finalize() }
        while try statement.step() {}
    }

    internal func prepare(
        _ sql: String, bindings: [SQLiteValue] = []
    ) throws -> SQLiteStatement {
        let database = try openHandle()
        guard !sql.utf8.contains(0) else { throw SQLiteFailure(code: SQLITE_MISUSE) }
        var prepared: OpaquePointer?
        var hasTrailingStatement = false
        let result = sql.withCString { pointer in
            var tail: UnsafePointer<CChar>?
            let result = sqlite3_prepare_v2(database, pointer, -1, &prepared, &tail)
            if let tail {
                hasTrailingStatement = !String(cString: tail)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return result
        }
        guard result == SQLITE_OK, let prepared, !hasTrailingStatement else {
            if let prepared { sqlite3_finalize(prepared) }
            if result != SQLITE_OK { throw failure(code: result) }
            throw SQLiteFailure(code: SQLITE_MISUSE)
        }
        let statement = SQLiteStatement(database: self, handle: prepared)
        try statement.bind(bindings)
        return statement
    }

    /// A snapshot starts at the first SELECT in this closure. All reads for
    /// one page/search snapshot run on this connection until COMMIT.
    internal func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try transaction(begin: "BEGIN DEFERRED", body)
    }

    /// V2-09 §6: item/revision/reference/aggregate/Gateway writes and the one
    /// ChangePosition advance commit together before a receipt is published.
    internal func writeTransaction<T>(_ body: () throws -> T) throws -> T {
        try transaction(begin: "BEGIN IMMEDIATE", body)
    }

    private func transaction<T>(begin: String, _ body: () throws -> T) throws -> T {
        let database = try openHandle()
        guard sqlite3_get_autocommit(database) != 0 else {
            throw SQLiteFailure(code: SQLITE_MISUSE)
        }
        try execute(begin)
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            // FULL/IOERR can already roll back the transaction themselves.
            // If SQLite still owns a transaction, rollback must finish before
            // another operation may reuse the connection.
            if sqlite3_get_autocommit(database) == 0 {
                do {
                    try execute("ROLLBACK")
                } catch {
                    sqlite3_close_v2(database)
                    handle = nil
                    throw error
                }
            }
            throw error
        }
    }

    fileprivate func openHandle() throws -> OpaquePointer {
        guard let handle else { throw SQLiteFailure(code: SQLITE_MISUSE) }
        return handle
    }

    fileprivate func failure(code: Int32) -> SQLiteFailure {
        guard let handle else { return SQLiteFailure(code: code) }
        let extended = sqlite3_extended_errcode(handle)
        return SQLiteFailure(code: (extended & 0xFF) == (code & 0xFF) ? extended : code)
    }

    fileprivate func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw failure(code: result) }
    }
}

internal final class SQLiteStatement {
    private let database: SQLiteDatabase
    private var handle: OpaquePointer?
    private var hasRow = false
    private var finished = false

    fileprivate init(database: SQLiteDatabase, handle: OpaquePointer) {
        self.database = database
        self.handle = handle
    }

    deinit {
        if let handle { sqlite3_finalize(handle) }
    }

    internal func finalize() {
        if let handle { sqlite3_finalize(handle) }
        handle = nil
        hasRow = false
        finished = true
    }

    internal func step() throws -> Bool {
        let handle = try openHandle()
        if finished { return false }
        hasRow = false
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW:
            hasRow = true
            return true
        case SQLITE_DONE:
            finished = true
            return false
        default:
            finished = true
            throw database.failure(code: result)
        }
    }

    internal func isNull(at column: Int32) throws -> Bool {
        try columnType(at: column) == SQLITE_NULL
    }

    internal func integer(at column: Int32) throws -> Int64 {
        try requireType(SQLITE_INTEGER, at: column)
        return sqlite3_column_int64(try openHandle(), column)
    }

    internal func real(at column: Int32) throws -> Double {
        try requireType(SQLITE_FLOAT, at: column)
        return sqlite3_column_double(try openHandle(), column)
    }

    internal func text(at column: Int32) throws -> String {
        try requireType(SQLITE_TEXT, at: column)
        let handle = try openHandle()
        // Explicit byte length preserves embedded NUL. Type checks precede
        // SQLite's coercing APIs; invalid persisted UTF-8 is never repaired.
        let pointer = sqlite3_column_text(handle, column)
        let count = Int(sqlite3_column_bytes(handle, column))
        guard let pointer else { throw database.failure(code: SQLITE_NOMEM) }
        let bytes = UnsafeBufferPointer(start: pointer, count: count)
        guard let value = String(validating: bytes, as: UTF8.self) else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        return value
    }

    internal func blob(at column: Int32) throws -> Data {
        try requireType(SQLITE_BLOB, at: column)
        let handle = try openHandle()
        let pointer = sqlite3_column_blob(handle, column)
        let count = Int(sqlite3_column_bytes(handle, column))
        if count == 0 { return Data() }
        guard let pointer else { throw database.failure(code: SQLITE_NOMEM) }
        return Data(bytes: pointer, count: count)
    }

    /// Search checks its byte budget before materializing a stored body.
    internal func blobByteCount(at column: Int32) throws -> Int {
        try requireType(SQLITE_BLOB, at: column)
        return Int(sqlite3_column_bytes(try openHandle(), column))
    }

    internal func textByteCount(at column: Int32) throws -> Int {
        try requireType(SQLITE_TEXT, at: column)
        return Int(sqlite3_column_bytes(try openHandle(), column))
    }

    internal func optionalText(at column: Int32) throws -> String? {
        try isNull(at: column) ? nil : text(at: column)
    }

    internal func optionalBlob(at column: Int32) throws -> Data? {
        try isNull(at: column) ? nil : blob(at: column)
    }

    fileprivate func bind(_ values: [SQLiteValue]) throws {
        let handle = try openHandle()
        guard Int(sqlite3_bind_parameter_count(handle)) == values.count else {
            throw SQLiteFailure(code: SQLITE_RANGE)
        }
        // SQLite's documented SQLITE_TRANSIENT sentinel copies buffers before
        // bind returns; no Swift pointers escape their withUnsafeBytes scope.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let column = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(handle, column)
            case let .integer(value):
                result = sqlite3_bind_int64(handle, column, value)
            case let .real(value):
                guard !value.isNaN else { throw SQLiteFailure(code: SQLITE_MISMATCH) }
                result = sqlite3_bind_double(handle, column, value)
            case let .text(value):
                result = value.withCString { pointer in
                    sqlite3_bind_text64(
                        handle, column, pointer, UInt64(value.utf8.count),
                        transient, UInt8(SQLITE_UTF8)
                    )
                }
            case let .blob(value):
                if value.isEmpty {
                    // A nil pointer would bind SQL NULL, not an empty BLOB.
                    result = sqlite3_bind_zeroblob(handle, column, 0)
                } else {
                    result = value.withUnsafeBytes { bytes in
                        sqlite3_bind_blob64(
                            handle, column, bytes.baseAddress, UInt64(bytes.count), transient
                        )
                    }
                }
            }
            try database.check(result)
        }
    }

    private func openHandle() throws -> OpaquePointer {
        _ = try database.openHandle()
        guard let handle else { throw SQLiteFailure(code: SQLITE_MISUSE) }
        return handle
    }

    private func columnType(at column: Int32) throws -> Int32 {
        let handle = try openHandle()
        guard hasRow, column >= 0, column < sqlite3_column_count(handle) else {
            throw SQLiteFailure(code: SQLITE_MISUSE)
        }
        return sqlite3_column_type(handle, column)
    }

    private func requireType(_ type: Int32, at column: Int32) throws {
        guard try columnType(at: column) == type else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
    }
}

/// Full UInt64 range and unsigned lexicographic ordering for ContentVersion,
/// ChangePosition and counters; SQLite INTEGER is signed and cannot hold it.
internal func sqliteUInt64(_ value: UInt64) -> Data {
    Data((0..<8).map { index in UInt8(truncatingIfNeeded: value >> ((7 - index) * 8)) })
}

internal func sqliteUInt64(_ data: Data) throws -> UInt64 {
    guard data.count == 8 else { throw HistoryFailure.persistence(.corruptStoredValue) }
    return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
}
