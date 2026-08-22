/// Receipts and History Commit outcomes — the caller-visible result of every
/// mutating History Action.
/// Owning spec: docs/03a-instruction-set.md §6. Foundation-only.
import Foundation

/// Result of a mutating History Action.
/// docs/03a-instruction-set.md §6.
///
/// `unchanged` means there was no durable mutation: it has no position,
/// publishes no invalidation, and is not a History Commit.
public enum HistoryReceipt: Sendable {
    case unchanged
    case committed(HistoryCommit)
}

/// A durable mutation receipt: the coherence position of the commit plus its
/// outcome. Only `committed` receipts carry one.
/// docs/03a-instruction-set.md §6.
public struct HistoryCommit: Sendable {
    public let position: ChangePosition
    public let outcome: HistoryCommitOutcome
    /// True only when the committed plan also retired an item or pruned an
    /// immutable revision for retention. Package callers use this receipt
    /// fact to discard derived presentation state without exposing storage's
    /// victim vocabulary at the public History boundary.
    package let hasDestructiveRetentionEffects: Bool

    public init(
        position: ChangePosition,
        outcome: HistoryCommitOutcome
    ) {
        self.position = position
        self.outcome = outcome
        self.hasDestructiveRetentionEffects = false
    }

    package init(
        position: ChangePosition,
        outcome: HistoryCommitOutcome,
        hasDestructiveRetentionEffects: Bool
    ) {
        self.position = position
        self.outcome = outcome
        self.hasDestructiveRetentionEffects = hasDestructiveRetentionEffects
    }
}

/// The kind of durable mutation a History Commit recorded.
/// docs/03a-instruction-set.md §6.
///
/// A committed capture returns the stable winner/new item reference.
/// Metadata-only outcomes (`placedPinned`, `unpinned`, `retentionPolicySet`,
/// `retentionPoliciesSet`) keep the existing Content Version, so the outcome
/// does not pretend to mint a new reference state.
public enum HistoryCommitOutcome: Sendable {
    case inserted(HistoryItemReference)
    case coalesced(HistoryItemReference)
    case placedPinned(HistoryItemID)
    case unpinned(HistoryItemID)
    case removed(count: Int)
    case cleared(count: Int)
    case revised(HistoryItemReference)
    /// v1 count-policy commit (unchanged — `03a` §6; `V2-02` §8.1).
    case retentionPolicySet(removedCount: Int)
    /// The `.setRetentionPolicies` commit (V2-02 new case, §8.1 —
    /// extension-by-addition per `V2-00` §8(h)): `retiredItems` counts R1/R2
    /// item retirements; `prunedRevisions` counts R3 revisions pruned for
    /// surviving (non-retired) items. The two are reported separately so a
    /// caller can distinguish item retirement from revision pruning.
    case retentionPoliciesSet(retiredItems: Int, prunedRevisions: Int)
}
