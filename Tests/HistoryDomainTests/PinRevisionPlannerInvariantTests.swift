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

@Test func everyClearScopeRetiresExactlyTheProvenAffectedCount() {
    let cases: [(scope: ClearScope, affectedCount: Int)] = [
        (.unpinned, 1), (.all, 2), (.unpinned, 20_000), (.all, 20_000),
    ]
    for clearCase in cases {
        let result = planClear(
            scope: clearCase.scope,
            facts: ClearFacts(affectedCount: clearCase.affectedCount)
        )
        guard case .commit(let plan) = result,
              case .cleared(let count) = plan.outcome
        else {
            Issue.record("A non-empty clear did not produce a commit")
            continue
        }
        #expect(count == clearCase.affectedCount)
        #expect(plan.mutations.count == 1)
        guard case .bulkClear(let scope, let affectedCount) = plan.mutations[0] else {
            Issue.record("Clear must carry one explicit scope, not expand membership")
            continue
        }
        #expect(scope == clearCase.scope)
        #expect(affectedCount == count)
    }

    for scope in [ClearScope.unpinned, .all] {
        switch planClear(scope: scope, facts: ClearFacts(affectedCount: 0)) {
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
                targetExists: false, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: 1
            )
        )
    }
    #expect(throws: DomainRejection.invalidPinnedPlacement(.targetEqualsAnchor)) {
        try planPinnedPlacement(
            itemID: target,
            placement: .before(target),
            facts: PinFacts(
                targetExists: true, targetOrdinal: PinOrdinal(rawValue: 0),
                anchorOrdinal: PinOrdinal(rawValue: 0), pinnedCount: 2
            )
        )
    }
    #expect(throws: DomainRejection.invalidPinnedPlacement(.anchorMissingOrUnpinned)) {
        try planPinnedPlacement(
            itemID: target,
            placement: .before(pinnedAnchor),
            facts: PinFacts(
                targetExists: true, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: 1
            )
        )
    }
}

@Test func validPinnedPlacementEmitsOnlyTheChangedContiguousOrdinals() throws {
    let first = pinRevisionItemID(1)
    let target = pinRevisionItemID(2)
    let anchor = pinRevisionItemID(3)
    let facts = PinFacts(
        targetExists: true, targetOrdinal: nil, anchorOrdinal: PinOrdinal(rawValue: 1), pinnedCount: 2
    )
    let result = try planPinnedPlacement(
        itemID: target,
        placement: .before(anchor),
        facts: facts
    )

    guard case .commit(let plan) = result,
          case .placedPinned(let placedID) = plan.outcome,
          plan.mutations.count == 1,
          case .relocatePin(let relocation) = plan.mutations[0]
    else {
        Issue.record("A valid before-anchor placement did not emit the complete pin shift")
        return
    }
    #expect(placedID == target)
    #expect(relocation.itemID == target)
    #expect(relocation.previousOrdinal == nil)
    #expect(relocation.destinationOrdinal?.rawValue == 1)
    #expect(relocation.pinnedCountBefore == 2)
    #expect(relocation.shift?.range == 1...1)
    #expect(relocation.shift?.delta == 1)

    switch try planPinnedPlacement(
        itemID: first,
        placement: .first,
        facts: PinFacts(targetExists: true, targetOrdinal: PinOrdinal(rawValue: 0),
            anchorOrdinal: nil, pinnedCount: 2)
    ) {
    case .unchanged:
        break
    case .commit:
        Issue.record("A placement reproducing the existing order was not a no-op")
    }
}

@Test func validReorderMovesAnAlreadyPinnedTargetToLast() throws {
    let target = pinRevisionItemID(1)
    let result = try planPinnedPlacement(
        itemID: target,
        placement: .last,
        facts: PinFacts(
            targetExists: true, targetOrdinal: PinOrdinal(rawValue: 0),
            anchorOrdinal: nil, pinnedCount: 3
        )
    )

    guard case .commit(let plan) = result,
          case .placedPinned(let placedID) = plan.outcome,
          plan.mutations.count == 1,
          case .relocatePin(let relocation) = plan.mutations[0]
    else {
        Issue.record("Moving an already-pinned target to last produced an incomplete order")
        return
    }
    #expect(placedID == target)
    #expect(relocation.itemID == target)
    #expect(relocation.previousOrdinal?.rawValue == 0)
    #expect(relocation.destinationOrdinal?.rawValue == 2)
    #expect(relocation.pinnedCountBefore == 3)
    #expect(relocation.shift?.range == 1...2)
    #expect(relocation.shift?.delta == -1)
}

@Test func unpinningAnAlreadyUnpinnedItemIsUnchanged() throws {
    let target = pinRevisionItemID(1)
    let result = try planUnpin(
        itemID: target,
        facts: PinFacts(
            targetExists: true, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: 1
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
    let target = pinRevisionItemID(2)
    let result = try planUnpin(
        itemID: target,
        facts: PinFacts(
            targetExists: true, targetOrdinal: PinOrdinal(rawValue: 1),
            anchorOrdinal: nil, pinnedCount: 3
        )
    )

    guard case .commit(let plan) = result,
          case .unpinned(let unpinnedID) = plan.outcome,
          plan.mutations.count == 1,
          case .relocatePin(let relocation) = plan.mutations[0]
    else {
        Issue.record("Unpinning a pinned target did not clear and compact in one plan")
        return
    }
    #expect(unpinnedID == target)
    #expect(relocation.itemID == target)
    #expect(relocation.previousOrdinal?.rawValue == 1)
    #expect(relocation.destinationOrdinal == nil)
    #expect(relocation.pinnedCountBefore == 3)
    #expect(relocation.shift?.range == 2...2)
    #expect(relocation.shift?.delta == -1)
}

@Test func unpinningTheOnlyPinnedItemNeedsExactlyOneNilAssignment() throws {
    let target = pinRevisionItemID(1)
    let result = try planUnpin(
        itemID: target,
        facts: PinFacts(
            targetExists: true, targetOrdinal: PinOrdinal(rawValue: 0),
            anchorOrdinal: nil, pinnedCount: 1
        )
    )

    guard case .commit(let plan) = result,
          case .unpinned(let unpinnedID) = plan.outcome,
          plan.mutations.count == 1,
          case .relocatePin(let relocation) = plan.mutations[0]
    else {
        Issue.record("Unpinning the only pinned item emitted an unnecessary shift")
        return
    }
    #expect(unpinnedID == target)
    #expect(relocation.itemID == target)
    #expect(relocation.previousOrdinal?.rawValue == 0)
    #expect(relocation.destinationOrdinal == nil)
    #expect(relocation.pinnedCountBefore == 1)
    #expect(relocation.shift == nil)
}

@Test func unpinAndRemoveRejectMissingTargetsWithNotFound() {
    let target = pinRevisionItemID(1)

    #expect(throws: DomainRejection.notFound(target)) {
        try planUnpin(
            itemID: target,
            facts: PinFacts(
                targetExists: false, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: 0
            )
        )
    }
    #expect(throws: DomainRejection.notFound(target)) {
        try planRemove(
            itemID: target,
            facts: RemoveFacts(
                item: nil,
                pinnedCount: 0
            )
        )
    }
}

@Test func removingMiddlePinnedItemCompactsLaterOrdinalInTheSamePlan() throws {
    let target = pinRevisionItemID(2)
    let result = try planRemove(
        itemID: target,
        facts: RemoveFacts(
            item: RetainedItemSummary(
                id: target,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                pinOrdinal: PinOrdinal(rawValue: 1)
            ),
            pinnedCount: 3
        )
    )

    guard case .commit(let plan) = result,
          plan.mutations.count == 2,
          case .relocatePin(let relocation) = plan.mutations[0],
          case .retire(let retiredID, let reason) = plan.mutations[1]
    else {
        Issue.record("Middle removal did not compact then retire in one plan")
        return
    }
    #expect(relocation.itemID == target)
    #expect(relocation.previousOrdinal?.rawValue == 1)
    #expect(relocation.destinationOrdinal == nil)
    #expect(relocation.pinnedCountBefore == 3)
    #expect(relocation.shift?.range == 2...2)
    #expect(relocation.shift?.delta == -1)
    #expect(retiredID == target)
    if case .userRemoval = reason {
        // Expected semantic reason.
    } else {
        Issue.record("The removed target carried the wrong retirement reason")
    }
}

@Test(arguments: [1, 2])
func removingLastPinnedItemClearsItsPinWithoutShiftingAnotherItem(pinnedCount: Int) throws {
    let target = pinRevisionItemID(2)
    let result = try planRemove(
        itemID: target,
        facts: RemoveFacts(
            item: RetainedItemSummary(
                id: target,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                pinOrdinal: PinOrdinal(rawValue: pinnedCount - 1)
            ),
            pinnedCount: pinnedCount
        )
    )

    guard case .commit(let plan) = result,
          plan.mutations.count == 2,
          case .relocatePin(let relocation) = plan.mutations[0],
          case .retire(let retiredID, let reason) = plan.mutations[1]
    else {
        Issue.record("Last pinned removal emitted an unnecessary pin shift")
        return
    }
    #expect(relocation.itemID == target)
    #expect(relocation.previousOrdinal?.rawValue == pinnedCount - 1)
    #expect(relocation.destinationOrdinal == nil)
    #expect(relocation.pinnedCountBefore == pinnedCount)
    #expect(relocation.shift == nil)
    #expect(retiredID == target)
    if case .userRemoval = reason {
        // Expected semantic reason.
    } else {
        Issue.record("The removed target carried the wrong retirement reason")
    }
}

@Test func beforePlacementCompensatesForRemovingTheTargetFromEitherSide() throws {
    let target = pinRevisionItemID(1)
    let anchor = pinRevisionItemID(2)
    let cases: [(old: Int?, anchor: Int, count: Int, destination: Int, range: ClosedRange<Int>, delta: Int)] = [
        (1, 4, 5, 3, 2...3, -1),
        (4, 1, 5, 1, 1...3, 1),
        (nil, 0, 3, 0, 0...2, 1),
        (nil, 2, 3, 2, 2...2, 1),
    ]
    for sample in cases {
        let result = try planPinnedPlacement(itemID: target, placement: .before(anchor), facts: PinFacts(
            targetExists: true, targetOrdinal: sample.old.map(PinOrdinal.init(rawValue:)),
            anchorOrdinal: PinOrdinal(rawValue: sample.anchor), pinnedCount: sample.count
        ))
        guard case .commit(let plan) = result, plan.mutations.count == 1,
              case .relocatePin(let relocation) = plan.mutations[0] else {
            Issue.record("Before placement must emit one complete interval relocation")
            continue
        }
        #expect(relocation.itemID == target)
        #expect(relocation.previousOrdinal?.rawValue == sample.old)
        #expect(relocation.destinationOrdinal?.rawValue == sample.destination)
        #expect(relocation.pinnedCountBefore == sample.count)
        #expect(relocation.shift?.range == sample.range)
        #expect(relocation.shift?.delta == sample.delta)
    }
}

@Test func adjacentBeforeAndBothExistingEndpointsAreNoOps() throws {
    let target = pinRevisionItemID(1)
    let anchor = pinRevisionItemID(2)
    let cases: [(placement: PinnedPlacement, old: Int, anchor: Int?)] = [
        (.first, 0, nil), (.last, 3, nil), (.before(anchor), 0, 1), (.before(anchor), 2, 3),
    ]
    for sample in cases {
        let result = try planPinnedPlacement(itemID: target, placement: sample.placement, facts: PinFacts(
            targetExists: true, targetOrdinal: PinOrdinal(rawValue: sample.old),
            anchorOrdinal: sample.anchor.map(PinOrdinal.init(rawValue:)), pinnedCount: 4
        ))
        guard case .unchanged = result else {
            Issue.record("A placement already at its requested position must not commit")
            continue
        }
    }
}

@Test func addingAtTheEndOrToAnEmptyPinnedLaneRequiresNoShift() throws {
    let target = pinRevisionItemID(1)
    let cases: [(count: Int, placement: PinnedPlacement)] = [(0, .first), (0, .last), (3, .last)]
    for sample in cases {
        let result = try planPinnedPlacement(itemID: target, placement: sample.placement, facts: PinFacts(
            targetExists: true, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: sample.count
        ))
        guard case .commit(let plan) = result, plan.mutations.count == 1,
              case .relocatePin(let relocation) = plan.mutations[0] else {
            Issue.record("An endpoint insertion must emit exactly its target relocation")
            continue
        }
        #expect(relocation.itemID == target)
        #expect(relocation.previousOrdinal == nil)
        #expect(relocation.destinationOrdinal?.rawValue == sample.count)
        #expect(relocation.pinnedCountBefore == sample.count)
        #expect(relocation.shift == nil)
    }
}

@Test func relationshipErrorsPrecedeMalformedPinCountFacts() {
    let target = pinRevisionItemID(1)
    let anchor = pinRevisionItemID(2)
    #expect(throws: DomainRejection.invalidPinnedPlacement(.targetMissing)) {
        try planPinnedPlacement(itemID: target, placement: .before(target), facts: PinFacts(
            targetExists: false, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: -1
        ))
    }
    #expect(throws: DomainRejection.invalidPinnedPlacement(.targetEqualsAnchor)) {
        try planPinnedPlacement(itemID: target, placement: .before(target), facts: PinFacts(
            targetExists: true, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: -1
        ))
    }
    #expect(throws: DomainRejection.invalidPinnedPlacement(.anchorMissingOrUnpinned)) {
        try planPinnedPlacement(itemID: target, placement: .before(anchor), facts: PinFacts(
            targetExists: true, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: -1
        ))
    }
    #expect(throws: DomainRejection.notFound(target)) {
        try planUnpin(itemID: target, facts: PinFacts(
            targetExists: false, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: -1
        ))
    }
    #expect(throws: DomainRejection.notFound(target)) {
        try planRemove(itemID: target, facts: RemoveFacts(item: nil, pinnedCount: -1))
    }
}

@Test func impossiblePinOrdinalsRejectWithoutPlanningARepair() {
    let target = pinRevisionItemID(1)
    for (ordinal, count) in [(-1, 3), (3, 3), (0, 0), (0, -1)] {
        let facts = PinFacts(targetExists: true, targetOrdinal: PinOrdinal(rawValue: ordinal),
            anchorOrdinal: nil, pinnedCount: count)
        #expect(throws: DomainRejection.corruptLineage) {
            try planPinnedPlacement(itemID: target, placement: .first, facts: facts)
        }
        #expect(throws: DomainRejection.corruptLineage) {
            try planUnpin(itemID: target, facts: facts)
        }
        #expect(throws: DomainRejection.corruptLineage) {
            try planRemove(itemID: target, facts: RemoveFacts(item: RetainedItemSummary(
                id: target, lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                pinOrdinal: PinOrdinal(rawValue: ordinal)
            ), pinnedCount: count))
        }
    }
    #expect(throws: DomainRejection.corruptLineage) {
        try planPinnedPlacement(itemID: target, placement: .before(pinRevisionItemID(2)), facts: PinFacts(
            targetExists: true, targetOrdinal: nil, anchorOrdinal: PinOrdinal(rawValue: 3), pinnedCount: 3
        ))
    }
    #expect(throws: DomainRejection.capacityExceeded(.retainedItems)) {
        try planPinnedPlacement(itemID: target, placement: .last, facts: PinFacts(
            targetExists: true, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: Int.max
        ))
    }
}
