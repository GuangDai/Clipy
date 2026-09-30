import Foundation
import HistoryCore

/// Request-owned source matching inside the search's existing SQLite snapshot.
/// Scan one item's metadata rows without collecting all its sources;
/// positive matches stop immediately, and every step observes cancellation.
internal final class SQLiteExpressionSources {
    private let database: SQLiteDatabase
    private let limits: HistoryLimits
    private let deadline: ContinuousClock.Instant
    private var query: SQLiteStatement?
    private var identifierQuery: SQLiteStatement?

    internal init(database: SQLiteDatabase, limits: HistoryLimits, deadline: ContinuousClock.Instant) {
        self.database = database
        self.limits = limits
        self.deadline = deadline
    }

    internal func finish() {
        query?.finalize(); query = nil
        identifierQuery?.finalize(); identifierQuery = nil
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
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)
            }
            guard try statement.step() else { return false }
            if try statement.isNull(at: 0) { continue }
            guard try statement.textByteCount(at: 0) <= limits.maximumSourceApplicationObservationUTF8Bytes else {
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
            if predicate(try statement.text(at: 0)) { return true }
        }
    }
}
