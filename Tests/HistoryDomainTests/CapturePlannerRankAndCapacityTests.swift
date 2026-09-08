/// Capture-planner ranking, tie-breaking, and count-retention invariants.
/// Split out of CapturePlannerInvariantTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

@Test(arguments: [false, true])
func equivalentTypeSpellingsKeepExactCanonicalRank(_ useDecomposedIncoming: Bool) throws {
    // §2.1: these spellings are equal Strings but straddle "f" in scalar
    // order. Both canonical arrays are normalized and describe the same set.
    let incomingType = useDecomposedIncoming ? "e\u{301}" : "\u{e9}"
    let candidateType = useDecomposedIncoming ? "\u{e9}" : "e\u{301}"
    let incoming = try captureCanonical([(incomingType, "accent", 1), ("f", "other", 2)])
    let equivalent = try captureCanonical([(candidateType, "accent", 1), ("f", "other", 2)])
    let sameSpelling = captureItem(
        id: capturePlannerID(2), canonical: incoming, lastCopiedAt: 100
    )
    // An exact set match must reach the recency and ID tie-breaks regardless
    // of identifier spelling, input order, or the normalized array order.
    for lastCopiedAt in [100.0, 200.0] {
        let expected = captureItem(
            id: capturePlannerID(1), canonical: equivalent, lastCopiedAt: lastCopiedAt
        )
        for candidates in [[sameSpelling, expected], [expected, sameSpelling]] {
            #expect(try coalescedWinner(incoming: incoming, candidates: candidates) == expected.id)
        }
    }
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
        facts: captureFacts(incoming: incoming, candidates: [winner]),
        retention: RetentionPolicy(maximumUnpinnedItems: 10)
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
            facts: captureFacts(incoming: incoming, candidates: [saturated]),
            retention: RetentionPolicy(maximumUnpinnedItems: 10)
        )
    }
}

@Test func countPolicyRetiresOnlyEligibleItemsAndPreservesPinnedItems() throws {
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
        facts: captureFacts(incoming: incoming, candidates: [], retained: [eligible],
            candidateID: candidateID, maximumUnpinnedItems: 1),
        retention: RetentionPolicy(maximumUnpinnedItems: 1)
    )

    guard case .commit(let boundaryPlan) = boundaryResult,
          boundaryPlan.mutations.count == 2,
          case .create(let created) = boundaryPlan.mutations[0],
          case .retirePrefix(let prefix) = boundaryPlan.mutations[1]
    else {
        Issue.record("The enabled count policy did not insert and retire")
        return
    }
    #expect(created.id == candidateID)
    #expect(prefix.through.itemID == eligible.id)
    #expect(prefix.through.itemID != candidateID)
    #expect(prefix.itemCount == 1)

    let pinned = captureItem(
        id: capturePlannerID(2),
        canonical: retainedCanonical,
        lastCopiedAt: 1,
        pinOrdinal: PinOrdinal(rawValue: 0)
    )
    let pinnedResult = try planCapture(
        preparedCapture(canonical: incoming, observedAt: 200, candidateID: candidateID),
        facts: captureFacts(incoming: incoming, candidates: [], retained: [pinned],
            candidateID: candidateID, maximumUnpinnedItems: 1),
        retention: RetentionPolicy(maximumUnpinnedItems: 1)
    )
    guard case .commit(let pinnedPlan) = pinnedResult,
          pinnedPlan.mutations.count == 1,
          case .create(let inserted) = pinnedPlan.mutations[0] else {
        Issue.record("Pinned items must not prevent inserting the first unpinned item")
        return
    }
    #expect(inserted.id == candidateID)
    #expect(inserted.id != pinned.id)
}

@Test func coalescingAtTheCountPolicyDoesNotRequireARetirement() throws {
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
        facts: captureFacts(incoming: incoming, candidates: [winner], retained: [winner]),
        retention: RetentionPolicy(maximumUnpinnedItems: 1)
    )

    guard case .commit(let plan) = result,
          case .coalesced(let winnerID) = plan.outcome,
          plan.mutations.count == 1,
          case .recordCopy(let mutatedID, _) = plan.mutations[0]
    else {
        Issue.record("A coalesce at the count policy unexpectedly required retention")
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
            incoming: incoming,
            candidates: [primary],
            retained: [primary, nextOldest, newest, pinnedOldest],
            maximumUnpinnedItems: 2
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 2)
    )

    guard case .commit(let plan) = result,
          plan.mutations.count == 2,
          case .recordCopy(let primaryID, _) = plan.mutations[0],
          case .retirePrefix(let prefix) = plan.mutations[1]
    else {
        Issue.record("Projected retention did not produce copy + one retirement")
        return
    }
    #expect(primaryID == primary.id)
    #expect(prefix.through.itemID == nextOldest.id)
    #expect(prefix.itemCount == 1)
    #expect(prefix.through.itemID != pinnedOldest.id)
    #expect(prefix.through.itemID != primary.id)
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
