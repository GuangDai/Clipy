/// Direct pure-planner proofs for pin/remove/clear/revision invariants D2–D4,
/// D12, D15–D16, and D18 (docs/02-domain.md §10–§11, §14).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

private func pinRevisionItemID(_ suffix: UInt8) -> HistoryItemID {
    HistoryItemID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

private func pinRevisionRevisionID(_ suffix: UInt8) -> RevisionID {
    RevisionID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

private func pinRevisionCanonical(_ bytes: String = "canonical") throws -> CanonicalContent {
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

private func pinRevisionState(
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

@Test func removingAnUnpinnedItemEmitsOnlyItsCompleteRetirementPayload() throws {
    let target = pinRevisionItemID(1)
    let retainedPinned = pinRevisionItemID(2)
    let result = try planRemove(
        itemID: target,
        facts: RemoveFacts(
            item: RetainedItemSummary(
                id: target,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                pinOrdinal: nil
            ),
            pinnedOrder: CompletePinnedOrder(itemIDs: [retainedPinned])
        )
    )

    guard case .commit(let plan) = result,
          case .removed(let count) = plan.outcome,
          count == 1,
          plan.mutations.count == 1,
          case .retire(let retiredID, let reason) = plan.mutations[0]
    else {
        Issue.record("Removing an unpinned item did not emit exactly one retirement")
        return
    }
    #expect(retiredID == target)
    if case .userRemoval = reason {
        // Expected semantic reason.
    } else {
        Issue.record("The unpinned removal carried the wrong retirement reason")
    }
}

@Test func sameEffectiveRevisionIsUnchangedButChangedBytesAppendOneFullRevision() throws {
    let itemID = pinRevisionItemID(1)
    let canonical = try pinRevisionCanonical()
    let item = pinRevisionState(id: itemID, canonical: canonical)
    let request = RevisionRequest(
        itemID: itemID,
        expected: .initial,
        intent: .revert(to: .canonical)
    )
    let sameContent = EffectiveContent(
        representations: canonical.representations.map(\.content)
    )
    let samePrepared = PreparedRevision(
        candidateRevisionID: pinRevisionRevisionID(1),
        createdAt: Date(timeIntervalSinceReferenceDate: 200),
        basedOn: .initial,
        proposedContent: sameContent
    )

    switch try planRevision(
        request: request,
        prepared: samePrepared,
        facts: RevisionFacts(item: item)
    ) {
    case .unchanged:
        break
    case .commit:
        Issue.record("A byte-identical revision produced an append plan")
    }

    let changedContent = EffectiveContent(representations: [
        ContentRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data("changed".utf8)
        ),
    ])
    let revisionID = pinRevisionRevisionID(2)
    let changedPrepared = PreparedRevision(
        candidateRevisionID: revisionID,
        createdAt: Date(timeIntervalSinceReferenceDate: 300),
        basedOn: .initial,
        proposedContent: changedContent
    )
    let changedResult = try planRevision(
        request: request,
        prepared: changedPrepared,
        facts: RevisionFacts(item: item)
    )

    guard case .commit(let plan) = changedResult,
          plan.mutations.count == 1,
          case .appendRevision(
              let revisedItemID,
              let appended,
              let activeRevisionID
          ) = plan.mutations[0]
    else {
        Issue.record("Changed Effective Content did not append one full revision")
        return
    }
    #expect(revisedItemID == itemID)
    #expect(appended.id == revisionID)
    #expect(appended.content == changedContent)
    #expect(activeRevisionID == revisionID)
    #expect(item.canonical == canonical)
}

@Test func revisionPlannerRejectsWrongPreparationBaseAndForeignType() throws {
    let itemID = pinRevisionItemID(1)
    let canonical = try pinRevisionCanonical()
    let item = pinRevisionState(id: itemID, canonical: canonical)
    let request = RevisionRequest(
        itemID: itemID,
        expected: .initial,
        intent: .revert(to: .canonical)
    )
    let validChangedContent = EffectiveContent(representations: [
        ContentRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data("changed".utf8)
        ),
    ])

    #expect(throws: DomainRejection.invalidRevisionDraft) {
        try planRevision(
            request: request,
            prepared: PreparedRevision(
                candidateRevisionID: pinRevisionRevisionID(1),
                createdAt: Date(timeIntervalSinceReferenceDate: 200),
                basedOn: ContentVersion(rawValue: 2),
                proposedContent: validChangedContent
            ),
            facts: RevisionFacts(item: item)
        )
    }
    #expect(throws: DomainRejection.invalidRevisionDraft) {
        try planRevision(
            request: request,
            prepared: PreparedRevision(
                candidateRevisionID: pinRevisionRevisionID(2),
                createdAt: Date(timeIntervalSinceReferenceDate: 200),
                basedOn: .initial,
                proposedContent: EffectiveContent(representations: [
                    ContentRepresentation(
                        typeIdentifier: "public.png",
                        bytes: Data("foreign".utf8)
                    ),
                ])
            ),
            facts: RevisionFacts(item: item)
        )
    }
}

@Test func revisionPlannerRejectsStaleContentBeforeInspectingTheDraft() throws {
    let itemID = pinRevisionItemID(1)
    let canonical = try pinRevisionCanonical()
    let expected = ContentVersion.initial
    let current = ContentVersion(rawValue: 2)
    let item = pinRevisionState(
        id: itemID,
        canonical: canonical,
        contentVersion: current
    )
    let request = RevisionRequest(
        itemID: itemID,
        expected: expected,
        intent: .revert(to: .canonical)
    )
    let prepared = PreparedRevision(
        candidateRevisionID: pinRevisionRevisionID(1),
        createdAt: Date(timeIntervalSinceReferenceDate: 200),
        basedOn: expected,
        proposedContent: EffectiveContent(representations: [])
    )

    #expect(throws: DomainRejection.staleContent(expected: expected, current: current)) {
        try planRevision(
            request: request,
            prepared: prepared,
            facts: RevisionFacts(item: item)
        )
    }
}

@Test func revisionPlannerMapsCorruptCurrentLineageToDomainRejection() throws {
    let itemID = pinRevisionItemID(1)
    let canonical = try pinRevisionCanonical()
    let orphanedRevision = ContentRevision(
        id: pinRevisionRevisionID(1),
        createdAt: Date(timeIntervalSinceReferenceDate: 100),
        content: EffectiveContent(
            representations: canonical.representations.map(\.content)
        )
    )
    let corruptItem = pinRevisionState(
        id: itemID,
        canonical: canonical,
        revisions: [orphanedRevision],
        activeRevisionID: nil
    )
    let request = RevisionRequest(
        itemID: itemID,
        expected: .initial,
        intent: .revert(to: .canonical)
    )
    let prepared = PreparedRevision(
        candidateRevisionID: pinRevisionRevisionID(2),
        createdAt: Date(timeIntervalSinceReferenceDate: 200),
        basedOn: .initial,
        proposedContent: EffectiveContent(representations: [
            ContentRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("changed".utf8)
            ),
        ])
    )

    #expect(throws: DomainRejection.corruptLineage) {
        try planRevision(
            request: request,
            prepared: prepared,
            facts: RevisionFacts(item: corruptItem)
        )
    }
}

@Test func revisionPlannerRejectsEmptyEmptyBytesAndUnsortedContent() throws {
    let html = ContentRepresentation(
        typeIdentifier: "public.html",
        bytes: Data("html".utf8)
    )
    let text = ContentRepresentation(
        typeIdentifier: "public.utf8-plain-text",
        bytes: Data("text".utf8)
    )
    let canonical = try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: html,
            fingerprint: ContentFingerprint(rawValue: 1)
        ),
        CanonicalRepresentation(
            content: text,
            fingerprint: ContentFingerprint(rawValue: 2)
        ),
    ])
    let itemID = pinRevisionItemID(1)
    let request = RevisionRequest(
        itemID: itemID,
        expected: .initial,
        intent: .revert(to: .canonical)
    )
    let invalidContents = [
        EffectiveContent(representations: []),
        EffectiveContent(representations: [
            ContentRepresentation(
                typeIdentifier: html.typeIdentifier,
                bytes: Data()
            ),
        ]),
        EffectiveContent(representations: [text, html]),
    ]

    for (index, invalidContent) in invalidContents.enumerated() {
        #expect(throws: DomainRejection.invalidRevisionDraft) {
            try planRevision(
                request: request,
                prepared: PreparedRevision(
                    candidateRevisionID: pinRevisionRevisionID(UInt8(index + 1)),
                    createdAt: Date(timeIntervalSinceReferenceDate: 200),
                    basedOn: .initial,
                    proposedContent: invalidContent
                ),
                facts: RevisionFacts(
                    item: pinRevisionState(id: itemID, canonical: canonical)
                )
            )
        }
    }
}

@Test func revisionPlannerRejectsNonAdjacentCanonicallyEquivalentTypes() throws {
    let decomposed = "e\u{301}"
    let precomposed = "\u{e9}"
    let between = "f"
    let canonical = try CanonicalContent(representations: [
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: decomposed,
                bytes: Data([0x01])
            ),
            fingerprint: ContentFingerprint(rawValue: 1)
        ),
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: between,
                bytes: Data([0x02])
            ),
            fingerprint: ContentFingerprint(rawValue: 2)
        ),
    ])
    let itemID = pinRevisionItemID(1)
    let request = RevisionRequest(
        itemID: itemID,
        expected: .initial,
        intent: .revert(to: .canonical)
    )
    let prepared = PreparedRevision(
        candidateRevisionID: pinRevisionRevisionID(1),
        createdAt: Date(timeIntervalSinceReferenceDate: 200),
        basedOn: .initial,
        proposedContent: EffectiveContent(representations: [
            ContentRepresentation(
                typeIdentifier: decomposed,
                bytes: Data([0x03])
            ),
            ContentRepresentation(
                typeIdentifier: between,
                bytes: Data([0x04])
            ),
            ContentRepresentation(
                typeIdentifier: precomposed,
                bytes: Data([0x05])
            ),
        ])
    )

    #expect(throws: DomainRejection.invalidRevisionDraft) {
        try planRevision(
            request: request,
            prepared: prepared,
            facts: RevisionFacts(
                item: pinRevisionState(id: itemID, canonical: canonical)
            )
        )
    }
}
