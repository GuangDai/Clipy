import Foundation
import HistoryCore

/// D12 under the current UNIQUE partial pinOrdinal index: count/min/max
/// prove the dense lane without transferring pinned IDs or an ordinal array.
/// SQLite may visit O(P) entries; the returned Swift facts remain O(1).
internal enum PinnedOrderSQL {
    internal static func validatedCount(
        in database: SQLiteDatabase, limits: HistoryLimits = .standard
    ) throws -> Int {
        let state = try database.prepare("""
            SELECT pinnedItemCount,retainedItemCount FROM history_state WHERE key='retained-history'
            """)
        defer { state.finalize() }
        guard try state.step() else { throw corrupt }
        let pinned = try state.integer(at: 0)
        let retained = try state.integer(at: 1)
        guard pinned >= 0, pinned <= retained, retained <= Int64(limits.hardMaximumRetainedItems) else {
            throw corrupt
        }
        let rows = try database.prepare("""
            SELECT COUNT(*),MIN(pinOrdinal),MAX(pinOrdinal),
                   COUNT(CASE WHEN typeof(pinOrdinal)='integer' THEN 1 END)
            FROM history_items WHERE pinOrdinal IS NOT NULL
            """)
        defer { rows.finalize() }
        // SQLite INTEGER affinity alone still accepts fractional REAL values.
        // Check their storage class without bringing individual ordinals into Swift.
        guard try rows.step(), try rows.integer(at: 0) == pinned,
              try rows.integer(at: 3) == pinned else { throw corrupt }
        if pinned == 0 {
            guard try rows.isNull(at: 1), try rows.isNull(at: 2) else { throw corrupt }
        } else {
            guard try rows.integer(at: 1) == 0, try rows.integer(at: 2) == pinned - 1 else { throw corrupt }
        }
        return Int(pinned)
    }

    private static var corrupt: HistoryFailure { .persistence(.invariantViolation) }
}
