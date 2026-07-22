/// PlannersCapture.swift — the capture and retention pure planners plus the
/// Canonical containment relation. Owning spec: docs/02-domain.md §8 (planner
/// contracts), §9 (deduplication), §12 (retention and hard capacity), §14
/// (invariants D1–D19). Pure value planning only: no I/O, no clocks, no UUID,
/// Content Version, or Change Position minting (docs/02-domain.md §1, §4) —
/// the plan describes mutations declaratively and Storage stamps tokens.
import Foundation
import HistoryCore

/// Byte-exact Canonical containment: true when every incoming
/// `(typeIdentifier, bytes)` pair appears in `existing`.
/// docs/02-domain.md §9.2
///
/// `CanonicalRepresentation` equality and hashing use `content` only
/// (docs/02-domain.md §2.3), so fingerprint evidence never completes this
/// decision (D7). Containment is a partial order, not an equivalence: it
/// preserves "rich copy absorbs a later plain-only copy" while refusing
/// hash-only matches.
package func canonicalContains(
    existing: CanonicalContent,
    incoming: CanonicalContent
) -> Bool {
    let existingSet = Set(existing.representations)
    return incoming.representations.allSatisfy { existingSet.contains($0) }
}

/// Plans one capture: lineage-lane and canonical-lane dedup, insert-or-
/// coalesce, and same-commit retention victim selection.
/// docs/02-domain.md §8, §9, §12
///
/// Matching lanes (docs/02-domain.md §9.3), in fixed order:
///
/// 1. Lineage lane — a direct retained hint wins only when the incoming
///    content is byte-set-equal to the hinted item's current Effective
///    Content; containment is insufficient here so a spoofed hint cannot
///    discard representations. Effective Content derivation is defensive:
///    an internally inconsistent lineage fact throws `.corruptLineage`
///    (docs/02-domain.md §6).
/// 2. Canonical lane — every complete signature candidate is byte-confirmed
///    with `canonicalContains`; Effective Content and inactive revisions do
///    not participate. Multiple confirmed candidates resolve to the minimum
///    rank of docs/02-domain.md §9.4 (D9).
/// 3. Insert — only when both lanes confirm no winner (D8: candidacy
///    completeness was proven before planning).
///
/// A coalescing winner receives one `.recordCopy` carrying the complete
/// folded occurrence of docs/02-domain.md §3.1 (D11); count overflow throws
/// `.capacityExceeded(.copyCount)` (docs/02-domain.md §13). Retention runs on
/// the projected post-insert / post-coalesce inventory (D14): pinned items
/// are exempt (D13), the primary item is never its own victim, and eviction
/// follows `lastCopiedAt` ascending, then `HistoryItemID` bytes ascending.
/// Only the global hard retained-item bound can fail capture, throwing
/// `.capacityExceeded(.retainedItems)` when too few eligible victims remain
/// (D19).
package func planCapture(
    _ capture: PreparedCapture,
    facts: IngestFacts,
    retention: RetentionPolicy,
    hardMaximumRetainedItems: Int
) throws -> PlanningResult {
    // Lane 1 — lineage (docs/02-domain.md §9.3.1): byte-set equality with the
    // hinted item's current Effective Content.
    var winner: HistoryItemState?
    if let hinted = facts.hintedItem {
        let hintedEffective: EffectiveContent
        do {
            hintedEffective = try effectiveContent(of: hinted)
        } catch {
            // Storage validates lineage at fact load; this is only the
            // planner's defensive backstop (docs/02-domain.md §6).
            throw DomainRejection.corruptLineage
        }
        let incomingSet = Set(capture.canonical.representations.map { $0.content })
        if incomingSet == Set(hintedEffective.representations) {
            winner = hinted
        }
    }

    // Lane 2 — canonical (docs/02-domain.md §9.3.2): byte-confirm every
    // complete candidate, then pick the deterministic §9.4 winner.
    if winner == nil {
        winner = facts.candidates.items
            .filter { canonicalContains(existing: $0.canonical, incoming: capture.canonical) }
            .min { canonicalWinnerRanksBefore($0, $1, incoming: capture.canonical) }
    }

    // Primary mutation: coalesce (§9.5) or insert (§9.3.3).
    let primaryID: HistoryItemID
    let primaryMutation: HistoryMutation
    let outcome: PlannedOutcome
    let projectedRecency: (id: HistoryItemID, lastCopiedAt: Date)?
    if let winner {
        let existing = winner.occurrence
        let (foldedCount, overflow) = existing.count.addingReportingOverflow(1)
        guard !overflow else {
            // Checked occurrence arithmetic fails closed (docs/02-domain.md §13).
            throw DomainRejection.capacityExceeded(.copyCount)
        }
        let advancesRecency = capture.observedAt >= existing.lastCopiedAt
        let folded = CopyOccurrence(
            firstCopiedAt: existing.firstCopiedAt,
            lastCopiedAt: max(existing.lastCopiedAt, capture.observedAt),
            count: foldedCount,
            firstSource: existing.firstSource,
            lastSource: advancesRecency
                ? capture.origin.sourceApplication ?? existing.lastSource
                : existing.lastSource
        )
        primaryID = winner.id
        primaryMutation = .recordCopy(itemID: winner.id, occurrence: folded)
        outcome = .coalesced(winner.id)
        projectedRecency = (id: winner.id, lastCopiedAt: folded.lastCopiedAt)
    } else {
        // docs/02-domain.md §3.1: a new item initializes all first/last values
        // from the accepted capture and sets count = 1.
        let occurrence = CopyOccurrence(
            firstCopiedAt: capture.observedAt,
            lastCopiedAt: capture.observedAt,
            count: 1,
            firstSource: capture.origin.sourceApplication,
            lastSource: capture.origin.sourceApplication
        )
        primaryID = capture.candidateID
        primaryMutation = .create(NewHistoryItem(
            id: capture.candidateID,
            canonical: capture.canonical,
            occurrence: occurrence
        ))
        outcome = .inserted(capture.candidateID)
        projectedRecency = nil
    }

    // Retention on the projected post-mutation inventory (§12, D14): the
    // primary's recency effect is visible before victims are chosen.
    let isInsert = projectedRecency == nil
    let projected: [RetainedItemSummary]
    if let projectedRecency {
        projected = facts.retention.allItems.map { summary in
            guard summary.id == projectedRecency.id else { return summary }
            return RetainedItemSummary(
                id: summary.id,
                lastCopiedAt: projectedRecency.lastCopiedAt,
                pinOrdinal: summary.pinOrdinal
            )
        }
    } else {
        projected = facts.retention.allItems + [
            RetainedItemSummary(
                id: capture.candidateID,
                lastCopiedAt: capture.observedAt,
                pinOrdinal: nil
            )
        ]
    }

    let unpinned = projected.filter { $0.pinOrdinal == nil }
    // Pinned items are exempt (D13); the primary is never its own victim (§12).
    let eligible = evictionOrdered(unpinned.filter { $0.id != primaryID })
    let userPolicyVictims = max(0, unpinned.count - retention.maximumUnpinnedItems)
    // Only an insert can push the retained total past the hard bound; a
    // coalesce leaves the total unchanged.
    let hardBoundVictims = isInsert ? max(0, projected.count - hardMaximumRetainedItems) : 0
    let victimCount = max(userPolicyVictims, hardBoundVictims)
    guard victimCount <= eligible.count else {
        // D19: the user policy alone can always be satisfied; only the global
        // hard retained-item bound forces this failure (§12).
        throw DomainRejection.capacityExceeded(.retainedItems)
    }

    var mutations: [HistoryMutation] = [primaryMutation]
    for victim in eligible.prefix(victimCount) {
        mutations.append(.retire(itemID: victim.id, reason: .retention))
    }
    return .commit(MutationPlan(outcome: outcome, mutations: mutations))
}

/// Plans a user retention-policy update: the new value and every victim
/// required to satisfy it are one plan (docs/02-domain.md §7).
/// docs/02-domain.md §8, §12
///
/// Setting the already-persisted value while the retained state satisfies it
/// is `.unchanged`; otherwise the plan emits `.setRetentionPolicy` plus
/// `.retire` for each excess unpinned item in eviction order (pinned items
/// are exempt, D13). `removedCount` in the outcome equals the number of
/// `.retire` mutations in the same commit (D18).
package func planRetention(
    facts: RetentionFacts,
    policy: RetentionPolicy
) -> PlanningResult {
    let unpinned = facts.inventory.allItems.filter { $0.pinOrdinal == nil }
    let victims = evictionOrdered(unpinned)
        .prefix(max(0, unpinned.count - policy.maximumUnpinnedItems))

    if policy == facts.currentPolicy, victims.isEmpty {
        return .unchanged
    }

    var mutations: [HistoryMutation] = [
        .setRetentionPolicy(maximumUnpinnedItems: policy.maximumUnpinnedItems)
    ]
    for victim in victims {
        mutations.append(.retire(itemID: victim.id, reason: .retention))
    }
    return .commit(MutationPlan(
        outcome: .retentionPolicySet(removedCount: victims.count),
        mutations: mutations
    ))
}

/// The deterministic winner rank of docs/02-domain.md §9.4: returns true when
/// `lhs` ranks before `rhs` — exact Canonical equality first, then fewest
/// extra representations, then most recent `lastCopiedAt`, then smallest
/// `HistoryItemID` bytes (the stable final tie-breaker, D9).
private func canonicalWinnerRanksBefore(
    _ lhs: HistoryItemState,
    _ rhs: HistoryItemState,
    incoming: CanonicalContent
) -> Bool {
    let lhsExact = lhs.canonical == incoming
    let rhsExact = rhs.canonical == incoming
    if lhsExact != rhsExact { return lhsExact }

    // Containment was already confirmed, so each count is non-negative.
    let lhsExtra = lhs.canonical.representations.count - incoming.representations.count
    let rhsExtra = rhs.canonical.representations.count - incoming.representations.count
    if lhsExtra != rhsExtra { return lhsExtra < rhsExtra }

    if lhs.occurrence.lastCopiedAt != rhs.occurrence.lastCopiedAt {
        return lhs.occurrence.lastCopiedAt > rhs.occurrence.lastCopiedAt
    }

    return lhs.id < rhs.id
}

/// The eviction order of docs/02-domain.md §12: `lastCopiedAt` ascending,
/// then `HistoryItemID` bytes ascending. Fact completeness gives every
/// retained item exactly once, so unique IDs make this a total order and the
/// result independent of input ordering (D16).
private func evictionOrdered(
    _ summaries: [RetainedItemSummary]
) -> [RetainedItemSummary] {
    summaries.sorted { lhs, rhs in
        if lhs.lastCopiedAt != rhs.lastCopiedAt {
            return lhs.lastCopiedAt < rhs.lastCopiedAt
        }
        return lhs.id < rhs.id
    }
}
