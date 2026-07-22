/// Action-specific complete facts — values whose type identity proves
/// fact-loading completeness to a planner (docs/02-domain.md §5) — and the
/// package rejection vocabulary planners throw (docs/02-domain.md §6).
/// Immutable values only: no I/O, actor, clock, UUID generation, cache, or
/// async (docs/02-domain.md §1).
import Foundation
import HistoryCore

// MARK: - Ingest facts (docs/02-domain.md §5.1)

/// Complete Canonical-containment candidacy for one capture.
/// docs/02-domain.md §5.1
///
/// `items` contains every retained item whose Canonical signature can cover
/// every incoming signature entry; every candidate is loaded sufficiently to
/// perform byte-exact confirmation (D7, D8). Completeness is established by
/// `HistoryStorage` fact loading: failure is a Storage fact-loading failure
/// mapped to `.temporarilyUnavailable(.factProof)`, or
/// `.temporarilyUnavailable(.dedupIndexRebuild)` when the Signature Index
/// cannot be rebuilt to a proved-complete state, or a persistence-corruption
/// failure. There is no `.bounded` state; a planner never sees a partial
/// candidate set.
package struct CompleteDedupCandidates: Sendable {
    package let items: [HistoryItemState]

    package init(items: [HistoryItemState]) {
        self.items = items
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

/// The complete retained-set inventory.
/// docs/02-domain.md §5.1
///
/// `allItems` contains every retained item exactly once. Anything less is a
/// Storage fact-loading failure raised before planning, never a partial fact.
package struct CompleteRetentionInventory: Sendable {
    package let allItems: [RetainedItemSummary]

    package init(allItems: [RetainedItemSummary]) {
        self.allItems = allItems
    }
}

/// The complete facts capture planning requires.
/// docs/02-domain.md §5.1
///
/// `hintedItem` is fetched directly by business ID when a hint exists; it is
/// independent of signature candidacy. A fact loader either constructs this
/// complete value or fails the History Action before planning — the Domain
/// planner is never invoked with a partial fact.
package struct IngestFacts: Sendable {
    package let hintedItem: HistoryItemState?
    package let candidates: CompleteDedupCandidates
    package let retention: CompleteRetentionInventory

    package init(
        hintedItem: HistoryItemState?,
        candidates: CompleteDedupCandidates,
        retention: CompleteRetentionInventory
    ) {
        self.hintedItem = hintedItem
        self.candidates = candidates
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

/// The complete lineage of the revision target.
/// docs/02-domain.md §5.3
///
/// The fact loader returns the complete target lineage or fails with
/// `notFound`; it does not synthesize a missing active revision.
package struct RevisionFacts: Sendable {
    package let item: HistoryItemState

    package init(item: HistoryItemState) {
        self.item = item
    }
}

// MARK: - Clear and remove facts (docs/02-domain.md §5.4)

/// The complete facts removal planning requires.
/// docs/02-domain.md §5.4
///
/// A nil `item` means the target is absent from the retained set; planning
/// rejects it with `.notFound`.
package struct RemoveFacts: Sendable {
    package let item: RetainedItemSummary?

    package init(item: RetainedItemSummary?) {
        self.item = item
    }
}

/// The complete facts clear planning requires.
/// docs/02-domain.md §5.4
///
/// `affected` is the complete set selected by the requested scope at the
/// Authority linearization point. There is no partial clear.
package struct ClearFacts: Sendable {
    package let affected: [RetainedItemSummary]

    package init(affected: [RetainedItemSummary]) {
        self.affected = affected
    }
}

// MARK: - Retention facts (docs/02-domain.md §5.5)

/// The complete facts retention planning requires.
/// docs/02-domain.md §5.5
package struct RetentionFacts: Sendable {
    package let inventory: CompleteRetentionInventory
    package let currentPolicy: RetentionPolicy

    package init(inventory: CompleteRetentionInventory, currentPolicy: RetentionPolicy) {
        self.inventory = inventory
        self.currentPolicy = currentPolicy
    }
}

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
/// exhaustively to the public `HistoryFailure` cases at the boundary
/// (`corruptLineage` maps to `.persistence(.invariantViolation)`).
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
    /// The referenced Revision does not exist on the target item.
    /// docs/02-domain.md §6
    case revisionNotFound(RevisionID)
    /// A validated fact proved internally inconsistent (e.g. an active
    /// revision ID naming no stored revision). Defensive backstop only.
    /// docs/02-domain.md §6, §11 step 3
    case corruptLineage
    /// A configured capacity dimension rejected the action.
    /// docs/02-domain.md §6, §12
    case capacityExceeded(CapacityKind)
}
