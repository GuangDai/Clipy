import Foundation
import HistoryCore

/// Explicit history ordering uses disjoint keyset ranges, keeping pagination
/// independent of the loaded UI window (04 §6; V2-09 §4). Unsigned counters are
/// stored as eight big-endian bytes, so SQLite BLOB order preserves UInt64.
internal enum HistorySortSQL {
    typealias Range = (condition: String, bindings: [SQLiteValue], order: String)
    typealias Anchor = (date: Date, count: UInt64, id: HistoryItemID)

    static func ranges(sortOrder: HistorySortOrder, anchor: Anchor?, reversed: Bool) -> [Range] {
        let idOrder = reversed ? "DESC" : "ASC"
        let idComparison = reversed ? "<=" : ">="
        let ascendingDate = (sortOrder == .oldestFirst) != reversed
        let dateOrder = ascendingDate ? "ASC" : "DESC"
        let dateComparison = ascendingDate ? ">" : "<"
        let countOrder = reversed ? "ASC" : "DESC"
        let countComparison = reversed ? ">" : "<"
        let ordinaryOrder = "lastCopiedAt \(dateOrder), id \(idOrder)"
        let fullOrder = sortOrder == .mostCopied ? "copyCount \(countOrder), \(ordinaryOrder)" : ordinaryOrder
        guard let anchor else { return [("1", [], fullOrder)] }
        let date = SQLiteValue.real(anchor.date.timeIntervalSinceReferenceDate)
        let id = SQLiteValue.text(anchor.id.rawValue.uuidString)
        if sortOrder == .mostCopied {
            let count = SQLiteValue.blob(sqliteUInt64(anchor.count))
            return [
                ("copyCount = ? AND lastCopiedAt = ? AND id \(idComparison) ?", [count, date, id], "id \(idOrder)"),
                ("copyCount = ? AND lastCopiedAt \(dateComparison) ?", [count, date], ordinaryOrder),
                ("copyCount \(countComparison) ?", [count], fullOrder),
            ]
        }
        return [
            ("lastCopiedAt = ? AND id \(idComparison) ?", [date, id], "id \(idOrder)"),
            ("lastCopiedAt \(dateComparison) ?", [date], ordinaryOrder),
        ]
    }

    static func anchor(for row: SearchCorpusRow) -> StoredOrderingAnchor {
        .metadata(lastCopiedAt: row.lastCopiedAt, copyCount: row.copyCount, id: row.id)
    }

    static func precedes(_ left: SearchCorpusRow, _ right: SearchCorpusRow, sortOrder: HistorySortOrder) -> Bool {
        if sortOrder == .mostCopied, left.copyCount != right.copyCount { return left.copyCount > right.copyCount }
        if left.lastCopiedAt != right.lastCopiedAt {
            return sortOrder == .oldestFirst ? left.lastCopiedAt < right.lastCopiedAt : left.lastCopiedAt > right.lastCopiedAt
        }
        return left.id < right.id
    }
}
