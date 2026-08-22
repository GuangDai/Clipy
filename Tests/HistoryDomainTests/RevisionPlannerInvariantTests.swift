/// Revision-planner invariants: retirement payloads, revision append, draft rejection.
/// Split out of PinRevisionPlannerInvariantTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

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
    let sameContent = EffectiveContent(
        representations: canonical.representations.map(\.content)
    )
    let existingRevisionID = pinRevisionRevisionID(1)
    let item = pinRevisionState(
        id: itemID,
        canonical: canonical,
        contentVersion: ContentVersion(rawValue: 2),
        revisions: [ContentRevision(
            id: existingRevisionID,
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            content: sameContent
        )],
        activeRevisionID: existingRevisionID
    )
    let request = RevisionRequest(
        itemID: itemID,
        expected: item.contentVersion,
        intent: .revert(to: .canonical)
    )
    let samePrepared = PreparedRevision(
        candidateRevisionID: pinRevisionRevisionID(2),
        createdAt: Date(timeIntervalSinceReferenceDate: 200),
        basedOn: item.contentVersion,
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
    let revisionID = pinRevisionRevisionID(3)
    let changedPrepared = PreparedRevision(
        candidateRevisionID: revisionID,
        createdAt: Date(timeIntervalSinceReferenceDate: 300),
        basedOn: item.contentVersion,
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
    let oldRevisionIDs = item.revisions.map(\.id)
    #expect(!oldRevisionIDs.contains(appended.id))
    let resultingRevisionIDs = oldRevisionIDs + [appended.id]
    #expect(resultingRevisionIDs.count == oldRevisionIDs.count + 1)
    let containsDuplicate = resultingRevisionIDs.indices.contains { index in
        resultingRevisionIDs.dropFirst(index + 1).contains(resultingRevisionIDs[index])
    }
    #expect(!containsDuplicate)
}

@Test func revisionPlannerRejectsCandidateIDAlreadyInTheItemLineage() throws {
    let itemID = pinRevisionItemID(1)
    let canonical = try pinRevisionCanonical()
    let duplicateCandidateID = pinRevisionRevisionID(1)
    let inactiveRevision = ContentRevision(
        id: duplicateCandidateID,
        createdAt: Date(timeIntervalSinceReferenceDate: 200),
        content: EffectiveContent(representations: [
            ContentRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("first revision".utf8)
            ),
        ])
    )
    let activeRevisionID = pinRevisionRevisionID(2)
    let activeRevision = ContentRevision(
        id: activeRevisionID,
        createdAt: Date(timeIntervalSinceReferenceDate: 300),
        content: EffectiveContent(representations: [
            ContentRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("second revision".utf8)
            ),
        ])
    )
    let currentVersion = ContentVersion(rawValue: 3)
    let item = pinRevisionState(
        id: itemID,
        canonical: canonical,
        contentVersion: currentVersion,
        revisions: [inactiveRevision, activeRevision],
        activeRevisionID: activeRevisionID
    )
    let request = RevisionRequest(
        itemID: itemID,
        expected: currentVersion,
        intent: .revert(to: .canonical)
    )
    let prepared = PreparedRevision(
        candidateRevisionID: duplicateCandidateID,
        createdAt: Date(timeIntervalSinceReferenceDate: 400),
        basedOn: currentVersion,
        proposedContent: EffectiveContent(representations: [
            ContentRepresentation(
                typeIdentifier: "public.utf8-plain-text",
                bytes: Data("third revision".utf8)
            ),
        ])
    )

    #expect(throws: DomainRejection.invalidRevisionDraft) {
        try planRevision(
            request: request,
            prepared: prepared,
            facts: RevisionFacts(item: item)
        )
    }
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
