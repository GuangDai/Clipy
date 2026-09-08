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
/// An optional user count policy is the only count-based retirement trigger
/// (V2-09 §9); pinned items never consume that allowance.
package func planCapture(
    _ capture: PreparedCapture,
    facts: IngestFacts,
    retention: RetentionPolicy
) throws -> PlanningResult {
    let winner = facts.confirmedMatch

    // Primary mutation: coalesce (§9.5) or insert (§9.3.3).
    let primaryID: HistoryItemID
    let primaryMutation: HistoryMutation
    let outcome: PlannedOutcome
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
    }

    let victimCount = try captureRetirementCount(
        confirmedMatch: winner,
        retainedCount: facts.retention.retainedCount,
        unpinnedCount: facts.retention.unpinnedCount,
        retention: retention
    )
    var mutations: [HistoryMutation] = [primaryMutation]
    if victimCount == 0 {
        guard facts.retention.retirementPrefix == nil else {
            throw DomainRejection.corruptLineage
        }
    } else {
        guard let prefix = facts.retention.retirementPrefix,
              prefix.itemCount == victimCount,
              prefix.excludedItemID == primaryID,
              prefix.through.itemID != primaryID else {
            throw DomainRejection.corruptLineage
        }
        mutations.append(.retirePrefix(prefix))
    }
    return .commit(MutationPlan(outcome: outcome, mutations: mutations))
}

/// Computes the exact excess before Storage selects its SQL eviction prefix.
/// Coalescing changes no counts, and neither pins nor the primary may be
/// retired. Nil disables count retirement; integer overflow still rejects an
/// unrepresentable count (V2-09 §9).
package func captureRetirementCount(
    confirmedMatch: CaptureMatch?,
    retainedCount: Int,
    unpinnedCount: Int,
    retention: RetentionPolicy
) throws -> Int {
    guard retainedCount >= 0, unpinnedCount >= 0,
          unpinnedCount <= retainedCount,
          retention.maximumUnpinnedItems.map({ $0 > 0 }) ?? true else {
        throw DomainRejection.corruptLineage
    }
    if let confirmedMatch {
        guard retainedCount > 0,
              confirmedMatch.pinOrdinal == nil || retainedCount > unpinnedCount else {
            throw DomainRejection.corruptLineage
        }
    }
    let isInsert = confirmedMatch == nil
    let increment = isInsert ? 1 : 0
    let (_, retainedOverflow) = retainedCount.addingReportingOverflow(increment)
    let (projectedUnpinned, unpinnedOverflow) = unpinnedCount.addingReportingOverflow(increment)
    guard !retainedOverflow, !unpinnedOverflow else {
        throw DomainRejection.capacityExceeded(.retainedItems)
    }
    let eligibleCount = unpinnedCount
        - (confirmedMatch != nil && confirmedMatch?.pinOrdinal == nil ? 1 : 0)
    guard eligibleCount >= 0 else { throw DomainRejection.corruptLineage }
    let victimCount = retention.maximumUnpinnedItems.map { max(0, projectedUnpinned - $0) } ?? 0
    guard victimCount <= eligibleCount else {
        throw DomainRejection.capacityExceeded(.retainedItems)
    }
    return victimCount
}

/// Plans one count-policy update with its exact SQL-selected retirement
/// prefix (02 §12, D18). The boundary and aggregate are constant-size even
/// when lowering the policy removes nearly the complete unpinned lane.
package func planRetention(
    currentPolicy: RetentionPolicy,
    policy: RetentionPolicy,
    retirementPrefix: RetentionRetirementPrefix?
) -> PlanningResult {
    guard currentPolicy != policy || retirementPrefix != nil else { return .unchanged }
    var mutations: [HistoryMutation] = [
        .setRetentionPolicy(maximumUnpinnedItems: policy.maximumUnpinnedItems)
    ]
    if let retirementPrefix {
        mutations.append(.retirePrefix(retirementPrefix))
    }
    return .commit(MutationPlan(
        outcome: .retentionPolicySet(removedCount: retirementPrefix?.itemCount ?? 0),
        mutations: mutations
    ))
}
