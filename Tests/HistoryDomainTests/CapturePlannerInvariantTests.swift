/// Direct pure-planner proofs for capture invariants D1, D3, D7, D9–D11,
/// D13–D14, D16, and D18–D19 (docs/02-domain.md §9, §12, §14).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

private enum CapturePlannerTestError: Error {
    case expectedCommit
    case expectedCoalescedOutcome
}

private func capturePlannerID(_ suffix: UInt8) -> HistoryItemID {
    HistoryItemID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

private func capturePlannerRevisionID(_ suffix: UInt8) -> RevisionID {
    RevisionID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

private func captureCanonical(
    _ values: [(typeIdentifier: String, bytes: String, fingerprint: UInt64)]
) throws -> CanonicalContent {
    let sorted = values.sorted { lhs, rhs in
        lhs.typeIdentifier.unicodeScalars.lexicographicallyPrecedes(
            rhs.typeIdentifier.unicodeScalars
        )
    }
    return try CanonicalContent(representations: sorted.map { value in
        CanonicalRepresentation(
            content: ContentRepresentation(
                typeIdentifier: value.typeIdentifier,
                bytes: Data(value.bytes.utf8)
            ),
            fingerprint: ContentFingerprint(rawValue: value.fingerprint)
        )
    })
}

private func captureItem(
    id: HistoryItemID,
    canonical: CanonicalContent,
    lastCopiedAt: TimeInterval,
    count: UInt64 = 1,
    lastSource: String? = "existing.source",
    revisions: [ContentRevision] = [],
    activeRevisionID: RevisionID? = nil,
    pinOrdinal: PinOrdinal? = nil
) -> HistoryItemState {
    HistoryItemState(
        id: id,
        contentVersion: .initial,
        canonical: canonical,
        revisions: revisions,
        activeRevisionID: activeRevisionID,
        occurrence: CopyOccurrence(
            firstCopiedAt: Date(timeIntervalSinceReferenceDate: 0),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: lastCopiedAt),
            count: count,
            firstSource: "first.source",
            lastSource: lastSource
        ),
        pinOrdinal: pinOrdinal
    )
}

private func captureSummary(_ item: HistoryItemState) -> RetainedItemSummary {
    RetainedItemSummary(
        id: item.id,
        lastCopiedAt: item.occurrence.lastCopiedAt,
        pinOrdinal: item.pinOrdinal
    )
}

private func preparedCapture(
    canonical: CanonicalContent,
    observedAt: TimeInterval,
    candidateID: HistoryItemID = capturePlannerID(250),
    hint: HistoryItemID? = nil,
    source: String? = "incoming.source"
) -> PreparedCapture {
    PreparedCapture(
        candidateID: candidateID,
        canonical: canonical,
        origin: CopyOrigin(
            lineageHint: hint,
            sourceApplication: source
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: observedAt)
    )
}

private func captureFacts(
    hintedItem: HistoryItemState? = nil,
    candidates: [HistoryItemState],
    retained: [HistoryItemState]? = nil,
    additionalSummaries: [RetainedItemSummary] = []
) -> IngestFacts {
    let retainedItems = retained ?? candidates
    return IngestFacts(
        hintedItem: hintedItem,
        candidates: CompleteDedupCandidates(items: candidates),
        retention: CompleteRetentionInventory(
            allItems: retainedItems.map(captureSummary) + additionalSummaries
        )
    )
}

private func capturePlan(
    incoming: CanonicalContent,
    candidates: [HistoryItemState],
    observedAt: TimeInterval = 500
) throws -> MutationPlan {
    let result = try planCapture(
        preparedCapture(canonical: incoming, observedAt: observedAt),
        facts: captureFacts(candidates: candidates),
        retention: RetentionPolicy(maximumUnpinnedItems: 100),
        hardMaximumRetainedItems: 100
    )
    guard case .commit(let plan) = result else {
        throw CapturePlannerTestError.expectedCommit
    }
    return plan
}

private func coalescedWinner(
    incoming: CanonicalContent,
    candidates: [HistoryItemState]
) throws -> HistoryItemID {
    let plan = try capturePlan(incoming: incoming, candidates: candidates)
    guard case .coalesced(let winnerID) = plan.outcome else {
        throw CapturePlannerTestError.expectedCoalescedOutcome
    }
    return winnerID
}

@Test func canonicalContentRejectsNonAdjacentCanonicallyEquivalentTypes() {
    let decomposed = "e\u{301}"
    let precomposed = "\u{e9}"

    #expect(
        throws: CanonicalContentRejection.duplicateTypeIdentifier(precomposed)
    ) {
        try CanonicalContent(representations: [
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: decomposed,
                    bytes: Data([0x01])
                ),
                fingerprint: ContentFingerprint(rawValue: 1)
            ),
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: "f",
                    bytes: Data([0x02])
                ),
                fingerprint: ContentFingerprint(rawValue: 2)
            ),
            CanonicalRepresentation(
                content: ContentRepresentation(
                    typeIdentifier: precomposed,
                    bytes: Data([0x03])
                ),
                fingerprint: ContentFingerprint(rawValue: 3)
            ),
        ])
    }
}

@Test func canonicalContainmentRequiresEveryIncomingTypeAndBytePair() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let richExisting = try captureCanonical([
        ("public.html", "html", 2),
        ("public.utf8-plain-text", "text", 99),
    ])
    let sameSignatureDifferentBytes = try captureCanonical([
        ("public.utf8-plain-text", "different", 1),
    ])

    #expect(canonicalContains(existing: richExisting, incoming: incoming))
    #expect(!canonicalContains(existing: incoming, incoming: richExisting))
    #expect(!canonicalContains(
        existing: sameSignatureDifferentBytes,
        incoming: incoming
    ))
}

@Test func fingerprintCollisionWithoutEqualBytesInsertsInsteadOfCoalescing() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "incoming", 42),
    ])
    let colliding = try captureCanonical([
        ("public.utf8-plain-text", "different", 42),
    ])
    let existing = captureItem(
        id: capturePlannerID(1),
        canonical: colliding,
        lastCopiedAt: 100
    )
    let candidateID = capturePlannerID(200)
    let result = try planCapture(
        preparedCapture(
            canonical: incoming,
            observedAt: 200,
            candidateID: candidateID
        ),
        facts: captureFacts(candidates: [existing]),
        retention: RetentionPolicy(maximumUnpinnedItems: 10),
        hardMaximumRetainedItems: 10
    )

    guard case .commit(let plan) = result,
          case .inserted(let insertedID) = plan.outcome,
          plan.mutations.count == 1,
          case .create(let created) = plan.mutations[0]
    else {
        Issue.record("A fingerprint-only collision did not produce one create plan")
        return
    }
    #expect(insertedID == candidateID)
    #expect(created.id == candidateID)
}

@Test func insertionCarriesTheCompleteInitialOccurrencePayload() throws {
    let canonical = try captureCanonical([
        ("public.utf8-plain-text", "new item", 1),
    ])
    let candidateID = capturePlannerID(200)
    let observedAt = Date(timeIntervalSinceReferenceDate: 321)
    let result = try planCapture(
        PreparedCapture(
            candidateID: candidateID,
            canonical: canonical,
            origin: CopyOrigin(
                lineageHint: nil,
                sourceApplication: "incoming.source"
            ),
            observedAt: observedAt
        ),
        facts: captureFacts(candidates: [], retained: []),
        retention: RetentionPolicy(maximumUnpinnedItems: 1),
        hardMaximumRetainedItems: 1
    )

    guard case .commit(let plan) = result,
          case .inserted(let insertedID) = plan.outcome,
          plan.mutations.count == 1,
          case .create(let created) = plan.mutations[0]
    else {
        Issue.record("A valid first capture did not produce one complete create mutation")
        return
    }
    #expect(insertedID == candidateID)
    #expect(created.id == candidateID)
    #expect(created.canonical == canonical)
    #expect(created.occurrence.firstCopiedAt == observedAt)
    #expect(created.occurrence.lastCopiedAt == observedAt)
    #expect(created.occurrence.count == 1)
    #expect(created.occurrence.firstSource == "incoming.source")
    #expect(created.occurrence.lastSource == "incoming.source")
}

@Test func byteEqualLineageHintWinsBeforeCanonicalCandidates() throws {
    let original = try captureCanonical([
        ("public.utf8-plain-text", "original", 1),
    ])
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "revised", 2),
    ])
    let activeRevisionID = capturePlannerRevisionID(1)
    let activeRevision = ContentRevision(
        id: activeRevisionID,
        createdAt: Date(timeIntervalSinceReferenceDate: 50),
        content: EffectiveContent(
            representations: incoming.representations.map(\.content)
        )
    )
    let hinted = captureItem(
        id: capturePlannerID(1),
        canonical: original,
        lastCopiedAt: 100,
        revisions: [activeRevision],
        activeRevisionID: activeRevisionID
    )
    let canonicalCandidate = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 900
    )
    let result = try planCapture(
        preparedCapture(
            canonical: incoming,
            observedAt: 200,
            hint: hinted.id
        ),
        facts: captureFacts(
            hintedItem: hinted,
            candidates: [canonicalCandidate],
            retained: [hinted, canonicalCandidate]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10),
        hardMaximumRetainedItems: 10
    )

    guard case .commit(let plan) = result,
          case .coalesced(let winnerID) = plan.outcome,
          plan.mutations.count == 1,
          case .recordCopy(let mutatedID, _) = plan.mutations[0]
    else {
        Issue.record("A byte-equal lineage hint did not produce a coalesce plan")
        return
    }
    #expect(winnerID == hinted.id)
    #expect(mutatedID == hinted.id)
    #expect(mutatedID != canonicalCandidate.id)
}

@Test func mismatchedLineageHintFallsThroughToByteConfirmedCandidates() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "incoming", 1),
    ])
    let hinted = captureItem(
        id: capturePlannerID(1),
        canonical: try captureCanonical([
            ("public.utf8-plain-text", "different", 2),
        ]),
        lastCopiedAt: 900
    )
    let confirmed = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 100
    )
    let result = try planCapture(
        preparedCapture(
            canonical: incoming,
            observedAt: 200,
            hint: hinted.id
        ),
        facts: captureFacts(
            hintedItem: hinted,
            candidates: [confirmed],
            retained: [hinted, confirmed]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10),
        hardMaximumRetainedItems: 10
    )

    guard case .commit(let plan) = result,
          case .coalesced(let winnerID) = plan.outcome,
          plan.mutations.count == 1,
          case .recordCopy(let mutatedID, _) = plan.mutations[0]
    else {
        Issue.record("A mismatched hint did not fall through to byte confirmation")
        return
    }
    #expect(winnerID == confirmed.id)
    #expect(mutatedID == confirmed.id)
    #expect(mutatedID != hinted.id)
}

@Test func corruptHintedLineageIsRejectedBeforeCanonicalFallback() throws {
    let canonical = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let revision = ContentRevision(
        id: capturePlannerRevisionID(1),
        createdAt: Date(timeIntervalSinceReferenceDate: 50),
        content: EffectiveContent(
            representations: canonical.representations.map(\.content)
        )
    )
    let corruptHint = captureItem(
        id: capturePlannerID(1),
        canonical: canonical,
        lastCopiedAt: 100,
        revisions: [revision],
        activeRevisionID: nil
    )

    #expect(throws: DomainRejection.corruptLineage) {
        try planCapture(
            preparedCapture(
                canonical: canonical,
                observedAt: 200,
                hint: corruptHint.id
            ),
            facts: captureFacts(
                hintedItem: corruptHint,
                candidates: [],
                retained: [corruptHint]
            ),
            retention: RetentionPolicy(maximumUnpinnedItems: 10),
            hardMaximumRetainedItems: 10
        )
    }
}

@Test func exactCanonicalCandidateBeatsNewerSuperset() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let superset = try captureCanonical([
        ("public.html", "html", 2),
        ("public.utf8-plain-text", "text", 1),
    ])
    let exactItem = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 100
    )
    let newerSuperset = captureItem(
        id: capturePlannerID(1),
        canonical: superset,
        lastCopiedAt: 900
    )

    #expect(
        try coalescedWinner(
            incoming: incoming,
            candidates: [newerSuperset, exactItem]
        ) == exactItem.id
    )
}

@Test func fewerCanonicalExtrasBeatRecency() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let oneExtra = try captureCanonical([
        ("public.html", "html", 2),
        ("public.utf8-plain-text", "text", 1),
    ])
    let twoExtras = try captureCanonical([
        ("public.html", "html", 2),
        ("public.png", "png", 3),
        ("public.utf8-plain-text", "text", 1),
    ])
    let smaller = captureItem(
        id: capturePlannerID(2),
        canonical: oneExtra,
        lastCopiedAt: 100
    )
    let newerLarger = captureItem(
        id: capturePlannerID(1),
        canonical: twoExtras,
        lastCopiedAt: 900
    )

    #expect(
        try coalescedWinner(
            incoming: incoming,
            candidates: [newerLarger, smaller]
        ) == smaller.id
    )
}

@Test func recencyBreaksEqualCanonicalRank() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let older = captureItem(
        id: capturePlannerID(1),
        canonical: incoming,
        lastCopiedAt: 100
    )
    let newer = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 200
    )

    #expect(
        try coalescedWinner(
            incoming: incoming,
            candidates: [newer, older]
        ) == newer.id
    )
}

@Test func smallestIDIsFinalWinnerTieBreakerIndependentOfInputOrder() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let smaller = captureItem(
        id: capturePlannerID(1),
        canonical: incoming,
        lastCopiedAt: 100
    )
    let larger = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 100
    )

    #expect(
        try coalescedWinner(
            incoming: incoming,
            candidates: [larger, smaller]
        ) == smaller.id
    )
    #expect(
        try coalescedWinner(
            incoming: incoming,
            candidates: [smaller, larger]
        ) == smaller.id
    )
}

@Test func coalescingPreservesWinnerAndDoesNotMutateLoser() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let winner = captureItem(
        id: capturePlannerID(1),
        canonical: incoming,
        lastCopiedAt: 200,
        count: 4
    )
    let loser = captureItem(
        id: capturePlannerID(2),
        canonical: incoming,
        lastCopiedAt: 100,
        count: 9
    )
    let plan = try capturePlan(
        incoming: incoming,
        candidates: [loser, winner],
        observedAt: 300
    )

    guard case .coalesced(let winnerID) = plan.outcome,
          plan.mutations.count == 1,
          case .recordCopy(let mutatedID, let occurrence) = plan.mutations[0]
    else {
        Issue.record("Coalescing did not produce exactly one recordCopy mutation")
        return
    }
    #expect(winnerID == winner.id)
    #expect(mutatedID == winner.id)
    #expect(occurrence.count == 5)
    #expect(mutatedID != loser.id)
}

@Test func outOfOrderCoalescingPreservesRecencyAndSourceWhileIncrementingCount() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let winner = captureItem(
        id: capturePlannerID(1),
        canonical: incoming,
        lastCopiedAt: 300,
        count: 7,
        lastSource: "newer.source"
    )
    let result = try planCapture(
        preparedCapture(
            canonical: incoming,
            observedAt: 200,
            source: "older.source"
        ),
        facts: captureFacts(candidates: [winner]),
        retention: RetentionPolicy(maximumUnpinnedItems: 10),
        hardMaximumRetainedItems: 10
    )

    guard case .commit(let plan) = result,
          !plan.mutations.isEmpty,
          case .recordCopy(_, let occurrence) = plan.mutations[0]
    else {
        Issue.record("Out-of-order coalescing did not record a copy")
        return
    }
    #expect(occurrence.lastCopiedAt == winner.occurrence.lastCopiedAt)
    #expect(occurrence.lastSource == "newer.source")
    #expect(occurrence.count == 8)
}

@Test func copyCountOverflowFailsClosed() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let saturated = captureItem(
        id: capturePlannerID(1),
        canonical: incoming,
        lastCopiedAt: 100,
        count: UInt64.max
    )

    #expect(throws: DomainRejection.capacityExceeded(.copyCount)) {
        try planCapture(
            preparedCapture(canonical: incoming, observedAt: 200),
            facts: captureFacts(candidates: [saturated]),
            retention: RetentionPolicy(maximumUnpinnedItems: 10),
            hardMaximumRetainedItems: 10
        )
    }
}

@Test func hardCapacityUsesOnlyEligibleVictimsAndFailsWhenNoneExist() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "incoming", 1),
    ])
    let retainedCanonical = try captureCanonical([
        ("public.png", "retained", 2),
    ])
    let eligible = captureItem(
        id: capturePlannerID(1),
        canonical: retainedCanonical,
        lastCopiedAt: 100
    )
    let candidateID = capturePlannerID(200)
    let boundaryResult = try planCapture(
        preparedCapture(
            canonical: incoming,
            observedAt: 200,
            candidateID: candidateID
        ),
        facts: captureFacts(candidates: [], retained: [eligible]),
        retention: RetentionPolicy(maximumUnpinnedItems: 1),
        hardMaximumRetainedItems: 1
    )

    guard case .commit(let boundaryPlan) = boundaryResult,
          boundaryPlan.mutations.count == 2,
          case .create(let created) = boundaryPlan.mutations[0],
          case .retire(let victimID, let reason) = boundaryPlan.mutations[1]
    else {
        Issue.record("The just-satisfiable hard-cap boundary did not insert and retire")
        return
    }
    #expect(created.id == candidateID)
    #expect(victimID == eligible.id)
    #expect(victimID != candidateID)
    if case .retention = reason {
        // Expected semantic reason.
    } else {
        Issue.record("The hard-cap victim carried the wrong retirement reason")
    }

    let pinned = captureItem(
        id: capturePlannerID(2),
        canonical: retainedCanonical,
        lastCopiedAt: 1,
        pinOrdinal: PinOrdinal(rawValue: 0)
    )
    #expect(throws: DomainRejection.capacityExceeded(.retainedItems)) {
        try planCapture(
            preparedCapture(
                canonical: incoming,
                observedAt: 200,
                candidateID: candidateID
            ),
            facts: captureFacts(candidates: [], retained: [pinned]),
            retention: RetentionPolicy(maximumUnpinnedItems: 1),
            hardMaximumRetainedItems: 1
        )
    }
}

@Test func coalescingAtTheHardCapacityDoesNotRequireARetirement() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "incoming", 1),
    ])
    let winner = captureItem(
        id: capturePlannerID(1),
        canonical: incoming,
        lastCopiedAt: 100
    )
    let result = try planCapture(
        preparedCapture(canonical: incoming, observedAt: 200),
        facts: captureFacts(candidates: [winner], retained: [winner]),
        retention: RetentionPolicy(maximumUnpinnedItems: 1),
        hardMaximumRetainedItems: 1
    )

    guard case .commit(let plan) = result,
          case .coalesced(let winnerID) = plan.outcome,
          plan.mutations.count == 1,
          case .recordCopy(let mutatedID, _) = plan.mutations[0]
    else {
        Issue.record("A coalesce at the hard bound unexpectedly required retention")
        return
    }
    #expect(winnerID == winner.id)
    #expect(mutatedID == winner.id)
}

@Test func projectedCoalesceRecencySelectsTheNextOldestUnpinnedVictim() throws {
    let incoming = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let primary = captureItem(
        id: capturePlannerID(1),
        canonical: incoming,
        lastCopiedAt: 100
    )
    let nextOldest = captureItem(
        id: capturePlannerID(2),
        canonical: try captureCanonical([("public.png", "png", 2)]),
        lastCopiedAt: 200
    )
    let newest = captureItem(
        id: capturePlannerID(3),
        canonical: try captureCanonical([("public.html", "html", 3)]),
        lastCopiedAt: 300
    )
    let pinnedOldest = captureItem(
        id: capturePlannerID(4),
        canonical: try captureCanonical([("public.rtf", "rtf", 4)]),
        lastCopiedAt: 1,
        pinOrdinal: PinOrdinal(rawValue: 0)
    )
    let result = try planCapture(
        preparedCapture(canonical: incoming, observedAt: 400),
        facts: captureFacts(
            candidates: [primary],
            retained: [primary, nextOldest, newest, pinnedOldest]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 2),
        hardMaximumRetainedItems: 10
    )

    guard case .commit(let plan) = result,
          plan.mutations.count == 2,
          case .recordCopy(let primaryID, _) = plan.mutations[0],
          case .retire(let victimID, let reason) = plan.mutations[1]
    else {
        Issue.record("Projected retention did not produce copy + one retirement")
        return
    }
    #expect(primaryID == primary.id)
    #expect(victimID == nextOldest.id)
    if case .retention = reason {
        // Expected semantic reason.
    } else {
        Issue.record("The projected victim was not retired for retention")
    }
    #expect(victimID != pinnedOldest.id)
    #expect(victimID != primary.id)
}

@Test func effectiveContentRejectsEveryCorruptActiveLineageShape() throws {
    let canonical = try captureCanonical([
        ("public.utf8-plain-text", "text", 1),
    ])
    let activeID = capturePlannerRevisionID(1)
    let missingID = capturePlannerRevisionID(2)
    let revision = ContentRevision(
        id: activeID,
        createdAt: Date(timeIntervalSinceReferenceDate: 100),
        content: EffectiveContent(representations: canonical.representations.map(\.content))
    )
    let corruptItems = [
        captureItem(
            id: capturePlannerID(1),
            canonical: canonical,
            lastCopiedAt: 100,
            revisions: [revision],
            activeRevisionID: nil
        ),
        captureItem(
            id: capturePlannerID(2),
            canonical: canonical,
            lastCopiedAt: 100,
            revisions: [revision],
            activeRevisionID: missingID
        ),
        captureItem(
            id: capturePlannerID(3),
            canonical: canonical,
            lastCopiedAt: 100,
            revisions: [revision, revision],
            activeRevisionID: activeID
        ),
    ]

    for item in corruptItems {
        #expect(throws: DomainRejection.corruptLineage) {
            try effectiveContent(of: item)
        }
    }
}
