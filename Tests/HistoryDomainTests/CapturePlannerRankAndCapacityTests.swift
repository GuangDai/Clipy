/// Capture-planner ranking, tie-breaking, and hard-capacity invariants.
/// Split out of CapturePlannerInvariantTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

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
