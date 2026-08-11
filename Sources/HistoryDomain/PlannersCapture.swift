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
    // complete candidate, cache the §9.4 facts established while doing so,
    // then pick the deterministic winner. Canonical byte equality is paid
    // once per candidate rather than once for each `min` comparison.
    if winner == nil {
        winner = facts.candidates.items.lazy
            .compactMap { item -> ConfirmedCanonicalCandidate? in
                let isExactCanonicalMatch = item.canonical == capture.canonical
                guard isExactCanonicalMatch || canonicalContains(
                    existing: item.canonical,
                    incoming: capture.canonical
                ) else {
                    return nil
                }
                return ConfirmedCanonicalCandidate(
                    item: item,
                    isExactCanonicalMatch: isExactCanonicalMatch,
                    extraRepresentationCount: item.canonical.representations.count
                        - capture.canonical.representations.count
                )
            }
            .min(by: canonicalWinnerRanksBefore)?.item
    }

    // Primary mutation: coalesce (§9.5) or insert (§9.3.3).
    let primaryID: HistoryItemID
    let primaryMutation: HistoryMutation
    let outcome: PlannedOutcome
    let isInsert: Bool
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
        isInsert = false
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
        isInsert = true
    }

    // Derive the projected counts before allocating or sorting an eviction
    // inventory. An insert adds one unpinned row; a coalesce changes only the
    // primary's recency, and the primary is ineligible as its own victim, so
    // that recency never affects the ordering of eligible rows (§12, D14).
    let retainedCount = facts.retention.allItems.count + (isInsert ? 1 : 0)
    let unpinnedCount = facts.retention.allItems.lazy
        .filter { $0.pinOrdinal == nil }
        .count + (isInsert ? 1 : 0)
    let userPolicyVictims = max(
        0,
        unpinnedCount - retention.maximumUnpinnedItems
    )
    // Only an insert can push the retained total past the hard bound; a
    // coalesce leaves the total unchanged.
    let hardBoundVictims = isInsert
        ? max(0, retainedCount - hardMaximumRetainedItems)
        : 0
    let victimCount = max(userPolicyVictims, hardBoundVictims)

    var mutations: [HistoryMutation] = [primaryMutation]
    guard victimCount > 0 else {
        return .commit(MutationPlan(outcome: outcome, mutations: mutations))
    }

    // Pinned items are exempt (D13); the primary is never its own victim
    // (§12). Establishing this order is paid only when a victim can exist.
    let eligible = evictionOrdered(facts.retention.allItems.filter {
        $0.pinOrdinal == nil && $0.id != primaryID
    })
    guard victimCount <= eligible.count else {
        // D19: the user policy alone can always be satisfied; only the global
        // hard retained-item bound forces this failure (§12).
        throw DomainRejection.capacityExceeded(.retainedItems)
    }

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

    // The unchanged case depends only on the persisted policy and unpinned
    // count. Return before establishing an eviction order when no victim can
    // exist; ordering remains necessary for every over-limit plan (§12, D16).
    if policy == facts.currentPolicy,
       unpinned.count <= policy.maximumUnpinnedItems {
        return .unchanged
    }

    let victims = evictionOrdered(unpinned)
        .prefix(max(0, unpinned.count - policy.maximumUnpinnedItems))

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

/// One byte-confirmed lane-2 candidate plus the rank facts computed during
/// confirmation. Keeping these facts beside the item prevents the minimum
/// reduction from repeatedly walking Canonical bytes (docs/02-domain.md §9.4).
private struct ConfirmedCanonicalCandidate {
    let item: HistoryItemState
    let isExactCanonicalMatch: Bool
    let extraRepresentationCount: Int
}

/// The deterministic winner rank of docs/02-domain.md §9.4: returns true when
/// `lhs` ranks before `rhs` — exact Canonical equality first, then fewest
/// extra representations, then most recent `lastCopiedAt`, then smallest
/// `HistoryItemID` bytes (the stable final tie-breaker, D9).
private func canonicalWinnerRanksBefore(
    _ lhs: ConfirmedCanonicalCandidate,
    _ rhs: ConfirmedCanonicalCandidate
) -> Bool {
    if lhs.isExactCanonicalMatch != rhs.isExactCanonicalMatch {
        return lhs.isExactCanonicalMatch
    }
    if lhs.extraRepresentationCount != rhs.extraRepresentationCount {
        return lhs.extraRepresentationCount < rhs.extraRepresentationCount
    }

    if lhs.item.occurrence.lastCopiedAt != rhs.item.occurrence.lastCopiedAt {
        return lhs.item.occurrence.lastCopiedAt > rhs.item.occurrence.lastCopiedAt
    }

    return lhs.item.id < rhs.item.id
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
