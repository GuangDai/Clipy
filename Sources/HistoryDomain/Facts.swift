/// Action-specific complete facts — values whose type identity proves
/// fact-loading completeness to a planner (docs/02-domain.md §5) — and the
/// package rejection vocabulary planners throw (docs/02-domain.md §6).
/// Immutable values only: no I/O, actor, clock, UUID generation, cache, or
/// async (docs/02-domain.md §1).
import Foundation
import HistoryCore

// MARK: - Ingest facts (docs/02-domain.md §5.1)

/// Byte-confirmed capture winner facts (02 §9). Content is consumed during
/// confirmation; coalescing needs only identity, occurrence, and pin state.
package struct CaptureMatch: Sendable {
    package let id: HistoryItemID
    package let occurrence: CopyOccurrence
    package let pinOrdinal: PinOrdinal?

    package init(id: HistoryItemID, occurrence: CopyOccurrence, pinOrdinal: PinOrdinal?) {
        self.id = id
        self.occurrence = occurrence
        self.pinOrdinal = pinOrdinal
    }
}

/// Canonical confirmation retains only the rank needed for a streaming
/// winner reduction (02 §9.4). Zero extras denotes exact set equality.
package struct CanonicalCaptureMatch: Sendable {
    package let value: CaptureMatch
    package let extraRepresentationCount: Int

    package init(value: CaptureMatch, extraRepresentationCount: Int) {
        self.value = value
        self.extraRepresentationCount = extraRepresentationCount
    }
}

/// Retention-relevant projection of one retained item.
/// docs/02-domain.md §5.1
package struct RetainedItemSummary: Sendable, Hashable {
    package let id: HistoryItemID
    package let lastCopiedAt: Date
    package let pinOrdinal: PinOrdinal?

    package init(id: HistoryItemID, lastCopiedAt: Date, pinOrdinal: PinOrdinal?) {
        self.id = id
        self.lastCopiedAt = lastCopiedAt
        self.pinOrdinal = pinOrdinal
    }
}

/// Capture needs exact counts and the selected eviction boundary, not one
/// retained value per victim. Storage selects the prefix after confirmation,
/// excluding the primary item from the ordered unpinned lane (02 §12).
package struct CaptureRetentionFacts: Sendable {
    package let retainedCount: Int
    package let unpinnedCount: Int
    package let retirementPrefix: RetentionRetirementPrefix?

    package init(
        retainedCount: Int,
        unpinnedCount: Int,
        retirementPrefix: RetentionRetirementPrefix?
    ) {
        self.retainedCount = retainedCount
        self.unpinnedCount = unpinnedCount
        self.retirementPrefix = retirementPrefix
    }
}

/// The complete facts capture planning requires.
/// docs/02-domain.md §5.1
///
/// Storage confirms a direct lineage hint first, then reduces every Canonical
/// signature candidate with the pure confirmation helpers. A nil match means
/// both lanes completed without a winner; any loading failure aborts before
/// planning. Candidate content never accumulates in this fact (02 §9, D7–D9).
package struct IngestFacts: Sendable {
    package let confirmedMatch: CaptureMatch?
    package let candidateIDExists: Bool
    package let retention: CaptureRetentionFacts

    package init(
        confirmedMatch: CaptureMatch?,
        candidateIDExists: Bool,
        retention: CaptureRetentionFacts
    ) {
        self.confirmedMatch = confirmedMatch
        self.candidateIDExists = candidateIDExists
        self.retention = retention
    }
}

// MARK: - Pinned-order facts (docs/02-domain.md §5.2)

/// The complete ordered list of pinned History Item IDs.
/// docs/02-domain.md §5.2
///
/// Construction (in `HistoryStorage`) validates that every pinned retained
/// row appears exactly once and that ordinals are unique and contiguous
/// (D12). A malformed stored order is a persistence invariant failure; the
/// planner does not guess a repair.
package struct CompletePinnedOrder: Sendable {
    package let itemIDs: [HistoryItemID]

    package init(itemIDs: [HistoryItemID]) {
        self.itemIDs = itemIDs
    }
}

/// The complete facts pin placement and unpin planning require.
/// docs/02-domain.md §5.2
package struct PinFacts: Sendable {
    package let targetExists: Bool
    package let order: CompletePinnedOrder

    package init(targetExists: Bool, order: CompletePinnedOrder) {
        self.targetExists = targetExists
        self.order = order
    }
}

// MARK: - Revision facts (docs/02-domain.md §5.3)

/// Content and revision metadata needed to plan against the revision target.
/// docs/02-domain.md §5.3
///
/// Storage derives and validates `current` from the active lineage before
/// constructing these facts. Older revision bytes are unnecessary for draft
/// validation, duplicate-ID rejection, and revision-retention planning.
package struct RevisionFacts: Sendable {
    package let itemID: HistoryItemID
    package let contentVersion: ContentVersion
    package let canonical: CanonicalContent
    package let current: EffectiveContent
    package let revisions: [RevisionRetentionSummary]
    package let activeRevisionID: RevisionID?

    package init(
        itemID: HistoryItemID,
        contentVersion: ContentVersion,
        canonical: CanonicalContent,
        current: EffectiveContent,
        revisions: [RevisionRetentionSummary],
        activeRevisionID: RevisionID?
    ) {
        self.itemID = itemID
        self.contentVersion = contentVersion
        self.canonical = canonical
        self.current = current
        self.revisions = revisions
        self.activeRevisionID = activeRevisionID
    }
}

// MARK: - Clear and remove facts (docs/02-domain.md §5.4)

/// The complete facts removal planning requires.
/// docs/02-domain.md §5.4
///
/// A nil `item` means the target is absent from the retained set; planning
/// rejects it with `.notFound`. `pinnedOrder` is the same proven value pin
/// planning loads (§5.2): removing a pinned item must compact the pinned lane
/// in the same commit (§10, D12 — AUDIT IMP6-01), which a target-only fact
/// cannot plan.
package struct RemoveFacts: Sendable {
    package let item: RetainedItemSummary?
    package let pinnedOrder: CompletePinnedOrder

    package init(item: RetainedItemSummary?, pinnedOrder: CompletePinnedOrder) {
        self.item = item
        self.pinnedOrder = pinnedOrder
    }
}

/// The complete facts clear planning requires.
/// docs/02-domain.md §5.4
///
/// `affectedCount` counts the complete scope at the Authority linearization
/// point. Scope deletion needs no retained IDs or per-item facts.
package struct ClearFacts: Sendable {
    package let affectedCount: Int

    package init(affectedCount: Int) {
        self.affectedCount = affectedCount
    }
}

// MARK: - Retention facts (docs/02-domain.md §5.5)

/// The single v1 user retention dimension: maximum unpinned item count.
/// docs/02-domain.md §5.5
///
/// `maximumUnpinnedItems` is at least 1 and no greater than the configured
/// hard retained-item bound (the Part VI user range is 1–5,000). 0 is
/// rejected at the `HistoryStorage` boundary (typed `invalidInput`), so
/// planning always receives a policy that permits at least one unpinned item
/// (D19). Pinned items are exempt from the user policy, but not from the
/// global hard safety bound.
package struct RetentionPolicy: Sendable, Hashable {
    package let maximumUnpinnedItems: Int

    package init(maximumUnpinnedItems: Int) {
        self.maximumUnpinnedItems = maximumUnpinnedItems
    }
}

// MARK: - Domain rejection vocabulary (docs/02-domain.md §6)

/// The complete rejection vocabulary thrown by Domain planners.
/// docs/02-domain.md §6
///
/// Planners throw only this package vocabulary; `HistoryStorage` maps it
/// exhaustively at the boundary. `candidateItemIDCollision` is intercepted
/// as an internal remint signal, while `corruptLineage` maps to public
/// `.persistence(.invariantViolation)`.
/// Persistence corruption and fact-proof availability are normally caught at
/// the Storage fact-loading boundary before planning; `corruptLineage` is
/// only the planner's defensive backstop when a validated fact is internally
/// inconsistent (e.g. an active revision ID naming no stored revision). A
/// planner is never invoked with a known-incomplete fact.
package enum DomainRejection: Error, Sendable, Equatable {
    /// The referenced item is absent from the retained set.
    /// docs/02-domain.md §6
    case notFound(HistoryItemID)
    /// The request's expected Content Version no longer matches the item's
    /// durable one. docs/02-domain.md §6, §11 step 1
    case staleContent(
        expected: ContentVersion,
        current: ContentVersion
    )
    /// A pin placement request referenced an invalid target/anchor pair.
    /// docs/02-domain.md §6, §10
    case invalidPinnedPlacement(PinnedPlacementFailure)
    /// The prepared revision failed Domain-level revalidation.
    /// docs/02-domain.md §6, §11 steps 2 and 4
    case invalidRevisionDraft
    /// Capture selected the insert lane, but Storage's candidate History Item
    /// ID already names a retained item. The pure planner rejects; Storage
    /// owns remint/retry (Card 2B-1/2B-2).
    case candidateItemIDCollision(HistoryItemID)
    /// A validated fact proved internally inconsistent (e.g. an active
    /// revision ID naming no stored revision). Defensive backstop only.
    /// docs/02-domain.md §6, §11 step 3
    case corruptLineage
    /// A configured capacity dimension rejected the action.
    /// docs/02-domain.md §6, §12
    case capacityExceeded(CapacityKind)
}
