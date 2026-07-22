/// Strong semantic mutation plan — the Domain's declarative output for one
/// accepted action: one ordered list of mutations plus a package outcome
/// vocabulary. Owning spec: docs/02-domain.md §7. Foundation + HistoryCore
/// only; pure values, no version/position minting (docs/02-domain.md §1, §4).
import Foundation
import HistoryCore

/// One semantic change in a plan; each case carries the complete payload for
/// that kind of change.
/// docs/02-domain.md §7
///
/// Case payload rules (plan invariants 2–9, see `MutationPlan`):
/// - `create`: the ID does not already exist in the facts (invariant 2).
/// - `recordCopy`: carries the final folded occurrence; Storage does not
///   reconstruct it (invariant 3).
/// - `assignPin`: `nil` ordinal means unpinned (docs/02-domain.md §3); the
///   final set of `assignPin` mutations plus unchanged pinned items produces
///   exactly one contiguous order (invariant 4).
/// - `appendRevision`: carries the complete immutable revision and the final
///   active ID (invariant 5); always changes Effective Content — same-content
///   requests returned `.unchanged` earlier (invariant 6).
/// - `retire`: a retired item is not also the primary created/coalesced/
///   revised result of the same plan (invariant 7); retention never retires a
///   pinned item (invariant 8).
/// - No case redirects, merges, or reuses History Item IDs (invariant 9).
package enum HistoryMutation: Sendable {
    case create(NewHistoryItem)
    case recordCopy(itemID: HistoryItemID, occurrence: CopyOccurrence)
    case assignPin(itemID: HistoryItemID, ordinal: PinOrdinal?)
    case appendRevision(
        itemID: HistoryItemID,
        revision: ContentRevision,
        activeRevisionID: RevisionID
    )
    case retire(itemID: HistoryItemID, reason: RetirementReason)
    case setRetentionPolicy(maximumUnpinnedItems: Int)
}

/// Payload of `HistoryMutation.create`: a new item's identity, canonical
/// content, and first occurrence.
/// docs/02-domain.md §7
package struct NewHistoryItem: Sendable {
    package let id: HistoryItemID
    package let canonical: CanonicalContent
    package let occurrence: CopyOccurrence
}

/// Why an item leaves the retained history.
/// docs/02-domain.md §7
package enum RetirementReason: Sendable {
    case userRemoval
    case clear
    case retention
}

/// The Domain's ordered plan for one accepted action.
/// docs/02-domain.md §7
///
/// Plan invariants (docs/02-domain.md §7):
/// 1. `mutations` is non-empty.
/// 2. A create ID does not already exist in the facts.
/// 3. `recordCopy` carries the final folded occurrence; Storage does not
///    reconstruct it.
/// 4. The final set of `assignPin` mutations plus unchanged pinned items
///    produces exactly one contiguous order.
/// 5. `appendRevision` carries the complete immutable revision and final
///    active ID.
/// 6. The revision case always changes Effective Content; same-content
///    requests returned `.unchanged` earlier.
/// 7. A retired item is not also the primary created/coalesced/revised
///    result of the same plan.
/// 8. Retention never retires a pinned item.
/// 9. No plan redirects, merges, or reuses History Item IDs.
/// 10. Version and projection values are intentionally absent. Part V stamps
///     them mechanically from the mutation case and derived Effective
///     Content, producing a storage-internal `StampedCommitPlan` before
///     transaction execution.
///
/// A retention-policy update and all victims needed to satisfy it are one
/// plan. Unlike the deleted parallel-map design, there is no independent
/// change-kind array that can disagree with its payload and no
/// Authority-only hidden occurrence fold.
package struct MutationPlan: Sendable {
    package let outcome: PlannedOutcome
    /// Non-empty by invariant 1.
    package let mutations: [HistoryMutation]
}

/// Package outcome vocabulary, mapped mechanically to the public receipt
/// outcome in Part III.
/// docs/02-domain.md §7
package enum PlannedOutcome: Sendable {
    case inserted(HistoryItemID)
    case coalesced(HistoryItemID)
    case placedPinned(HistoryItemID)
    case unpinned(HistoryItemID)
    case removed(count: Int)
    case cleared(count: Int)
    case revised(HistoryItemID)
    case retentionPolicySet(removedCount: Int)
}

/// The planner verdict for one action: either nothing changes, or one
/// ordered plan commits.
/// docs/02-domain.md §7
package enum PlanningResult: Sendable {
    case unchanged
    case commit(MutationPlan)
}
