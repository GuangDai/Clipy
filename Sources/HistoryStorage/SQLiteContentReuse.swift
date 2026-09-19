import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    /// V2-09 §§3/4: reuse existing immutable bytes within this item's current
    /// or Canonical content. Each indexed content/item/type key has at most one
    /// candidate; historical revisions and other items are not searched.
    /// Type equivalence narrows candidates; only byte-exact equality reuses a
    /// payload. The new representation row still owns its original spelling.
    internal func reusableRepresentation(
        _ representation: ContentRepresentation,
        itemID: HistoryItemID
    ) throws -> (inline: SQLiteValue, blobID: SQLiteValue)? {
        try Task.checkCancellation()
        let itemKey = itemID.rawValue.uuidString
        let statement = try database.prepare("""
            SELECT inlineBytes, blobID FROM representations
            WHERE contentID IN (
                SELECT currentContentID FROM history_items WHERE id = ?
                UNION
                SELECT id FROM contents WHERE itemID = ? AND revisionOrdinal = 0
            ) AND pasteboardItemIndex = ? AND typeKey = ? AND byteCount = ?
            LIMIT 2
            """, bindings: [
                .text(itemKey), .text(itemKey), .integer(Int64(representation.pasteboardItemIndex)),
                .text(representation.typeIdentifier.precomposedStringWithCanonicalMapping),
                .integer(Int64(representation.bytes.count)),
            ])
        defer { statement.finalize() }
        while try statement.step() {
            try Task.checkCancellation()
            switch (try statement.isNull(at: 0), try statement.isNull(at: 1)) {
            case (false, true):
                guard try statement.blobByteCount(at: 0) == representation.bytes.count else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                let bytes = try statement.blob(at: 0)
                if bytes == representation.bytes { return (.blob(bytes), .null) }
            case (true, false):
                guard try statement.textByteCount(at: 1) == 36 else {
                    throw HistoryFailure.persistence(.corruptStoredValue)
                }
                let identifier = try statement.text(at: 1)
                let id = try HistoryItemRowHydration.uuid(identifier)
                let bytes = try blobStore.read(id: id, expectedByteCount: representation.bytes.count)
                if bytes == representation.bytes { return (.null, .text(identifier)) }
            default:
                throw HistoryFailure.persistence(.corruptStoredValue)
            }
        }
        return nil
    }
}
