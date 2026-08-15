/// RetentionExpansionFacts.swift — the V2-02 expansion fact types: the
/// per-item byte/revision summaries R2/R3 require, extending v1's
/// `CompleteRetentionInventory` (`02` §5.5). Owning spec: docs/v2/
/// V2-02-retention.md §3.2 (declaration shape and construction guarantees);
/// roadmap slice: docs/v2/V2-roadmap.md §6 R.2 "Pure Domain". The planners
/// take the public `HistoryRetentionPolicies` directly (§3.2 first paragraph
/// — v1 planners likewise take public types such as `HistoryItemID`,
/// `02` §8), so no Domain-side policy mirror exists. Immutable values only:
/// no I/O, actor, clock, UUID generation, cache, or async (`02` §1).
import Foundation
import HistoryCore

// MARK: - Expansion facts (docs/v2/V2-02-retention.md §3.2)

/// Retention-relevant byte/revision projection of one retained item.
/// docs/v2/V2-02-retention.md §3.2
///
/// Extends v1's `RetainedItemSummary` (`02` §5.5) with the scalar byte and
/// revision summaries R2/R3 select over. On the planning path every scalar is
/// read from the Storage-side `RetainedBytesRow` projection (`V2-02` §3.3b),
/// stamped in the same `ModelContext.transaction` as the blob it summarizes
/// (`05` §15) — the planner decodes no `SignatureBlobV1` envelope and no
/// `revisionStateBlob` per plan (`RET-PLATFORM-2`):
/// - `canonicalBytes` is a signature-envelope byte count: the sum of
///   `StoredSignatureEntryV1.byteCount` over `SignatureBlobV1.entries`
///   (`05` §4) — never a materialization of the pasteboard bytes themselves;
/// - `revisionBytes` is revision content bytes (the sum of stored-revision
///   representation bytes), commensurate with `canonicalBytes` and with the
///   v1 per-item-revision-byte hard-bound measure (`V2-02` §5.4);
/// - `revisionCount` is the count of stored revisions.
///
/// The insert lane is the one exception (`V2-02` §3.2): a freshly inserted
/// primary has no `RetainedBytesRow` yet, so its scalars are taken in memory
/// from the capture blob being written (`revisionCount == 0` and
/// `revisionBytes == 0` — a new item carries an empty revision list,
/// `02` §2.5 rule 3 / `05` §3.1). The coalesce lane never substitutes the
/// incoming capture blob for the winner's stored scalars: coalesce preserves
/// the winner's Canonical Content and revision state (`02` §9.5), so the
/// winner's existing `RetainedBytesRow` is already correct.
package struct RetentionExpansionItemSummary: Sendable, Hashable {
    package let id: HistoryItemID
    /// R1 reads this (`V2-02` §4.2); already in v1 `RetainedItemSummary`.
    package let lastCopiedAt: Date
    package let pinOrdinal: PinOrdinal?
    /// R2: Canonical content bytes (`V2-02` §3.2; sourced from the
    /// `RetainedBytesRow` scalar projection, §3.3b).
    package let canonicalBytes: Int
    /// R3: count of stored revisions; sourced from `RetainedBytesRow`.
    package let revisionCount: Int
    /// R3: revision content bytes (sum of stored-revision representation
    /// bytes); sourced from `RetainedBytesRow`; commensurate with the v1
    /// 256 MiB hard-bound measure (`V2-02` §5.4).
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

/// The complete retained-set expansion inventory.
/// docs/v2/V2-02-retention.md §3.2
///
/// `items` contains every retained item exactly once, projected to the state
/// the enclosing commit will leave (D14: latest-state retention): for capture
/// this is post-insert/post-coalesce and post-count-retirement (the v1 count
/// plan's victims are excluded — the expansion pass never re-runs v1 victim
/// selection, `V2-02` §4.1); for `.setRetentionPolicies` it is the current
/// retained set projected to the post-R3-prune state (`V2-02` §3.2/§4.4 —
/// R2 never credits soon-to-be-pruned revision bytes, `RET-PRUNE-2`).
/// Anything less is a Storage fact-loading failure raised before planning,
/// never a partial fact (D8; `05` §16).
package struct CompleteRetentionExpansionInventory: Sendable {
    package let items: [RetentionExpansionItemSummary]

    package init(items: [RetentionExpansionItemSummary]) {
        self.items = items
    }
}

/// The complete facts V2-02 expansion planning requires.
/// docs/v2/V2-02-retention.md §3.2
///
/// `currentPolicies` are the persisted V2 policies (what the store currently
/// enforces); the NEW policies a `.setRetentionPolicies` commit will enforce
/// arrive as the planner's `policies` argument (`V2-02` §6.5), so the pair
/// distinguishes "value changes" from "state already satisfies it" — the
/// same-value already-satisfied case is `.unchanged` at the Storage
/// composition boundary (`V2-02` §4.4/§5.6), not a planner concern. A fact
/// loader either constructs this complete value or fails the History Action
/// before planning (D8); the planner is never invoked with a partial fact.
package struct RetentionExpansionFacts: Sendable {
    package let inventory: CompleteRetentionExpansionInventory
    /// Persisted V2 policies (`RetentionExpansionConfigRow`, §3.3).
    package let currentPolicies: HistoryRetentionPolicies

    package init(
        inventory: CompleteRetentionExpansionInventory,
        currentPolicies: HistoryRetentionPolicies
    ) {
        self.inventory = inventory
        self.currentPolicies = currentPolicies
    }
}
