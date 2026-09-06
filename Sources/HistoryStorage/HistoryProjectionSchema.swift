/// The retained History item and its byte-exact list/search projections.
/// Clipboard content remains in immutable canonical/revision blobs; title
/// and search-body strings are encoded only as UTF-8 Data for persistence.
/// Owning spec: docs/05-authority-kernel.md §3, §15.
import Foundation
import SwiftData

@Model
internal final class HistoryItemRow {
    #Index<HistoryItemRow>([\.pinOrdinal, \.lastCopiedAt, \.idOrder])

    @Attribute(.unique)
    var id: UUID
    /// UUID's fixed-width uppercase text has the same order as its bytes.
    /// Persisting that sortable scalar lets count retention select a bounded
    /// oldest prefix even when every copy has the same timestamp (02 §12).
    var idOrder: String

    var contentVersionRaw: UInt64

    @Attribute(.externalStorage)
    var canonicalBlob: Data

    @Attribute(.externalStorage)
    var revisionStateBlob: Data

    var canonicalSignatureBlob: Data

    /// UTF-8 content bytes preserve a leading U+FEFF across materialization.
    var titleUTF8: Data
    /// Literal content bytes, decoded strictly only by body-reading paths.
    var searchBodyUTF8: Data
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
        self.idOrder = id.uuidString
        self.contentVersionRaw = contentVersionRaw
        self.canonicalBlob = canonicalBlob
        self.revisionStateBlob = revisionStateBlob
        self.canonicalSignatureBlob = canonicalSignatureBlob
        self.titleUTF8 = Data(title.utf8)
        self.searchBodyUTF8 = Data(searchBody.utf8)
        self.effectiveTypeIdentifiersBlob = effectiveTypeIdentifiersBlob
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.copyCount = copyCount
        self.firstSource = firstSource
        self.lastSource = lastSource
        self.pinOrdinal = pinOrdinal
    }
}
