/// SwiftData schema v1 (`HistorySchemaV1`): the durable rows behind
/// `SwiftDataHistory`.
/// Owning spec: docs/05-authority-kernel.md §3 (Part V); access rule:
/// docs/01-architecture.md §2 (all model types are internal to HistoryStorage
/// and never occur in a public or package signature).
///
/// The schema deliberately has no History Change Record table, no Operation
/// Record or external-connection table, no thumbnail/list/search cache table,
/// no version-map/checkpoint row, no separate pin table or denormalized
/// occupancy map, no enrichment or revision-retention metadata, and no
/// migration bridge from the current Maccy models (§3.3).
import Foundation
import SwiftData

/// The v1 schema (`HistorySchemaV1`) containing exactly `HistoryItemRow` and
/// `LastChangePositionRow`, registered with the `ModelContainer` at `open`
/// time (docs/05-authority-kernel.md §3).
///
/// `HistorySchemaV1` is also the conceptual version label referenced by the
/// §17 migration stance: a future schema change increments it and adds a
/// migration plan.
internal let v1Schema = Schema(HistoryItemRow.self, LastChangePositionRow.self)

/// Durable row for one retained History Item (docs/05-authority-kernel.md §3.1).
///
/// Semantic mapping (§3.1):
///
/// - `id` is the stable business ID; `PersistentIdentifier` is never exposed.
/// - `contentVersionRaw` is the current Effective Content version, always at
///   least 1.
/// - `canonicalBlob` holds the immutable Canonical representations including
///   per-representation fingerprint evidence (`CanonicalBlobV1`, §4).
/// - `revisionStateBlob` holds the full revision list plus the active Revision
///   ID (`RevisionStateBlobV1`, §4). The active revision's bytes are present
///   whenever `activeRevisionID` is non-nil; for a Canonical-state item
///   (`activeRevisionID == nil`) the revision list is empty and there are no
///   revision bytes — Effective Content equals Canonical Content.
/// - `canonicalSignatureBlob` holds durable scalar metadata
///   (`SignatureBlobV1`, §4) used to rebuild the complete Signature Index
///   without decoding content bytes.
/// - The projection fields are the durable bounded projection of the current
///   Effective Content for list/search (§15).
/// - The occurrence fields hold the full first/last time and source summary.
/// - `pinOrdinal` is the internal encoding of pinned order; `nil` is unpinned.
///
/// `@Attribute(.externalStorage)` is an implementation hint: correctness, byte
/// limits, and read isolation do not depend on whether SwiftData stores a blob
/// inline or externally (§3.1). There is no `pinned: Bool`, inactive-only
/// revision list, single `application` column, enrichment field, tombstone,
/// cache payload, durable change record, or SwiftData identity map.
@Model
internal final class HistoryItemRow {
    @Attribute(.unique)
    var id: UUID

    var contentVersionRaw: UInt64

    @Attribute(.externalStorage)
    var canonicalBlob: Data

    @Attribute(.externalStorage)
    var revisionStateBlob: Data

    var canonicalSignatureBlob: Data

    var projectionSchemaVersion: UInt16
    var title: String
    var searchBody: String
    var effectiveTypeIdentifiersBlob: Data

    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var copyCount: UInt64
    var firstSource: String?
    var lastSource: String?

    var pinOrdinal: Int?

    init(
        id: UUID,
        contentVersionRaw: UInt64,
        canonicalBlob: Data,
        revisionStateBlob: Data,
        canonicalSignatureBlob: Data,
        projectionSchemaVersion: UInt16,
        title: String,
        searchBody: String,
        effectiveTypeIdentifiersBlob: Data,
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        copyCount: UInt64,
        firstSource: String?,
        lastSource: String?,
        pinOrdinal: Int?
    ) {
        self.id = id
        self.contentVersionRaw = contentVersionRaw
        self.canonicalBlob = canonicalBlob
        self.revisionStateBlob = revisionStateBlob
        self.canonicalSignatureBlob = canonicalSignatureBlob
        self.projectionSchemaVersion = projectionSchemaVersion
        self.title = title
        self.searchBody = searchBody
        self.effectiveTypeIdentifiersBlob = effectiveTypeIdentifiersBlob
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.firstSource = firstSource
        self.lastSource = lastSource
        self.pinOrdinal = pinOrdinal
    }
}

/// Change-position and retention-policy singleton row
/// (docs/05-authority-kernel.md §3.2).
///
/// Exactly one row exists, keyed `key == "retained-history"`. Every non-empty
/// History Commit updates this row in the same transaction as its item
/// mutations; the first commit moves `rawValue` 0 → 1, so empty stores still
/// support an authoritative `HistoryPage(position: 0, rows: [])`. The same
/// singleton owns the current v1 retention policy (`maximumUnpinnedItems`) so
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
