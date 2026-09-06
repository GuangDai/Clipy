/// Current durable History schema. All models remain internal to
/// HistoryStorage; no storage-model type crosses the public History seam.
/// Owning spec: docs/05-authority-kernel.md §3; docs/01-architecture.md §2.
import Foundation
import SwiftData

internal let historySchema = Schema(
    HistoryItemRow.self,
    LastChangePositionRow.self,
    RetentionExpansionConfigRow.self,
    RetainedBytesRow.self,
    ConnectionRow.self,
    GrantRow.self,
    OperationRecordRow.self,
    GatewayConfigRow.self,
    HistoryChangeRecordRow.self,
    JournalConfigRow.self
)

/// Change-position and retention-policy singleton row
/// (docs/05-authority-kernel.md §3.2).
///
/// Exactly one row exists, keyed `key == "retained-history"`. Every non-empty
/// History Commit updates this row in the same transaction as its item
/// mutations; the first commit moves `rawValue` 0 → 1, so empty stores still
/// support an authoritative `HistoryPage(position: 0, rows: [])`. The same
/// singleton owns the current count retention policy (`maximumUnpinnedItems`) so
/// capture and policy changes read one authoritative value.
///
/// The singleton is not a journal: it only identifies the latest durable
/// History Commit.
@Model
internal final class LastChangePositionRow {
    @Attribute(.unique)
    var key: String        // always "retained-history"
    var rawValue: UInt64   // 0 before the first History Commit
    var maximumUnpinnedItems: Int

    init(key: String, rawValue: UInt64, maximumUnpinnedItems: Int) {
        self.key = key
        self.rawValue = rawValue
        self.maximumUnpinnedItems = maximumUnpinnedItems
    }
}
