import Foundation
import HistoryCore
import HistoryDomain

/// V2-09 §4, 02 §9: persistent postings narrow the candidates, then every
/// representation is validated and compared as bytes. Only the current
/// representation and incoming capture stay alive during confirmation.
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
        let content = try HistoryItemRowHydration.contentMetadata(
            id: HistoryItemRowHydration.uuid(query.text(at: 0)), itemID: item.id, in: database
        )
        guard content.byteCount == item.canonicalBytes else { throw corrupt }
        let matched = try matchingCount(incoming: incoming, content: content, itemID: item.id,
                                        database: database, blobStore: blobStore, limits: limits)
        guard matched == incoming.representations.count else { return nil }
        return CanonicalCaptureMatch(
            value: CaptureMatch(id: item.id, occurrence: item.occurrence, pinOrdinal: item.pinOrdinal),
            extraRepresentationCount: content.representationCount - matched
        )
    }

    internal static func lineage(
        incoming: CanonicalContent, item: HistoryItemMetadata,
        database: SQLiteDatabase, blobStore: ImmutableBlobStore, limits: HistoryLimits
    ) throws -> CaptureMatch? {
        let content = try HistoryItemRowHydration.contentMetadata(
            id: item.currentContentID, itemID: item.id, in: database
        )
        guard item.revisionCount == 0 ? content.ordinal == 0 : content.ordinal > 0,
              content.ordinal == 0 ? content.byteCount == item.canonicalBytes
                : content.byteCount <= item.revisionBytes else { throw corrupt }
        let matched = try matchingCount(incoming: incoming, content: content, itemID: item.id,
                                        database: database, blobStore: blobStore, limits: limits)
        // A hint requires equal representation sets, unlike Canonical's
        // containment. A valid hint continues to precede Canonical ranking.
        guard matched == incoming.representations.count,
              matched == content.representationCount else { return nil }
        return CaptureMatch(id: item.id, occurrence: item.occurrence, pinOrdinal: item.pinOrdinal)
    }

    private static func matchingCount(
        incoming: CanonicalContent, content: HistoryContentMetadata, itemID: HistoryItemID,
        database: SQLiteDatabase, blobStore: ImmutableBlobStore, limits: HistoryLimits
    ) throws -> Int {
        // Type-only keys preserve Swift String canonical equivalence without
        // hashing payloads. Values share the caller's immutable incoming Data.
        let incomingByType = Dictionary(uniqueKeysWithValues: incoming.representations.map {
            ($0.content.typeIdentifier, $0.content)
        })
        var matched = 0
        try HistoryItemRowHydration.visitRepresentations(
            in: content, itemID: itemID, database: database, blobStore: blobStore, limits: limits
        ) { representation, _ in
            if incomingByType[representation.typeIdentifier] == representation { matched += 1 }
        }
        return matched
    }

    private static var corrupt: HistoryFailure { .persistence(.corruptStoredValue) }
}
