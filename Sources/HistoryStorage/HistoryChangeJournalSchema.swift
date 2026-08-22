/// Internal HCR-only V4 schema prerequisite (`V2-roadmap` J.2/J.3 and the
/// 2026-08-23 DC-25 controlling amendment). The shipped `HistorySchemaV3`
/// remains immutable; this additive graft introduces exactly the durable
/// commit record and its minimal accounting singleton. It deliberately does
/// not admit reconnect cursors, collection-cache state, materializer state,
/// store identity, user-configurable limits, or a public journal surface.
import Foundation
import SwiftData

/// The fourth shipped schema: immutable V3 plus the two HCR-only rows. The
/// V3 → V4 hop adds tables only, so it requires no historical HCR backfill
/// and rewrites no existing row or column.
internal enum HistorySchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        HistorySchemaV3.models + [
            HistoryChangeRecordRow.self,
            JournalConfigRow.self,
        ]
    }
}

/// One durable record per non-empty History Commit. `sequence` and
/// `changePositionRaw` are equal by construction; keeping both makes the
/// commit-to-journal cross-reference independently checkable at startup.
/// Affected item IDs remain inside the versioned bounded blob and therefore
/// reference History business identity by value, never by relationship.
@Model
internal final class HistoryChangeRecordRow {
    @Attribute(.unique)
    var sequence: UInt64

    var changePositionRaw: UInt64
    var changeKindRaw: Int16
    var affectedItemsBlob: Data
    var createdAt: Date

    init(
        sequence: UInt64,
        changePositionRaw: UInt64,
        changeKindRaw: Int16,
        affectedItemsBlob: Data,
        createdAt: Date
    ) {
        self.sequence = sequence
        self.changePositionRaw = changePositionRaw
        self.changeKindRaw = changeKindRaw
        self.affectedItemsBlob = affectedItemsBlob
        self.createdAt = createdAt
    }
}

/// Minimal HCR-only singleton keyed by `"change-journal"`.
///
/// `compactionFloorRaw` is the greatest ChangePosition intentionally absent
/// from the retained journal. Retained rows must form the exact contiguous
/// interval `(compactionFloorRaw, currentPosition]`; an empty journal has
/// `compactionFloorRaw == currentPosition` and `journalBytes == 0`.
/// `journalBytes` is the checked exact sum of each retained record's
/// `affectedItemsBlob.count`. The later Authority bootstrap owns initial
/// values and validation; migration itself inserts no row.
@Model
internal final class JournalConfigRow {
    @Attribute(.unique)
    var key: String

    var compactionFloorRaw: UInt64
    var journalBytes: UInt64
    var configSchemaVersion: UInt16

    init(
        key: String,
        compactionFloorRaw: UInt64,
        journalBytes: UInt64,
        configSchemaVersion: UInt16
    ) {
        self.key = key
        self.compactionFloorRaw = compactionFloorRaw
        self.journalBytes = journalBytes
        self.configSchemaVersion = configSchemaVersion
    }
}
