/// Durable History change records and journal accounting.
/// Decoded SQLite values remain internal to HistoryStorage (V2-roadmap J.2/J.3).
import Foundation

/// One durable record per non-empty History Commit. `sequence` and
/// `changePositionRaw` are equal by construction; keeping both makes the
/// commit-to-journal cross-reference independently checkable at startup.
/// Affected item IDs remain inside the versioned bounded blob and therefore
/// reference History business identity by value, never by relationship.
internal struct HistoryChangeRecordRow: Sendable {
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
/// values and validation.
internal struct JournalConfigRow: Sendable {
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
