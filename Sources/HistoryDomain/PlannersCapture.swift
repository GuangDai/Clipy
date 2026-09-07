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
    // Index only by the bounded type identifier (A <= 32, Part VI §2), then
    // byte-confirm the matching value. A Set<CanonicalRepresentation> would
    // also be correct, but it unnecessarily uses the potentially large
    // clipboard bytes as part of every hash key. String equality preserves
    // the required Unicode canonical-equivalence semantics; a merge walk over
    // the stored scalar order would not, because canonically equivalent
    // spellings can occupy different positions relative to other strings.
    var existingBytesByType: [String: Data] = [:]
    existingBytesByType.reserveCapacity(existing.representations.count)
    for representation in existing.representations {
        existingBytesByType[representation.content.typeIdentifier] =
            representation.content.bytes
    }
    return incoming.representations.allSatisfy { representation in
        existingBytesByType[representation.content.typeIdentifier]
            == representation.content.bytes
    }
}

/// Confirms one Canonical signature candidate by content bytes (02 §9.2).
/// Fingerprints never establish identity. Equal arrays use the common fast
/// path; containment also handles equivalent Unicode type spellings whose
/// scalar order differs. Equal cardinality then establishes exact set equality.
package func confirmCanonicalCapture(
    incoming: CanonicalContent,
    existing: CanonicalContent,
    id: HistoryItemID,
    occurrence: CopyOccurrence,
    pinOrdinal: PinOrdinal?
) -> CanonicalCaptureMatch? {
    guard existing == incoming || canonicalContains(existing: existing, incoming: incoming) else {
        return nil
    }
    return CanonicalCaptureMatch(
        value: CaptureMatch(id: id, occurrence: occurrence, pinOrdinal: pinOrdinal),
        extraRepresentationCount: existing.representations.count - incoming.representations.count
    )
}

/// Reduces confirmed candidates without retaining their content (02 §9.4):
/// exact equality, fewest extras, newest copy, then smallest business ID.
package func preferredCanonicalCaptureMatch(
    _ lhs: CanonicalCaptureMatch,
    _ rhs: CanonicalCaptureMatch
) -> CanonicalCaptureMatch {
    if lhs.extraRepresentationCount != rhs.extraRepresentationCount {
        return lhs.extraRepresentationCount < rhs.extraRepresentationCount ? lhs : rhs
    }
    if lhs.value.occurrence.lastCopiedAt != rhs.value.occurrence.lastCopiedAt {
        return lhs.value.occurrence.lastCopiedAt > rhs.value.occurrence.lastCopiedAt ? lhs : rhs
    }
    return lhs.value.id < rhs.value.id ? lhs : rhs
}

/// A retained lineage hint wins only for equal Effective representation sets
/// (02 §9.3.1). Storage resolves and validates the active content before this
/// comparison; Canonical containment cannot authorize a lineage match.
package func confirmLineageCapture(
    incoming: CanonicalContent,
    effective: EffectiveContent,
    id: HistoryItemID,
    occurrence: CopyOccurrence,
    pinOrdinal: PinOrdinal?
) -> CaptureMatch? {
    let incomingEffective = EffectiveContent(representations: incoming.representations.map(\.content))
    guard incomingEffective.hasSameRepresentations(as: effective) else { return nil }
    return CaptureMatch(id: id, occurrence: occurrence, pinOrdinal: pinOrdinal)
}

/// Plans one capture from the confirmed winner: insert-or-coalesce and
/// same-commit retention victim selection.
/// docs/02-domain.md §8, §9, §12
///
/// Storage supplies the lineage winner or the complete Canonical reduction,
/// using the pure helpers above in that order (02 §9.3, D8–D9). Insert occurs
/// only when neither lane confirms a match.
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
    let winner = facts.confirmedMatch

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
        // Card 2B-1: the point-read occupancy is the authoritative pure fact
        // for this prepared business ID. Only the insert lane consumes
        // the prepared candidate; a coalescing winner above deliberately
        // ignores it. Storage catches this package rejection and remints —
        // the Domain never generates identity (docs/02-domain.md §1/§4).
        guard !facts.candidateIDExists else {
            throw DomainRejection.candidateItemIDCollision(
                capture.candidateID
            )
        }

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
    let retainedCount = facts.retention.retainedCount + (isInsert ? 1 : 0)
    let eligibleCount = facts.retention.unpinnedCount
        - (winner != nil && winner?.pinOrdinal == nil ? 1 : 0)
    let unpinnedCount = facts.retention.unpinnedCount + (isInsert ? 1 : 0)
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
    guard victimCount <= eligibleCount else {
        // D19: the user policy alone can always be satisfied; only the global
        // hard retained-item bound forces this failure (§12).
        throw DomainRejection.capacityExceeded(.retainedItems)
    }

    let victims = facts.retention.oldestUnpinnedItems.lazy
        .filter { $0.id != primaryID }
        .prefix(victimCount)
    for victim in victims {
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
    let unpinnedCount = facts.inventory.allItems.lazy
        .filter { $0.pinOrdinal == nil }
        .count

    // The unchanged case depends only on the persisted policy and unpinned
    // count. Return before establishing an eviction order when no victim can
    // exist; ordering remains necessary for every over-limit plan (§12, D16).
    if policy == facts.currentPolicy,
       unpinnedCount <= policy.maximumUnpinnedItems {
        return .unchanged
    }

    let victimCount = max(0, unpinnedCount - policy.maximumUnpinnedItems)
    let victims = evictionVictims(
        in: facts.inventory.allItems,
        excluding: nil,
        count: victimCount,
        eligibleCount: unpinnedCount
    )
    return planRetention(
        currentPolicy: facts.currentPolicy,
        policy: policy,
        victimIDs: victims.map(\.id)
    )
}

/// Plans a count-policy update from the complete selected victim prefix
/// (02 §12). Storage computes the excess from authoritative unpinned count
/// and fetches exactly that many oldest unpinned IDs, ordered by copy time
/// then business ID. The prefix contains every required victim, not an
/// arbitrary page of retained items; planning needs no other inventory.
package func planRetention(
    currentPolicy: RetentionPolicy,
    policy: RetentionPolicy,
    victimIDs: [HistoryItemID]
) -> PlanningResult {
    guard currentPolicy != policy || !victimIDs.isEmpty else { return .unchanged }
    var mutations: [HistoryMutation] = [
        .setRetentionPolicy(maximumUnpinnedItems: policy.maximumUnpinnedItems)
    ]
    for victimID in victimIDs {
        mutations.append(.retire(itemID: victimID, reason: .retention))
    }
    return .commit(MutationPlan(
        outcome: .retentionPolicySet(removedCount: victimIDs.count),
        mutations: mutations
    ))
}

/// Selects the first `count` rows in the eviction order of docs/02-domain.md
/// §12: `lastCopiedAt` ascending, then `HistoryItemID` bytes ascending. Fact
/// completeness gives every retained item exactly once, so unique IDs make
/// this a total order and the result independent of input ordering (D16).
///
/// Normal capture retention removes very few rows from a large inventory. A
/// bounded max-heap makes that path `O(N log K)` time and `O(K)` scratch for
/// `K` victims instead of sorting an `O(N)` copy. When a policy change removes
/// more than a quarter of all eligible rows, a full sort is deliberately used:
/// the result already requires `O(K)` mutation payloads, and contiguous sort
/// storage is faster than heap maintenance when `K` approaches `N`.
private func evictionVictims(
    in summaries: [RetainedItemSummary],
    excluding excludedID: HistoryItemID?,
    count: Int,
    eligibleCount: Int
) -> [RetainedItemSummary] {
    guard count > 0 else { return [] }

    if count > eligibleCount / 4 {
        var eligible = summaries.filter {
            $0.pinOrdinal == nil && $0.id != excludedID
        }
        eligible.sort(by: evictionRanksBefore)
        return Array(eligible.prefix(count))
    }

    var heap: [RetainedItemSummary] = []
    heap.reserveCapacity(count)
    for summary in summaries
    where summary.pinOrdinal == nil && summary.id != excludedID {
        offerEvictionCandidate(summary, to: &heap, capacity: count)
    }
    return heap.sorted(by: evictionRanksBefore)
}

private func evictionRanksBefore(
    _ lhs: RetainedItemSummary,
    _ rhs: RetainedItemSummary
) -> Bool {
    if lhs.lastCopiedAt != rhs.lastCopiedAt {
        return lhs.lastCopiedAt < rhs.lastCopiedAt
    }
    return lhs.id < rhs.id
}

/// Offers one row to a local max-heap under `evictionRanksBefore`: the root
/// is the latest (worst) retained victim, so a better row can replace it in
/// `O(log K)` time. Domain retains no mutable stored state (D17).
private func offerEvictionCandidate(
    _ summary: RetainedItemSummary,
    to heap: inout [RetainedItemSummary],
    capacity: Int
) {
    if heap.count < capacity {
        heap.append(summary)
        siftEvictionCandidateUp(in: &heap, from: heap.count - 1)
    } else if evictionRanksBefore(summary, heap[0]) {
        heap[0] = summary
        siftEvictionCandidateDown(in: &heap, from: 0)
    }
}

private func siftEvictionCandidateUp(
    in heap: inout [RetainedItemSummary],
    from startIndex: Int
) {
    var childIndex = startIndex
    while childIndex > 0 {
        let parentIndex = (childIndex - 1) / 2
        guard evictionRanksBefore(heap[parentIndex], heap[childIndex]) else {
            return
        }
        heap.swapAt(parentIndex, childIndex)
        childIndex = parentIndex
    }
}

private func siftEvictionCandidateDown(
    in heap: inout [RetainedItemSummary],
    from startIndex: Int
) {
    var parentIndex = startIndex
    while true {
        let leftIndex = parentIndex * 2 + 1
        guard leftIndex < heap.count else { return }

        let rightIndex = leftIndex + 1
        var worseChildIndex = leftIndex
        if rightIndex < heap.count,
           evictionRanksBefore(heap[leftIndex], heap[rightIndex]) {
            worseChildIndex = rightIndex
        }
        guard evictionRanksBefore(heap[parentIndex], heap[worseChildIndex]) else {
            return
        }
        heap.swapAt(parentIndex, worseChildIndex)
        parentIndex = worseChildIndex
    }
}
