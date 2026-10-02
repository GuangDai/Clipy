/// Revision-planner invariants: retirement payloads, revision append, draft rejection.
/// Split out of PinRevisionPlannerInvariantTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

/// Test fixtures can start with a complete lineage; product planning keeps
/// only the validated current content and old revision metadata (02 §11).
private func revisionFacts(_ item: PlannerItemFixture) throws -> RevisionFacts {
    RevisionFacts(
        itemID: item.id,
        contentVersion: item.contentVersion,
        canonical: item.canonical,
        current: try item.currentContent(),
        revisions: item.revisions.map { revision in
            RevisionRetentionSummary(
                id: revision.id,
                byteCount: revision.content.representations.reduce(0) { $0 + $1.bytes.count }
            )
        },
        activeRevisionID: item.activeRevisionID
    )
}

@Test func revisionMetadataUsesCurrentContentBeforeRejectingDuplicateCandidate() throws {
    let canonical = try pinRevisionCanonical()
    let current = EffectiveContent(representations: [ContentRepresentation(
        typeIdentifier: "public.utf8-plain-text", bytes: Data("active bytes".utf8)
    )])
    let itemID = pinRevisionItemID(1)
    let activeID = pinRevisionRevisionID(2)
    let duplicateID = pinRevisionRevisionID(1)
    let facts = RevisionFacts(
        itemID: itemID, contentVersion: .initial, canonical: canonical,
        current: current,
        revisions: [
            RevisionRetentionSummary(id: duplicateID, byteCount: 1_000_000),
            RevisionRetentionSummary(id: activeID, byteCount: 12),
        ],
        activeRevisionID: activeID
    )
    let request = RevisionRequest(itemID: itemID, expected: .initial, intent: .revert(to: .canonical))
    let unchanged = try planRevision(
        request: request,
        prepared: PreparedRevision(
            candidateRevisionID: duplicateID,
            createdAt: Date(timeIntervalSinceReferenceDate: 300),
            basedOn: .initial, proposedContent: current
        ),
        facts: facts
    )
    if case .commit = unchanged {
        Issue.record("Equal current content must remain unchanged before duplicate-ID validation")
    }
    #expect(throws: DomainRejection.invalidRevisionDraft) {
        try planRevision(
            request: request,
            prepared: PreparedRevision(
                candidateRevisionID: duplicateID,
                createdAt: Date(timeIntervalSinceReferenceDate: 300),
                basedOn: .initial,
                proposedContent: EffectiveContent(representations: canonical.representations.map(\.content))
            ),
            facts: facts
        )
    }
}

@Test(arguments: [false, true])
func equivalentTypeSpellingsDoNotAppendARevision(_ useDecomposedCanonical: Bool) throws {
    let canonicalType = useDecomposedCanonical ? "e\u{301}" : "\u{e9}"
    let proposedType = useDecomposedCanonical ? "\u{e9}" : "e\u{301}"
    let canonical = try captureCanonical([(canonicalType, "accent", 1), ("f", "other", 2)])
    let item = pinRevisionState(id: pinRevisionItemID(1), canonical: canonical)
    let request = RevisionRequest(
        itemID: item.id, expected: item.contentVersion, intent: .revert(to: .canonical)
    )
    for changed in [false, true] {
        let proposed = try captureCanonical([
            (proposedType, changed ? "changed" : "accent", 1), ("f", "other", 2),
        ])
        let result = try planRevision(
            request: request,
            prepared: PreparedRevision(
                candidateRevisionID: pinRevisionRevisionID(1),
                createdAt: Date(timeIntervalSinceReferenceDate: 200),
                basedOn: item.contentVersion,
                proposedContent: EffectiveContent(representations: proposed.representations.map(\.content))
            ),
            facts: revisionFacts(item)
        )
        switch result {
        case .unchanged:
            #expect(!changed)
        case .commit(let plan):
            #expect(changed)
            #expect(plan.mutations.count == 1)
        }
    }
}

@Test func removingAnUnpinnedItemEmitsOnlyItsCompleteRetirementPayload() throws {
    let target = pinRevisionItemID(1)
    let result = try planRemove(
        itemID: target,
        facts: RemoveFacts(
            item: RetainedItemSummary(
                id: target,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                pinOrdinal: nil
            ),
            pinnedCount: 1
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
        facts: revisionFacts(item)
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
        facts: revisionFacts(item)
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
            facts: revisionFacts(item)
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
            facts: revisionFacts(item)
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
            facts: revisionFacts(item)
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
            facts: revisionFacts(item)
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
                facts: revisionFacts(
                    pinRevisionState(id: itemID, canonical: canonical)
                )
            )
        }
    }
}

@Test func revisionPlannerKeepsEveryPasteboardItemWhileAllowingTypeRemoval() throws {
    func representation(_ item: Int, _ type: String, _ bytes: String) -> ContentRepresentation {
        ContentRepresentation(typeIdentifier: type, bytes: Data(bytes.utf8), pasteboardItemIndex: item)
    }
    let text = "public.utf8-plain-text"
    let originals = [
        representation(0, "public.html", "<p>first</p>"),
        representation(0, text, "first"),
        representation(1, text, "second"),
        representation(2, text, "third")
    ]
    let canonical = try CanonicalContent(representations: originals.map {
        CanonicalRepresentation(content: $0, fingerprint: ContentFingerprint(rawValue: 1))
    })
    let itemID = pinRevisionItemID(1)
    let facts = try revisionFacts(pinRevisionState(id: itemID, canonical: canonical))
    let request = RevisionRequest(itemID: itemID, expected: .initial, intent: .revert(to: .canonical))
    let reduced = Array(originals.dropFirst())
    for proposed in [reduced, Array(reduced.dropFirst()), Array(reduced.dropLast()), [reduced[0], reduced[2]]] {
        let prepared = PreparedRevision(
            candidateRevisionID: pinRevisionRevisionID(1),
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            basedOn: .initial, proposedContent: EffectiveContent(representations: proposed)
        )
        if proposed == reduced {
            guard case .commit(let plan) = try planRevision(request: request, prepared: prepared, facts: facts),
                  let mutation = plan.mutations.first,
                  case .appendRevision(_, let revision, _) = mutation else {
                Issue.record("Removing one format must preserve the ordered pasteboard items")
                continue
            }
            #expect(revision.content.representations == reduced)
        } else {
            #expect(throws: DomainRejection.invalidRevisionDraft) {
                try planRevision(request: request, prepared: prepared, facts: facts)
            }
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
            facts: revisionFacts(
                pinRevisionState(id: itemID, canonical: canonical)
            )
        )
    }
}
