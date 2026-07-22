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

/// Plans a first pin or a reorder of an already pinned item.
///
/// docs/02-domain.md §8, §10. The caller expresses a placement, never a
/// numeric slot; the complete ordered ID list in `facts.order` is the proven
/// pin state (§5.2).
///
/// - Throws: `DomainRejection.invalidPinnedPlacement(.targetMissing)` when the
///   target is not retained, `.targetEqualsAnchor` when a `.before` anchor
///   names the target itself, and `.anchorMissingOrUnpinned` when the anchor
///   is not another retained pinned item. (Placement uses this dedicated
///   vocabulary rather than `.notFound` by design — docs/03b-instruction-set.md
///   §10, docs/06-cross-cutting.md WS16.)
/// - Returns: `.unchanged` when the placement reproduces the existing order
///   (§10 step 5); otherwise a commit whose `.assignPin` mutations cover
///   exactly the IDs whose ordinal changed, including the target (§10 step 6,
///   plan invariant 4).
package func planPinnedPlacement(
    itemID: HistoryItemID,
    placement: PinnedPlacement,
    facts: PinFacts
) throws -> PlanningResult {
    // §10 step 1: reject a missing target.
    guard facts.targetExists else {
        throw DomainRejection.invalidPinnedPlacement(.targetMissing)
    }

    // §10 step 2: copy the complete ordered ID list and remove the target if
    // already pinned.
    let originalOrder = facts.order.itemIDs
    var finalOrder = originalOrder
    finalOrder.removeAll { $0 == itemID }

    // §10 steps 3–4: insert at the requested explicit position. `.before`
    // requires an anchor that is another retained pinned item.
    switch placement {
    case .first:
        finalOrder.insert(itemID, at: 0)
    case .last:
        finalOrder.append(itemID)
    case .before(let anchor):
        guard anchor != itemID else {
            throw DomainRejection.invalidPinnedPlacement(.targetEqualsAnchor)
        }
        guard let anchorIndex = finalOrder.firstIndex(of: anchor) else {
            throw DomainRejection.invalidPinnedPlacement(.anchorMissingOrUnpinned)
        }
        finalOrder.insert(itemID, at: anchorIndex)
    }

    // §10 step 5: a placement producing the existing order is a no-op.
    guard finalOrder != originalOrder else {
        return .unchanged
    }

    // §10 step 6: zip the final order with 0 ..< count and emit `.assignPin`
    // only for changed ordinals. The target is always among them: it either
    // moved within the order or enters from the unpinned state (old ordinal
    // `nil` never equals its new ordinal).
    return .commit(MutationPlan(
        outcome: .placedPinned(itemID),
        mutations: pinShiftMutations(from: originalOrder, to: finalOrder)
    ))
}

// MARK: - Unpin (docs/02-domain.md §10)

/// Plans removing an item from the pinned lane.
///
/// docs/02-domain.md §8, §10: unpin removes the target and shifts later
/// ordinals; the remaining order is zipped against `0 ..< count` exactly like
/// a placement.
///
/// - Throws: `DomainRejection.notFound(itemID)` when the target is not
///   retained (remove/unpin/revise use `.notFound`, placement alone uses
///   `.targetMissing` — docs/06-cross-cutting.md WS16, docs/AUDIT.md S1-R2).
/// - Returns: `.unchanged` when the target exists but is not pinned
///   (docs/03a-instruction-set.md §5); otherwise a commit assigning the target
///   a `nil` ordinal and shifting every later pinned item.
package func planUnpin(
    itemID: HistoryItemID,
    facts: PinFacts
) throws -> PlanningResult {
    guard facts.targetExists else {
        throw DomainRejection.notFound(itemID)
    }

    let originalOrder = facts.order.itemIDs
    guard originalOrder.contains(itemID) else {
        return .unchanged
    }

    let finalOrder = originalOrder.filter { $0 != itemID }
    let mutations =
        [HistoryMutation.assignPin(itemID: itemID, ordinal: nil)]
        + pinShiftMutations(from: originalOrder, to: finalOrder)
    return .commit(MutationPlan(outcome: .unpinned(itemID), mutations: mutations))
}

// MARK: - Remove (docs/02-domain.md §5.4, §8)

/// Plans the removal of one retained item.
///
/// docs/02-domain.md §8. Removal is absence from the retained set (D15);
/// there is no tombstone. The plan carries a single `.retire` mutation with
/// reason `.userRemoval`.
///
/// - Throws: `DomainRejection.notFound(itemID)` when the fact load found no
///   retained item with this ID (docs/06-cross-cutting.md WS16).
package func planRemove(
    itemID: HistoryItemID,
    facts: RemoveFacts
) throws -> PlanningResult {
    guard facts.item != nil else {
        throw DomainRejection.notFound(itemID)
    }
    return .commit(MutationPlan(
        outcome: .removed(count: 1),
        mutations: [.retire(itemID: itemID, reason: .userRemoval)]
    ))
}

// MARK: - Clear (docs/02-domain.md §5.4, §8)

/// Plans the removal of the complete item set selected by a clear scope.
///
/// docs/02-domain.md §8. `facts.affected` is the complete set selected by
/// `scope` at the Authority linearization point (§5.4), so the planner does
/// not re-interpret the scope: it retires exactly the affected set in one
/// commit. There is no partial clear. `scope` is part of the planner surface
/// (§8) and documents which selection the fact value proves complete.
///
/// - Returns: `.unchanged` when the affected set is empty (a commit's mutation
///   list is non-empty by invariant — §7); otherwise one `.retire` mutation
///   per affected item with reason `.clear`.
package func planClear(
    scope: ClearScope,
    facts: ClearFacts
) -> PlanningResult {
    guard !facts.affected.isEmpty else {
        return .unchanged
    }
    let mutations = facts.affected.map {
        HistoryMutation.retire(itemID: $0.id, reason: .clear)
    }
    return .commit(MutationPlan(
        outcome: .cleared(count: facts.affected.count),
        mutations: mutations
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
/// 3. Current Effective Content is derived; inconsistent lineage is corrupt.
/// 4. The proposed content is revalidated against Domain-level invariants.
/// 5. Byte-identical proposed content is a no-op.
/// 6. Otherwise the new revision is appended and made active.
///
/// - Throws: `DomainRejection.staleContent(expected:current:)` on an OCC
///   mismatch, `.invalidRevisionDraft` on a base-version mismatch or
///   un-normalized/foreign-typed proposed content, and `.corruptLineage` as
///   the defensive backstop for inconsistent lineage (§6).
package func planRevision(
    request: RevisionRequest,
    prepared: PreparedRevision,
    facts: RevisionFacts
) throws -> PlanningResult {
    let item = facts.item

    // §11 step 1: optimistic concurrency — the editor's base version must
    // still be the item's current Content Version.
    guard request.expected == item.contentVersion else {
        throw DomainRejection.staleContent(
            expected: request.expected,
            current: item.contentVersion
        )
    }

    // §11 step 2: a preparation result is built for exactly one base version
    // and is never reused; a mismatch is a defensive invariant violation.
    guard prepared.basedOn == request.expected else {
        throw DomainRejection.invalidRevisionDraft
    }

    // §11 step 3: derive current Effective Content. Storage validated lineage
    // at fact load; this is the defensive backstop (§6) for a missing or
    // duplicated active revision, or a non-empty revision list with a nil
    // active ID (D3). Planners throw only the §6 vocabulary.
    let current: EffectiveContent
    do {
        current = try effectiveContent(of: item)
    } catch {
        throw DomainRejection.corruptLineage
    }

    // §11 step 4: revalidate Domain-level invariants on the proposed content.
    // Numeric byte/count bounds were already enforced by Storage preparation
    // and are not re-asserted here (the Domain does not receive them).
    guard isNormalizedRevisionContent(prepared.proposedContent, canonical: item.canonical) else {
        throw DomainRejection.invalidRevisionDraft
    }

    // §11 step 5 (§2.5 rule 7): a proposed revision byte-equal to current
    // Effective Content is a no-op — no redundant revision, commit, version,
    // or invalidation. Both sides are normalized, so array equality is byte
    // equality.
    guard prepared.proposedContent != current else {
        return .unchanged
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

/// Emits `.assignPin` for every ID whose ordinal differs between the original
/// and the final pinned order.
///
/// docs/02-domain.md §10 step 6: the final order is zipped with `0 ..< count`;
/// only changed ordinals are emitted, and the final set plus unchanged pinned
/// items produces exactly one contiguous order (plan invariant 4, D12). An ID
/// entering the lane has no original ordinal, so `nil` never equals its new
/// ordinal and it is always emitted. Emission follows the final order, which
/// keeps planning deterministic (D16).
private func pinShiftMutations(
    from originalOrder: [HistoryItemID],
    to finalOrder: [HistoryItemID]
) -> [HistoryMutation] {
    var originalOrdinals: [HistoryItemID: PinOrdinal] = [:]
    for (index, id) in originalOrder.enumerated() {
        originalOrdinals[id] = PinOrdinal(rawValue: index)
    }
    var mutations: [HistoryMutation] = []
    for (index, id) in finalOrder.enumerated() {
        let ordinal = PinOrdinal(rawValue: index)
        if originalOrdinals[id] != ordinal {
            mutations.append(.assignPin(itemID: id, ordinal: ordinal))
        }
    }
    return mutations
}

/// Revalidates proposed Effective Content at the Domain level.
///
/// docs/02-domain.md §11 step 4: the content must be normalized per §2.1 —
/// non-empty, no empty-bytes representation, at most one representation per
/// type identifier, sorted by type identifier in stable Unicode scalar order
/// (a strictly increasing sequence proves both uniqueness and order, using the
/// same Unicode-scalar comparison as the `CanonicalContent` validator in
/// §2.3) — and must contain only Canonical representation types. Storage
/// preparation has already enforced the numeric bounds; the Domain does not
/// re-assert limits it does not receive (§11 step 4).
private func isNormalizedRevisionContent(
    _ proposed: EffectiveContent,
    canonical: CanonicalContent
) -> Bool {
    let representations = proposed.representations
    guard !representations.isEmpty else { return false }
    let canonicalTypes = Set(canonical.representations.map { $0.content.typeIdentifier })
    for (index, representation) in representations.enumerated() {
        guard !representation.bytes.isEmpty,
              canonicalTypes.contains(representation.typeIdentifier)
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
