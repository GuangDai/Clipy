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

    public init(
        position: ChangePosition,
        outcome: HistoryCommitOutcome
    ) {
        self.position = position
        self.outcome = outcome
    }
}

/// The kind of durable mutation a History Commit recorded.
/// docs/03a-instruction-set.md §6.
///
/// A committed capture returns the stable winner/new item reference.
/// Metadata-only outcomes (`placedPinned`, `unpinned`, `retentionPolicySet`)
/// keep the existing Content Version, so the outcome does not pretend to mint
/// a new reference state.
public enum HistoryCommitOutcome: Sendable {
    case inserted(HistoryItemReference)
    case coalesced(HistoryItemReference)
    case placedPinned(HistoryItemID)
    case unpinned(HistoryItemID)
    case removed(count: Int)
    case cleared(count: Int)
    case revised(HistoryItemReference)
    case retentionPolicySet(removedCount: Int)
}
