import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    /// The target temporarily leaves the UNIQUE lane while the original
    /// ordinal interval moves above it. Both interval updates have disjoint
    /// source/destination ranges, so correctness never relies on UPDATE order.
    /// All phases run inside executeCommitTransaction's one SQL transaction.
    internal func applyPinRelocation(_ relocation: PinRelocation, in database: SQLiteDatabase) throws {
        let previous = relocation.previousOrdinal?.rawValue
        let destination = relocation.destinationOrdinal?.rawValue
        let count = relocation.pinnedCountBefore
        let delta = (destination == nil ? 0 : 1) - (previous == nil ? 0 : 1)
        let (finalCount, countOverflow) = count.addingReportingOverflow(delta)
        guard count >= 0, !countOverflow,
              previous != destination,
              previous.map({ $0 >= 0 && $0 < count }) ?? true,
              destination.map({ $0 >= 0 && $0 < finalCount }) ?? true,
              finalCount >= 0 else {
            throw TransactionApplyRejection.finalPinOrderViolated
        }
        let old = try requireMutationRow(relocation.itemID, in: database)
        guard old.pinOrdinal == previous else { throw TransactionApplyRejection.finalPinOrderViolated }
        let state = try database.prepare(
            "SELECT pinnedItemCount FROM history_state WHERE key = ?", bindings: [.text(Self.positionSingletonKey)]
        )
        defer { state.finalize() }
        guard try state.step(), try state.integer(at: 0) == Int64(count) else {
            throw TransactionApplyRejection.finalPinOrderViolated
        }

        try database.execute("UPDATE history_items SET pinOrdinal = NULL WHERE id = ?",
                             bindings: [.text(relocation.itemID.rawValue.uuidString)])
        guard try database.changedRowCount == 1 else {
            throw TransactionApplyRejection.missingRow(itemID: relocation.itemID)
        }
        if let shift = relocation.shift {
            let lower = shift.range.lowerBound
            let upper = shift.range.upperBound
            guard lower >= 0, upper < count, shift.delta == -1 || shift.delta == 1,
                  previous.map({ !shift.range.contains($0) }) ?? true else {
                throw TransactionApplyRejection.finalPinOrderViolated
            }
            // B=P+1 leaves both the old lane and a newly inserted final P free.
            // Check the temporary SQL integer range rather than imposing a
            // product history-count cap (V2-09 §4/§9).
            let (base, baseOverflow) = Int64(count).addingReportingOverflow(1)
            let (temporaryUpper, upperOverflow) = Int64(upper).addingReportingOverflow(base)
            guard !baseOverflow, !upperOverflow else {
                throw HistoryFailure.capacityExceeded(.retainedItems)
            }
            let width = Int64(upper - lower + 1)
            try database.execute("""
                UPDATE history_items SET pinOrdinal = pinOrdinal + ?
                WHERE pinOrdinal BETWEEN ? AND ?
                """, bindings: [.integer(base), .integer(Int64(lower)), .integer(Int64(upper))])
            guard try database.changedRowCount == width else {
                throw TransactionApplyRejection.finalPinOrderViolated
            }
            try database.execute("""
                UPDATE history_items SET pinOrdinal = pinOrdinal - ? + ?
                WHERE pinOrdinal BETWEEN ? AND ?
                """, bindings: [
                    .integer(base), .integer(Int64(shift.delta)),
                    .integer(Int64(lower) + base), .integer(temporaryUpper),
                ])
            guard try database.changedRowCount == width else {
                throw TransactionApplyRejection.finalPinOrderViolated
            }
        }
        if let destination {
            try database.execute("UPDATE history_items SET pinOrdinal = ? WHERE id = ?", bindings: [
                .integer(Int64(destination)), .text(relocation.itemID.rawValue.uuidString),
            ])
            guard try database.changedRowCount == 1 else {
                throw TransactionApplyRejection.missingRow(itemID: relocation.itemID)
            }
        }
        if delta != 0 {
            try database.execute(
                "UPDATE history_state SET pinnedItemCount = pinnedItemCount + ? WHERE key = ?",
                bindings: [.integer(Int64(delta)), .text(Self.positionSingletonKey)]
            )
            guard try database.changedRowCount == 1 else { throw TransactionApplyRejection.finalPinOrderViolated }
        }
        // Pinned removal continues with .delete. It rereads this actual NULL
        // target and subtracts only retained count/content bytes, not pins twice.
    }
}
