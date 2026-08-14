/// Direct pure-planner proofs for pin/remove/clear/revision invariants D2–D4,
/// D12, D15–D16, and D18 (docs/02-domain.md §10–§11, §14).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

internal func pinRevisionItemID(_ suffix: UInt8) -> HistoryItemID {
    HistoryItemID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

internal func pinRevisionRevisionID(_ suffix: UInt8) -> RevisionID {
    RevisionID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

internal func pinRevisionCanonical(_ bytes: String = "canonical") throws -> CanonicalContent {
    try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data(bytes.utf8)
            ),
            fingerprint: ContentFingerprint(rawValue: 1)
        ),
    ])
}

internal func pinRevisionState(
    id: HistoryItemID,
    canonical: CanonicalContent,
    contentVersion: ContentVersion = .initial,
    revisions: [ContentRevision] = [],
    activeRevisionID: RevisionID? = nil
) -> HistoryItemState {
    HistoryItemState(
        id: id,
        contentVersion: contentVersion,
        canonical: canonical,
        revisions: revisions,
        activeRevisionID: activeRevisionID,
        occurrence: CopyOccurrence(
            firstCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            count: 1,
            firstSource: nil,
            lastSource: nil
        ),
        pinOrdinal: nil
    )
}

@Test func everyClearScopeRetiresExactlyTheProvenAffectedSet() {
    let first = RetainedItemSummary(
        id: pinRevisionItemID(1),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
        pinOrdinal: nil
    )
    let second = RetainedItemSummary(
        id: pinRevisionItemID(2),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 200),
        pinOrdinal: PinOrdinal(rawValue: 0)
    )

    let cases: [(scope: ClearScope, affected: [RetainedItemSummary])] = [
        (.unpinned, [first]),
        (.all, [first, second]),
    ]
    for clearCase in cases {
        let result = planClear(
            scope: clearCase.scope,
            facts: ClearFacts(affected: clearCase.affected)
        )
        guard case .commit(let plan) = result,
              case .cleared(let count) = plan.outcome
        else {
            Issue.record("A non-empty clear did not produce a commit")
            continue
        }
        #expect(count == clearCase.affected.count)
        #expect(plan.mutations.count == clearCase.affected.count)
        for (mutation, expectedID) in zip(
            plan.mutations,
            clearCase.affected.map(\.id)
        ) {
            guard case .retire(let retiredID, .clear) = mutation else {
                Issue.record("Clear omitted an affected ID or its semantic reason")
                continue
            }
            #expect(retiredID == expectedID)
        }
    }

    for scope in [ClearScope.unpinned, .all] {
        switch planClear(scope: scope, facts: ClearFacts(affected: [])) {
        case .unchanged:
            break
        case .commit:
            Issue.record("An empty clear produced a commit")
        }
    }
}

@Test func pinnedPlacementRejectsEveryInvalidTargetAnchorRelationship() {
    let target = pinRevisionItemID(1)
    let pinnedAnchor = pinRevisionItemID(2)

    #expect(throws: DomainRejection.invalidPinnedPlacement(.targetMissing)) {
        try planPinnedPlacement(
            itemID: target,
            placement: .first,
            facts: PinFacts(
                targetExists: false,
                order: CompletePinnedOrder(itemIDs: [pinnedAnchor])
            )
        )
    }
    #expect(throws: DomainRejection.invalidPinnedPlacement(.targetEqualsAnchor)) {
        try planPinnedPlacement(
            itemID: target,
            placement: .before(target),
            facts: PinFacts(
                targetExists: true,
                order: CompletePinnedOrder(itemIDs: [target, pinnedAnchor])
            )
        )
    }
    #expect(throws: DomainRejection.invalidPinnedPlacement(.anchorMissingOrUnpinned)) {
        try planPinnedPlacement(
            itemID: target,
            placement: .before(pinRevisionItemID(3)),
            facts: PinFacts(
                targetExists: true,
                order: CompletePinnedOrder(itemIDs: [pinnedAnchor])
            )
        )
    }
}

@Test func validPinnedPlacementEmitsOnlyTheChangedContiguousOrdinals() throws {
    let first = pinRevisionItemID(1)
    let target = pinRevisionItemID(2)
    let anchor = pinRevisionItemID(3)
    let facts = PinFacts(
        targetExists: true,
        order: CompletePinnedOrder(itemIDs: [first, anchor])
    )
    let result = try planPinnedPlacement(
        itemID: target,
        placement: .before(anchor),
        facts: facts
    )

    guard case .commit(let plan) = result,
          case .placedPinned(let placedID) = plan.outcome,
          plan.mutations.count == 2,
          case .assignPin(let insertedID, let insertedOrdinal) = plan.mutations[0],
          case .assignPin(let shiftedID, let shiftedOrdinal) = plan.mutations[1]
    else {
        Issue.record("A valid before-anchor placement did not emit the complete pin shift")
        return
    }
    #expect(placedID == target)
    #expect(insertedID == target)
    #expect(insertedOrdinal?.rawValue == 1)
    #expect(shiftedID == anchor)
    #expect(shiftedOrdinal?.rawValue == 2)

    switch try planPinnedPlacement(
        itemID: first,
        placement: .first,
        facts: facts
    ) {
    case .unchanged:
        break
    case .commit:
        Issue.record("A placement reproducing the existing order was not a no-op")
    }
}

@Test func validReorderMovesAnAlreadyPinnedTargetToLast() throws {
    let target = pinRevisionItemID(1)
    let middle = pinRevisionItemID(2)
    let last = pinRevisionItemID(3)
    let result = try planPinnedPlacement(
        itemID: target,
        placement: .last,
        facts: PinFacts(
            targetExists: true,
            order: CompletePinnedOrder(itemIDs: [target, middle, last])
        )
    )

    guard case .commit(let plan) = result,
          case .placedPinned(let placedID) = plan.outcome,
          plan.mutations.count == 3,
          case .assignPin(let firstID, let firstOrdinal) = plan.mutations[0],
          case .assignPin(let secondID, let secondOrdinal) = plan.mutations[1],
          case .assignPin(let thirdID, let thirdOrdinal) = plan.mutations[2]
    else {
        Issue.record("Moving an already-pinned target to last produced an incomplete order")
        return
    }
    #expect(placedID == target)
    #expect(firstID == middle)
    #expect(firstOrdinal?.rawValue == 0)
    #expect(secondID == last)
    #expect(secondOrdinal?.rawValue == 1)
    #expect(thirdID == target)
    #expect(thirdOrdinal?.rawValue == 2)
}

@Test func unpinningAnAlreadyUnpinnedItemIsUnchanged() throws {
    let target = pinRevisionItemID(1)
    let result = try planUnpin(
        itemID: target,
        facts: PinFacts(
            targetExists: true,
            order: CompletePinnedOrder(itemIDs: [pinRevisionItemID(2)])
        )
    )

    switch result {
    case .unchanged:
        break
    case .commit:
        Issue.record("An already-unpinned target produced a mutation plan")
    }
}

@Test func unpinningAPinnedItemClearsItAndCompactsEveryLaterOrdinal() throws {
    let first = pinRevisionItemID(1)
    let target = pinRevisionItemID(2)
    let last = pinRevisionItemID(3)
    let result = try planUnpin(
        itemID: target,
        facts: PinFacts(
            targetExists: true,
            order: CompletePinnedOrder(itemIDs: [first, target, last])
        )
    )

    guard case .commit(let plan) = result,
          case .unpinned(let unpinnedID) = plan.outcome,
          plan.mutations.count == 2,
          case .assignPin(let clearedID, let clearedOrdinal) = plan.mutations[0],
          case .assignPin(let shiftedID, let shiftedOrdinal) = plan.mutations[1]
    else {
        Issue.record("Unpinning a pinned target did not clear and compact in one plan")
        return
    }
    #expect(unpinnedID == target)
    #expect(clearedID == target)
    #expect(clearedOrdinal == nil)
    #expect(shiftedID == last)
    #expect(shiftedOrdinal?.rawValue == 1)
}

@Test func unpinningTheOnlyPinnedItemNeedsExactlyOneNilAssignment() throws {
    let target = pinRevisionItemID(1)
    let result = try planUnpin(
        itemID: target,
        facts: PinFacts(
            targetExists: true,
            order: CompletePinnedOrder(itemIDs: [target])
        )
    )

    guard case .commit(let plan) = result,
          case .unpinned(let unpinnedID) = plan.outcome,
          plan.mutations.count == 1,
          case .assignPin(let clearedID, let ordinal) = plan.mutations[0]
    else {
        Issue.record("Unpinning the only pinned item emitted an unnecessary shift")
        return
    }
    #expect(unpinnedID == target)
    #expect(clearedID == target)
    #expect(ordinal == nil)
}

@Test func unpinAndRemoveRejectMissingTargetsWithNotFound() {
    let target = pinRevisionItemID(1)

    #expect(throws: DomainRejection.notFound(target)) {
        try planUnpin(
            itemID: target,
            facts: PinFacts(
                targetExists: false,
                order: CompletePinnedOrder(itemIDs: [])
            )
        )
    }
    #expect(throws: DomainRejection.notFound(target)) {
        try planRemove(
            itemID: target,
            facts: RemoveFacts(
                item: nil,
                pinnedOrder: CompletePinnedOrder(itemIDs: [])
            )
        )
    }
}

@Test func removingMiddlePinnedItemCompactsLaterOrdinalInTheSamePlan() throws {
    let first = pinRevisionItemID(1)
    let target = pinRevisionItemID(2)
    let last = pinRevisionItemID(3)
    let result = try planRemove(
        itemID: target,
        facts: RemoveFacts(
            item: RetainedItemSummary(
                id: target,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                pinOrdinal: PinOrdinal(rawValue: 1)
            ),
            pinnedOrder: CompletePinnedOrder(itemIDs: [first, target, last])
        )
    )

    guard case .commit(let plan) = result,
          plan.mutations.count == 2,
          case .assignPin(let shiftedID, let ordinal) = plan.mutations[0],
          case .retire(let retiredID, let reason) = plan.mutations[1]
    else {
        Issue.record("Middle removal did not compact then retire in one plan")
        return
    }
    #expect(shiftedID == last)
    #expect(ordinal?.rawValue == 1)
    #expect(retiredID == target)
    if case .userRemoval = reason {
        // Expected semantic reason.
    } else {
        Issue.record("The removed target carried the wrong retirement reason")
    }
}

@Test func removingLastPinnedItemNeedsOnlyTheRetirementMutation() throws {
    let first = pinRevisionItemID(1)
    let target = pinRevisionItemID(2)
    let result = try planRemove(
        itemID: target,
        facts: RemoveFacts(
            item: RetainedItemSummary(
                id: target,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                pinOrdinal: PinOrdinal(rawValue: 1)
            ),
            pinnedOrder: CompletePinnedOrder(itemIDs: [first, target])
        )
    )

    guard case .commit(let plan) = result,
          plan.mutations.count == 1,
          case .retire(let retiredID, _) = plan.mutations[0]
    else {
        Issue.record("Last pinned removal emitted an unnecessary pin shift")
        return
    }
    #expect(retiredID == target)
}

