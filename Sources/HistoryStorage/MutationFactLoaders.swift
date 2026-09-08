/// Purpose-specific SQL facts. Only selected IDs and one item's current
/// content enter Domain planning; no ORM objects or full-store blobs exist.
import Foundation
import HistoryCore
import HistoryDomain

internal enum MutationFactLoaders {
    internal static func loadPinFacts(itemID: HistoryItemID, placement: PinnedPlacement? = nil,
                                     in database: SQLiteDatabase,
                                     limits: HistoryLimits = .standard) throws -> PinFacts {
        let count = try PinnedOrderSQL.validatedCount(in: database, limits: limits)
        let target = try pinLocation(itemID: itemID, pinnedCount: count, in: database)
        let anchor: PinOrdinal?
        if case .before(let anchorID)? = placement {
            anchor = try anchorID == itemID ? target.ordinal
                : pinLocation(itemID: anchorID, pinnedCount: count, in: database).ordinal
        } else {
            anchor = nil
        }
        return PinFacts(targetExists: target.exists, targetOrdinal: target.ordinal,
                        anchorOrdinal: anchor, pinnedCount: count)
    }

    private static func pinLocation(
        itemID: HistoryItemID, pinnedCount: Int, in database: SQLiteDatabase
    ) throws -> (exists: Bool, ordinal: PinOrdinal?) {
        let row = try database.prepare("SELECT pinOrdinal FROM history_items WHERE id=?",
                                       bindings: [.text(itemID.rawValue.uuidString)])
        defer { row.finalize() }
        guard try row.step() else { return (false, nil) }
        guard try !row.isNull(at: 0) else { return (true, nil) }
        let ordinal = try HistoryItemRowHydration.integer(row, 0)
        guard ordinal >= 0, ordinal < pinnedCount else { throw corrupt }
        return (true, PinOrdinal(rawValue: ordinal))
    }

    internal static func loadRemoveFacts(itemID: HistoryItemID, in database: SQLiteDatabase,
                                        limits: HistoryLimits = .standard) throws -> RemoveFacts {
        let row = try database.prepare("SELECT id,lastCopiedAt,pinOrdinal FROM history_items WHERE id=?",
                                       bindings: [.text(itemID.rawValue.uuidString)])
        defer { row.finalize() }
        let item = try row.step() ? HistoryItemRowHydration.retainedSummary(row) : nil
        let count = try PinnedOrderSQL.validatedCount(in: database, limits: limits)
        return RemoveFacts(item: item, pinnedCount: count)
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
                                          blobStore: ImmutableBlobStore, limits: HistoryLimits = .standard,
                                          expectedVersion: ContentVersion? = nil) throws -> RevisionFacts {
        guard let item = try HistoryItemRowHydration.metadata(itemID: itemID, in: database, limits: limits) else {
            throw HistoryFailure.notFound(itemID)
        }
        // A prepared revision can become stale while off the Authority.
        // Phase two must reject that obsolete proposal before reading any
        // canonical/current payload, just like preparation does (05 §6.2).
        if let expectedVersion {
            // Content reads already honor task cancellation; preserve that
            // exit when the obsolete request now skips those reads entirely.
            try Task.checkCancellation()
            guard expectedVersion == item.contentVersion else {
                throw HistoryFailure.staleContent(expected: expectedVersion, current: item.contentVersion)
            }
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
