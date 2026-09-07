/// Scalar content-byte facts for ordered retention selection (V2-02 §3.2).
/// Storage supplies current item scalars without loading content bytes; a
/// prospective insertion supplies its prepared canonical byte count.
import Foundation
import HistoryCore

package struct RetentionExpansionItemSummary: Sendable, Hashable {
    package let id: HistoryItemID
    /// R1 reads this (`V2-02` §4.2); already in v1 `RetainedItemSummary`.
    package let lastCopiedAt: Date
    package let pinOrdinal: PinOrdinal?
    /// Canonical representation bytes, independent of inline/blob placement.
    package let canonicalBytes: Int
    /// Stored revision count and complete representation-byte total.
    package let revisionCount: Int
    package let revisionBytes: Int

    package init(
        id: HistoryItemID,
        lastCopiedAt: Date,
        pinOrdinal: PinOrdinal?,
        canonicalBytes: Int,
        revisionCount: Int,
        revisionBytes: Int
    ) {
        self.id = id
        self.lastCopiedAt = lastCopiedAt
        self.pinOrdinal = pinOrdinal
        self.canonicalBytes = canonicalBytes
        self.revisionCount = revisionCount
        self.revisionBytes = revisionBytes
    }
}
