import Foundation
import HistoryCore

/// Request-owned source matching/validation inside the existing read snapshot.
/// Scan one item's metadata rows without collecting all its sources;
/// positive matches stop immediately, and every step observes cancellation.
internal final class SQLiteExpressionSources {
    private let database: SQLiteDatabase
    private let limits: HistoryLimits
    private let deadline: ContinuousClock.Instant?
    private var query: SQLiteStatement?
    private var identifierQuery: SQLiteStatement?
    private var filterSubstringQuery: SQLiteStatement?
    private var filterIdentifiersQuery: SQLiteStatement?

    internal init(database: SQLiteDatabase, limits: HistoryLimits, deadline: ContinuousClock.Instant? = nil) {
        self.database = database
        self.limits = limits
        self.deadline = deadline
    }

    internal func finish() {
        query?.finalize(); query = nil
        identifierQuery?.finalize(); identifierQuery = nil
        filterSubstringQuery?.finalize(); filterSubstringQuery = nil
        filterIdentifiersQuery?.finalize(); filterIdentifiersQuery = nil
    }

    /// SQL has already admitted this item through these exact ordinary source
    /// predicates. Confirm only the matching application, with strict type,
    /// byte bound and UTF-8 decoding; never gather the item's other sources.
    internal func validateFilter(_ item: HistoryItemID, filter: HistoryFilter) throws {
        if let substring = filter.sourceApplication {
            let bindings = [SQLiteValue.text(item.rawValue.uuidString), .text(substring)]
            if let filterSubstringQuery { try filterSubstringQuery.reset(bindings: bindings) }
            else {
                filterSubstringQuery = try database.prepare("""
                    SELECT application FROM copy_sources
                    WHERE itemID = ? AND instr(lower(application), lower(?)) > 0 LIMIT 1
                    """, bindings: bindings)
            }
            guard let filterSubstringQuery else { throw HistoryFailure.persistence(.invariantViolation) }
            try validateMatchedApplication(filterSubstringQuery)
        }
        if let identifiers = filter.sourceApplicationIDs {
            let bindings = [SQLiteValue.text(item.rawValue.uuidString)] + identifiers.map(SQLiteValue.text)
            if let filterIdentifiersQuery { try filterIdentifiersQuery.reset(bindings: bindings) }
            else {
                let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
                filterIdentifiersQuery = try database.prepare("""
                    SELECT application FROM copy_sources
                    WHERE itemID = ? AND application IN (\(placeholders)) LIMIT 1
                    """, bindings: bindings)
            }
            guard let filterIdentifiersQuery else { throw HistoryFailure.persistence(.invariantViolation) }
            try validateMatchedApplication(filterIdentifiersQuery)
        }
    }

    private func validateMatchedApplication(_ statement: SQLiteStatement) throws {
        try checkReadInterruption()
        guard try statement.step() else { throw HistoryFailure.persistence(.invariantViolation) }
        _ = try readApplication(statement)
    }

    private func checkReadInterruption() throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline {
            throw HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)
        }
    }

    private func readApplication(_ statement: SQLiteStatement) throws -> String {
        guard try statement.textByteCount(at: 0) <= limits.maximumSourceApplicationObservationUTF8Bytes else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        return try statement.text(at: 0)
    }

    internal func contains(
        _ item: HistoryItemID, identifier: String?, matching predicate: (String) -> Bool
    ) throws -> Bool {
        let statement: SQLiteStatement
        if let identifier {
            let bindings = [SQLiteValue.text(identifier), .text(item.rawValue.uuidString)]
            if let identifierQuery { try identifierQuery.reset(bindings: bindings) }
            else {
                identifierQuery = try database.prepare(
                    "SELECT application FROM copy_sources WHERE application = ? AND itemID = ? LIMIT 1", bindings: bindings
                )
            }
            guard let identifierQuery else { throw HistoryFailure.persistence(.invariantViolation) }
            statement = identifierQuery
        } else {
            let bindings = [SQLiteValue.text(item.rawValue.uuidString)]
            if let query { try query.reset(bindings: bindings) }
            else {
                query = try database.prepare("SELECT application FROM copy_sources WHERE itemID = ?", bindings: bindings)
            }
            guard let query else { throw HistoryFailure.persistence(.invariantViolation) }
            statement = query
        }
        while true {
            try checkReadInterruption()
            guard try statement.step() else { return false }
            if try statement.isNull(at: 0) { continue }
            if predicate(try readApplication(statement)) { return true }
        }
    }
}
