/// Retained item state: copy origin and occurrence, pin ordinal, and the fully
/// hydrated history item value.
/// Owning spec: docs/02-domain.md §3. Immutable pure values — no I/O, actors,
/// clocks, UUID generation, or version minting (docs/02-domain.md §1, §4).
import Foundation
import HistoryCore

/// Observed origin of one accepted capture.
/// docs/02-domain.md §3.1
///
/// `sourceApplication` and `lineageHint` are observations, not authenticated
/// provenance. A lineage hint never bypasses byte comparison (§3.1, §9.3).
package struct CopyOrigin: Sendable, Hashable {
    package let lineageHint: HistoryItemID?
    package let sourceApplication: String?

    package init(lineageHint: HistoryItemID?, sourceApplication: String?) {
        self.lineageHint = lineageHint
        self.sourceApplication = sourceApplication
    }
}

/// Folded copy-occurrence record of one retained item.
/// docs/02-domain.md §3.1
///
/// A new item initializes all first/last values from the accepted capture and
/// sets `count = 1`. Copy Coalescing produces a complete replacement value:
/// it keeps `firstCopiedAt`/`firstSource`, moves `lastCopiedAt` to
/// `max(existing.lastCopiedAt, incoming.observedAt)`, increments `count` with
/// checked arithmetic (overflow rejects the operation — it never wraps or
/// saturates), and updates `lastSource` only when the incoming observation is
/// not older than the stored recency. Out-of-order capture must not move
/// recency or its associated source observation backwards (D11).
package struct CopyOccurrence: Sendable, Hashable {
    package let firstCopiedAt: Date
    package let lastCopiedAt: Date
    package let count: UInt64
    package let firstSource: String?
    package let lastSource: String?

    package init(
        firstCopiedAt: Date,
        lastCopiedAt: Date,
        count: UInt64,
        firstSource: String?,
        lastSource: String?
    ) {
        self.firstCopiedAt = firstCopiedAt
        self.lastCopiedAt = lastCopiedAt
        self.count = count
        self.firstSource = firstSource
        self.lastSource = lastSource
    }
}

/// Persistence encoding of one item's position in the pinned order.
/// docs/02-domain.md §3.2
///
/// `<` orders by `rawValue`; Swift does not synthesize `Comparable` here.
/// `rawValue` is non-negative: planners only ever mint `0 ..< p` for `p`
/// pinned items, each used exactly once (D12). A negative stored value is
/// persistence corruption (Part V §7.2), detected at the Storage boundary —
/// this value type does not re-validate it. An item stores `PinOrdinal?`;
/// `nil` means unpinned. The semantic pin state is the ordered list of pinned
/// History Item IDs; ordinals are only its persistence encoding.
package struct PinOrdinal: Sendable, Hashable, Comparable {
    package let rawValue: Int

    package init(rawValue: Int) {
        self.rawValue = rawValue
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Fully hydrated state of one retained history item.
/// docs/02-domain.md §3.3
///
/// Used only when an operation requires content lineage; list and search
/// reads do not expose or hydrate it. Removal is absence from the retained
/// set — there is no tombstone flag, and a removed ID is never resurrected or
/// reassigned (D15).
package struct HistoryItemState: Sendable, Hashable {
    package let id: HistoryItemID
    package let contentVersion: ContentVersion
    package let canonical: CanonicalContent
    package let revisions: [ContentRevision]
    package let activeRevisionID: RevisionID?
    package let occurrence: CopyOccurrence
    package let pinOrdinal: PinOrdinal?

    package init(
        id: HistoryItemID,
        contentVersion: ContentVersion,
        canonical: CanonicalContent,
        revisions: [ContentRevision],
        activeRevisionID: RevisionID?,
        occurrence: CopyOccurrence,
        pinOrdinal: PinOrdinal?
    ) {
        self.id = id
        self.contentVersion = contentVersion
        self.canonical = canonical
        self.revisions = revisions
        self.activeRevisionID = activeRevisionID
        self.occurrence = occurrence
        self.pinOrdinal = pinOrdinal
    }
}
