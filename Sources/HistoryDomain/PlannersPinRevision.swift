/// PlannersPinRevision.swift — the pure planners for pin placement, unpin,
/// remove, clear, and revision. Owning spec: docs/02-domain.md §8 (planner
/// surface), §10 (pinned order), §11 (revision planning and OCC); plan shape
/// and invariants per §7 and §14.
///
/// Imports Foundation + HistoryCore only. The Domain has no I/O, actor, clock,
/// UUID generator, cache, or async method (docs/02-domain.md §1), and it never
/// mints `ContentVersion`/`ChangePosition` tokens — plans describe semantic
/// mutations declaratively and `HistoryStorage` stamps tokens mechanically
/// (docs/02-domain.md §4, §13).
import Foundation
import HistoryCore

// MARK: - Pin placement (docs/02-domain.md §10)

/// Plans first pin or reorder from target/anchor ordinal point facts. Error
/// priority stays target missing, self anchor, then invalid anchor (02 §10;
/// WS16). An unchanged destination is a true no-op; every other placement
/// describes the target and one shifted ordinal interval, regardless of P.
package func planPinnedPlacement(
    itemID: HistoryItemID,
    placement: PinnedPlacement,
    facts: PinFacts
) throws -> PlanningResult {
    guard facts.targetExists else {
        throw DomainRejection.invalidPinnedPlacement(.targetMissing)
    }
    let anchorOrdinal: Int?
    switch placement {
    case .before(let anchor):
        guard anchor != itemID else {
            throw DomainRejection.invalidPinnedPlacement(.targetEqualsAnchor)
        }
        guard let ordinal = facts.anchorOrdinal else {
            throw DomainRejection.invalidPinnedPlacement(.anchorMissingOrUnpinned)
        }
        anchorOrdinal = ordinal.rawValue
    case .first, .last:
        anchorOrdinal = nil
    }
    try validatePinOrdinal(facts.targetOrdinal, count: facts.pinnedCount)
    if let anchorOrdinal {
        try validatePinOrdinal(PinOrdinal(rawValue: anchorOrdinal), count: facts.pinnedCount)
        // Distinct retained pinned items cannot occupy the same ordinal.
        guard facts.targetOrdinal?.rawValue != anchorOrdinal else {
            throw DomainRejection.corruptLineage
        }
    }
    if facts.targetOrdinal == nil,
       facts.pinnedCount.addingReportingOverflow(1).overflow {
        throw DomainRejection.capacityExceeded(.retainedItems)
    }
    let source = facts.targetOrdinal?.rawValue
    let destination: Int
    switch placement {
    case .first:
        destination = 0
    case .last:
        destination = facts.pinnedCount - (source == nil ? 0 : 1)
    case .before:
        guard let anchorOrdinal else { throw DomainRejection.corruptLineage }
        // Removing a target that precedes its anchor moves that anchor one
        // slot earlier. This also makes an adjacent .before a no-op.
        destination = anchorOrdinal - (source.map { $0 < anchorOrdinal } == true ? 1 : 0)
    }
    guard source != destination else { return .unchanged }
    return .commit(MutationPlan(
        outcome: .placedPinned(itemID),
        mutations: [.relocatePin(pinRelocation(
            itemID: itemID, previous: source, destination: destination, count: facts.pinnedCount))]
    ))
}

// MARK: - Unpin (docs/02-domain.md §10)

/// Unpin changes the target and the later ordinal suffix only (02 §10).
/// Missing target remains .notFound; an existing unpinned item is unchanged.
package func planUnpin(
    itemID: HistoryItemID,
    facts: PinFacts
) throws -> PlanningResult {
    guard facts.targetExists else {
        throw DomainRejection.notFound(itemID)
    }
    try validatePinOrdinal(facts.targetOrdinal, count: facts.pinnedCount)
    guard let source = facts.targetOrdinal?.rawValue else { return .unchanged }
    return .commit(MutationPlan(outcome: .unpinned(itemID), mutations: [
        .relocatePin(pinRelocation(itemID: itemID, previous: source,
                                  destination: nil, count: facts.pinnedCount))
    ]))
}

// MARK: - Remove (docs/02-domain.md §5.4, §8)

/// Pinned removal first unpins/compacts with the same compact relocation,
/// then retires the now-unpinned target (02 §10, D12/D15). Relocation changes
/// pinned count once; deletion owns retained count and content-byte removal.
package func planRemove(
    itemID: HistoryItemID,
    facts: RemoveFacts
) throws -> PlanningResult {
    guard let item = facts.item else {
        throw DomainRejection.notFound(itemID)
    }
    try validatePinOrdinal(item.pinOrdinal, count: facts.pinnedCount)
    var mutations: [HistoryMutation] = []
    if let source = item.pinOrdinal?.rawValue {
        mutations.append(.relocatePin(pinRelocation(
            itemID: itemID, previous: source, destination: nil, count: facts.pinnedCount)))
    }
    mutations.append(.retire(itemID: itemID, reason: .userRemoval))
    return .commit(MutationPlan(outcome: .removed(count: 1), mutations: mutations))
}

// MARK: - Clear (docs/02-domain.md §5.4, §8)

/// Plans the removal of the complete item set selected by a clear scope.
///
/// docs/02-domain.md §8. `facts.affectedCount` counts the complete scope selected by
/// `scope` at the Authority linearization point (§5.4), so the planner does
/// not re-interpret the scope: it retires exactly the affected set in one
/// commit. There is no partial clear. `scope` is part of the planner surface
/// (§8) and documents which selection the fact value proves complete.
///
/// - Returns: `.unchanged` when the affected set is empty (a commit's mutation
///   list is non-empty by invariant — §7); otherwise one `.bulkClear` mutation
///   for the complete scope, without per-item mutation allocation.
package func planClear(
    scope: ClearScope,
    facts: ClearFacts
) -> PlanningResult {
    // Both v1 scopes select a set whose remaining pinned lane is trivially
    // contiguous. Keep the switch here as an evolution forcing function: a
    // future partial-pinned scope must revisit D12 at the planner seam.
    switch scope {
    case .unpinned, .all:
        break
    }

    guard facts.affectedCount > 0 else {
        return .unchanged
    }
    return .commit(MutationPlan(
        outcome: .cleared(count: facts.affectedCount),
        mutations: [.bulkClear(scope: scope, affectedCount: facts.affectedCount)]
    ))
}

// MARK: - Revision (docs/02-domain.md §11)

/// Plans appending one new Effective Content revision to an item.
///
/// docs/02-domain.md §8, §11. Both intents (`.replace` and `.revert`) arrive
/// here fully resolved by `HistoryStorage` preparation: `prepared` already
/// carries the complete proposed Effective Content, so a revert mints a NEW
/// revision from historical Effective Content and never repoints an old one
/// (§2.5 rule 6, §11). The planning order is fixed by §11:
///
/// 1. OCC: `request.expected` must equal the item's current Content Version.
/// 2. The preparation result is built for exactly one base version.
/// 3. Current Effective Content comes from validated Storage facts.
/// 4. The proposed content is revalidated against Domain-level invariants.
/// 5. Byte-identical proposed content is a no-op.
/// 6. Otherwise require a new candidate Revision ID, append, and make it active.
///
/// - Throws: `DomainRejection.staleContent(expected:current:)` on an OCC
///   mismatch, `.invalidRevisionDraft` on a base-version mismatch or
///   invalid prepared content/duplicate candidate ID. Storage rejects corrupt
///   active lineage before constructing `RevisionFacts` (§6).
package func planRevision(
    request: RevisionRequest,
    prepared: PreparedRevision,
    facts: RevisionFacts
) throws -> PlanningResult {
    // §11 step 1: optimistic concurrency — the editor's base version must
    // still be the item's current Content Version.
    guard request.expected == facts.contentVersion else {
        throw DomainRejection.staleContent(
            expected: request.expected,
            current: facts.contentVersion
        )
    }

    // §11 step 2: a preparation result is built for exactly one base version
    // and is never reused; a mismatch is a defensive invariant violation.
    guard prepared.basedOn == request.expected else {
        throw DomainRejection.invalidRevisionDraft
    }

    // §11 step 4: revalidate Domain-level invariants on the proposed content.
    // Numeric byte/count bounds were already enforced by Storage preparation
    // and are not re-asserted here (the Domain does not receive them).
    guard isNormalizedRevisionContent(prepared.proposedContent, canonical: facts.canonical) else {
        throw DomainRejection.invalidRevisionDraft
    }

    // §11 step 5 (§2.5 rule 7): a proposed revision byte-equal to current
    // Effective Content is a no-op — no redundant revision, commit, version,
    // or invalidation. Compare representation sets because equivalent type
    // identifier spellings can change their normalized scalar order (§2.1).
    guard !prepared.proposedContent.hasSameRepresentations(as: facts.current) else {
        return .unchanged
    }

    // §2.5 rule 2: a successful append must add one new lineage identity.
    // A duplicate candidate is invalid preparation, not corrupt stored state.
    guard !facts.revisions.contains(where: { $0.id == prepared.candidateRevisionID }) else {
        throw DomainRejection.invalidRevisionDraft
    }

    // §11 step 6 (§2.5 rule 6, D4): append the complete immutable revision
    // snapshot and make it active. The candidate Revision ID and timestamp
    // were minted by Storage preparation (§4); the Domain mints nothing.
    let revision = ContentRevision(
        id: prepared.candidateRevisionID,
        createdAt: prepared.createdAt,
        content: prepared.proposedContent
    )
    return .commit(MutationPlan(
        outcome: .revised(request.itemID),
        mutations: [.appendRevision(
            itemID: request.itemID,
            revision: revision,
            activeRevisionID: prepared.candidateRevisionID
        )]
    ))
}

// MARK: - File-private helpers

/// Storage proves the complete lane; these constant-size checks reject an
/// internally contradictory scalar fact before constructing a range.
private func validatePinOrdinal(_ ordinal: PinOrdinal?, count: Int) throws {
    guard count >= 0 else { throw DomainRejection.corruptLineage }
    if let ordinal {
        guard ordinal.rawValue >= 0, ordinal.rawValue < count else {
            throw DomainRejection.corruptLineage
        }
    }
}

private func pinRelocation(itemID: HistoryItemID, previous: Int?,
                           destination: Int?, count: Int) -> PinRelocation {
    let shift: PinOrdinalShift?
    switch (previous, destination) {
    case (.none, .some(let destination)):
        shift = destination < count
            ? PinOrdinalShift(range: destination...(count - 1), delta: 1) : nil
    case (.some(let source), .none):
        shift = source < count - 1
            ? PinOrdinalShift(range: (source + 1)...(count - 1), delta: -1) : nil
    case (.some(let source), .some(let destination)) where destination < source:
        shift = PinOrdinalShift(range: destination...(source - 1), delta: 1)
    case (.some(let source), .some(let destination)) where source < destination:
        shift = PinOrdinalShift(range: (source + 1)...destination, delta: -1)
    default:
        shift = nil
    }
    return PinRelocation(itemID: itemID,
        previousOrdinal: previous.map { PinOrdinal(rawValue: $0) },
        destinationOrdinal: destination.map { PinOrdinal(rawValue: $0) },
        pinnedCountBefore: count, shift: shift)
}

/// Revalidates proposed Effective Content at the Domain level.
///
/// docs/02-domain.md §11 step 4: the content must be normalized per §2.1 —
/// non-empty, no empty-bytes representation, at most one representation per
/// canonically equivalent type identifier, sorted by type identifier in stable
/// Unicode scalar order — and must contain only Canonical representation types.
/// String equality and scalar order have different Unicode-equivalence
/// semantics, so uniqueness and ordering are checked independently, matching
/// the `CanonicalContent` validator in §2.3. Storage
/// preparation has already enforced the numeric bounds; the Domain does not
/// re-assert limits it does not receive (§11 step 4).
private func isNormalizedRevisionContent(
    _ proposed: EffectiveContent,
    canonical: CanonicalContent
) -> Bool {
    let representations = proposed.representations
    guard !representations.isEmpty else { return false }
    let canonicalTypes = Set(canonical.representations.map { $0.content.typeIdentifier })
    var seenTypes = Set<String>()
    seenTypes.reserveCapacity(representations.count)
    for (index, representation) in representations.enumerated() {
        guard !representation.bytes.isEmpty,
              canonicalTypes.contains(representation.typeIdentifier),
              seenTypes.insert(representation.typeIdentifier).inserted
        else {
            return false
        }
        if index > 0 {
            let previous = representations[index - 1].typeIdentifier.unicodeScalars
            let current = representation.typeIdentifier.unicodeScalars
            guard previous.lexicographicallyPrecedes(current) else { return false }
        }
    }
    return true
}
