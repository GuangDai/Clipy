import Foundation
import HistoryCore
import HistoryDomain

/// Canonical postings narrow the candidates. An ordinary capture may only
/// coalesce if the Canonical and current Effective content both contain the
/// incoming bytes. A validated lineage hint instead requires an exact match
/// with Effective content. Confirmation reads one stored representation at a time.
internal enum SQLiteCaptureConfirmation {
    internal static func canonical(
        incoming: CanonicalContent, item: HistoryItemMetadata,
        database: SQLiteDatabase, blobStore: ImmutableBlobStore, limits: HistoryLimits
    ) throws -> CanonicalCaptureMatch? {
        let query = try database.prepare(
            "SELECT id FROM contents WHERE itemID=? AND revisionOrdinal=0",
            bindings: [.text(item.id.rawValue.uuidString)]
        )
        defer { query.finalize() }
        guard try query.step() else { throw corrupt }
        guard try query.textByteCount(at: 0) == 36 else { throw corrupt }
        let content = try HistoryItemRowHydration.contentMetadata(
            id: HistoryItemRowHydration.uuid(query.text(at: 0)), itemID: item.id, in: database
        )
        guard content.byteCount == item.canonicalBytes else { throw corrupt }
        let matched = try matchingCount(incoming: incoming, content: content, itemID: item.id,
                                        database: database, blobStore: blobStore, limits: limits)
        guard matched == incoming.representations.count else { return nil }
        if item.revisionCount == 0 {
            guard item.currentContentID == content.id else { throw corrupt }
        } else {
            let effective = try currentContent(for: item, in: database)
            guard try matchingCount(incoming: incoming, content: effective, itemID: item.id,
                                    database: database, blobStore: blobStore, limits: limits) == matched
            else { return nil }
        }
        return CanonicalCaptureMatch(
            value: CaptureMatch(id: item.id, occurrence: item.occurrence, pinOrdinal: item.pinOrdinal),
            extraRepresentationCount: content.representationCount - matched
        )
    }

    internal static func lineage(
        incoming: CanonicalContent, item: HistoryItemMetadata,
        database: SQLiteDatabase, blobStore: ImmutableBlobStore, limits: HistoryLimits
    ) throws -> CaptureMatch? {
        let content = try currentContent(for: item, in: database)
        let matched = try matchingCount(incoming: incoming, content: content, itemID: item.id,
                                        database: database, blobStore: blobStore, limits: limits)
        // A hint requires equal representation sets, unlike Canonical's
        // containment. A valid hint continues to precede Canonical ranking.
        guard matched == incoming.representations.count,
              matched == content.representationCount else { return nil }
        return CaptureMatch(id: item.id, occurrence: item.occurrence, pinOrdinal: item.pinOrdinal)
    }

    private static func currentContent(
        for item: HistoryItemMetadata, in database: SQLiteDatabase
    ) throws -> HistoryContentMetadata {
        let content = try HistoryItemRowHydration.contentMetadata(
            id: item.currentContentID, itemID: item.id, in: database
        )
        guard item.revisionCount == 0 ? content.ordinal == 0 : content.ordinal > 0,
              content.ordinal == 0 ? content.byteCount == item.canonicalBytes
                : content.byteCount <= item.revisionBytes else { throw corrupt }
        return content
    }

    private static func matchingCount(
        incoming: CanonicalContent, content: HistoryContentMetadata, itemID: HistoryItemID,
        database: SQLiteDatabase, blobStore: ImmutableBlobStore, limits: HistoryLimits
    ) throws -> Int {
        // Item/type keys preserve Swift String canonical equivalence without
        // hashing payloads. Values share the caller's immutable incoming Data.
        let incomingByKey = Dictionary(uniqueKeysWithValues: incoming.representations.map {
            ($0.content.key, $0.content)
        })
        var matched = 0
        var lastItemIndex = -1
        try HistoryItemRowHydration.visitRepresentations(
            in: content, itemID: itemID, database: database, blobStore: blobStore, limits: limits
        ) { representation, _ in
            lastItemIndex = representation.pasteboardItemIndex
            if incomingByKey[representation.key] == representation { matched += 1 }
        }
        // Containment admits extra representations within matched system items.
        return lastItemIndex + 1 == incoming.pasteboardItemCount ? matched : 0
    }

    private static var corrupt: HistoryFailure { .persistence(.corruptStoredValue) }
}
