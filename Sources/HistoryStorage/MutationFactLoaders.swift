/// Purpose-specific SQL facts. Only selected IDs and one item's current
/// content enter Domain planning; no ORM objects or full-store blobs exist.
import Foundation
import HistoryCore
import HistoryDomain

internal enum MutationFactLoaders {
    internal static func loadCompletePinnedOrder(in database: SQLiteDatabase,
                                                 limits: HistoryLimits = .standard) throws -> CompletePinnedOrder {
        let rows = try database.prepare("SELECT id,pinOrdinal FROM history_items WHERE pinOrdinal IS NOT NULL ORDER BY pinOrdinal")
        defer { rows.finalize() }
        var ids: [HistoryItemID] = []
        while try rows.step() {
            guard try HistoryItemRowHydration.integer(rows, 1) == ids.count,
                  ids.count < limits.hardMaximumRetainedItems else { throw corrupt }
            ids.append(HistoryItemID(rawValue: try HistoryItemRowHydration.uuid(rows.text(at: 0))))
        }
        return CompletePinnedOrder(itemIDs: ids)
    }

    internal static func loadPinFacts(itemID: HistoryItemID, in database: SQLiteDatabase,
                                     limits: HistoryLimits = .standard) throws -> PinFacts {
        let row = try database.prepare("SELECT 1 FROM history_items WHERE id=?", bindings: [.text(itemID.rawValue.uuidString)])
        defer { row.finalize() }
        return PinFacts(targetExists: try row.step(), order: try loadCompletePinnedOrder(in: database, limits: limits))
    }

    internal static func loadRemoveFacts(itemID: HistoryItemID, in database: SQLiteDatabase,
                                        limits: HistoryLimits = .standard) throws -> RemoveFacts {
        let row = try database.prepare("SELECT id,lastCopiedAt,pinOrdinal FROM history_items WHERE id=?",
                                       bindings: [.text(itemID.rawValue.uuidString)])
        defer { row.finalize() }
        let item = try row.step() ? HistoryItemRowHydration.retainedSummary(row) : nil
        let order = try item?.pinOrdinal == nil ? CompletePinnedOrder(itemIDs: []) : loadCompletePinnedOrder(in: database, limits: limits)
        return RemoveFacts(item: item, pinnedOrder: order)
    }

    internal static func loadClearFacts(scope: ClearScope, in database: SQLiteDatabase,
                                       limits: HistoryLimits = .standard) throws -> ClearFacts {
        let state = try database.prepare(
            "SELECT retainedItemCount, pinnedItemCount FROM history_state WHERE key = 'retained-history'"
        )
        defer { state.finalize() }
        guard try state.step() else { throw corrupt }
        let retained = try HistoryItemRowHydration.integer(state, 0)
        let pinned = try HistoryItemRowHydration.integer(state, 1)
        guard retained >= 0, pinned >= 0, pinned <= retained else { throw corrupt }
        return ClearFacts(affectedCount: scope == .all ? retained : retained - pinned)
    }

    internal static func revisionSummaries(itemID: HistoryItemID, in database: SQLiteDatabase,
                                          limits: HistoryLimits = .standard) throws -> [RevisionRetentionSummary] {
        let rows = try database.prepare("""
            SELECT id,revisionOrdinal,contentByteCount FROM contents
            WHERE itemID=? AND revisionOrdinal>0 ORDER BY revisionOrdinal
            """, bindings: [.text(itemID.rawValue.uuidString)])
        defer { rows.finalize() }
        var result: [RevisionRetentionSummary] = []
        var previousOrdinal = 0
        var totalBytes = 0
        while try rows.step() {
            let ordinal = try HistoryItemRowHydration.integer(rows, 1)
            let bytes = try HistoryItemRowHydration.integer(rows, 2)
            guard ordinal > previousOrdinal, bytes > 0, bytes <= limits.maximumProposedRevisionBytes,
                  result.count < limits.maximumRevisionsPerItem else { throw corrupt }
            totalBytes += bytes
            guard totalBytes <= limits.maximumTotalRevisionBytesPerItem else { throw corrupt }
            result.append(RevisionRetentionSummary(id: RevisionID(rawValue: try HistoryItemRowHydration.uuid(rows.text(at: 0))), byteCount: bytes))
            previousOrdinal = ordinal
        }
        return result
    }

    internal static func loadRevisionFacts(itemID: HistoryItemID, in database: SQLiteDatabase,
                                          blobStore: ImmutableBlobStore, limits: HistoryLimits = .standard) throws -> RevisionFacts {
        guard let item = try HistoryItemRowHydration.metadata(itemID: itemID, in: database, limits: limits) else {
            throw HistoryFailure.notFound(itemID)
        }
        let canonical = try HistoryItemRowHydration.canonical(itemID: itemID, in: database, blobStore: blobStore, limits: limits)
        let currentMetadata = try HistoryItemRowHydration.contentMetadata(
            id: item.currentContentID, itemID: itemID, in: database)
        let current: EffectiveContent
        if currentMetadata.ordinal == 0 {
            // Before the first revision Effective is Canonical. Retain the
            // same immutable Data values instead of reading every file twice.
            current = EffectiveContent(representations: canonical.representations.map(\.content))
        } else {
            current = try HistoryItemRowHydration.content(id: item.currentContentID, itemID: itemID,
                in: database, blobStore: blobStore, limits: limits).content
        }
        let revisions = try revisionSummaries(itemID: itemID, in: database, limits: limits)
        let active = currentMetadata.ordinal == 0 ? nil : RevisionID(rawValue: currentMetadata.id)
        guard revisions.count == item.revisionCount,
              revisions.reduce(0, { $0 + $1.byteCount }) == item.revisionBytes,
              canonical.representations.reduce(0, { $0 + $1.content.bytes.count }) == item.canonicalBytes,
              (revisions.isEmpty ? active == nil : active.map { id in revisions.contains { $0.id == id } } == true)
        else { throw corrupt }
        return RevisionFacts(itemID: itemID, contentVersion: item.contentVersion,
                             canonical: canonical, current: current, revisions: revisions, activeRevisionID: active)
    }

    private static var corrupt: HistoryFailure { .persistence(.invariantViolation) }
}
