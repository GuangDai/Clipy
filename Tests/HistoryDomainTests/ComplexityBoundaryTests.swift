/// Boundary proofs for the algorithmic-shape decisions that the planners
/// deliberately split across two code paths (docs/02-domain.md §9, §12):
/// the eviction heap/sort quarter-threshold, lane-1 multi-representation
/// byte-set equality, and max-revision-count lineage resolution.
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

private enum ComplexityBoundaryTestError: Error {
    case expectedCommit
    case unexpectedMutation
}

/// Extracts the retirement victim IDs from a retention plan, mirroring the
/// production commit shape: one policy mutation followed by the victims in
/// eviction order.
private func boundaryRetentionVictims(
    inventory: [RetainedItemSummary],
    policy: RetentionPolicy
) throws -> [HistoryItemID] {
    let result = planRetention(
        facts: RetentionFacts(
            inventory: CompleteRetentionInventory(allItems: inventory),
            currentPolicy: RetentionPolicy(maximumUnpinnedItems: 1)
        ),
        policy: policy
    )
    guard case .commit(let plan) = result,
          case .retentionPolicySet(let removedCount) = plan.outcome,
          plan.mutations.count == removedCount + 1
    else {
        throw ComplexityBoundaryTestError.expectedCommit
    }
    return try plan.mutations.dropFirst().map { mutation in
        guard case .retire(let itemID, .retention) = mutation else {
            throw ComplexityBoundaryTestError.unexpectedMutation
        }
        return itemID
    }
}

/// `evictionVictims` (docs/02-domain.md §12) deliberately runs two code
/// paths: a bounded max-heap while victims stay at or under a quarter of
/// the eligible inventory, a full sort above it. With 100 eligible rows,
/// 25 victims (policy 75) rides the heap and 26 (policy 74) the sort; both
/// must produce the identical deterministic eviction order, independent of
/// inventory input order.
@Test func evictionHeapAndSortPathsAgreeAcrossTheQuarterThreshold() throws {
    let inventory: [RetainedItemSummary] = (1...100).map { index in
        RetainedItemSummary(
            id: capturePlannerID(UInt8(index)),
            lastCopiedAt: Date(
                timeIntervalSinceReferenceDate: Double(100 + index)
            ),
            pinOrdinal: nil
        )
    }
    let expectedOldest26 = inventory
        .sorted {
            ($0.lastCopiedAt, $0.id)
                < ($1.lastCopiedAt, $1.id)
        }
        .prefix(26)
        .map(\.id)

    let heapPath = try boundaryRetentionVictims(
        inventory: inventory,
        policy: RetentionPolicy(maximumUnpinnedItems: 75)
    )
    let sortPath = try boundaryRetentionVictims(
        inventory: inventory,
        policy: RetentionPolicy(maximumUnpinnedItems: 74)
    )
    let shuffledPath = try boundaryRetentionVictims(
        inventory: inventory.reversed(),
        policy: RetentionPolicy(maximumUnpinnedItems: 74)
    )

    #expect(heapPath.count == 25)
    #expect(sortPath.count == 26)
    #expect(Array(sortPath.prefix(25)) == heapPath)
    #expect(sortPath == Array(expectedOldest26))
    #expect(shuffledPath == sortPath)
}

/// Lane-1 equality (docs/02-domain.md §9.3.1) must hold for hinted items
/// whose Effective Content carries several representations with
/// non-trivial payloads, and must not depend on fingerprint evidence —
/// the dictionary-keyed comparison consults bytes only.
@Test func lineageHintEqualityHoldsAcrossMultipleLargeRepresentations() throws {
    let largeText = String(repeating: "lineage", count: 512)
    let largeRTF = String(repeating: "{\\rtf}", count: 512)
    let largeHTML = String(repeating: "<p>", count: 512)
    let activeRevisionID = capturePlannerRevisionID(9)
    let effectiveRevisions: [(typeIdentifier: String, bytes: String)] = [
        ("public.html", largeHTML),
        ("public.rtf", largeRTF),
        ("public.utf8-plain-text", largeText),
    ]
    // Same content pairs, deliberately different fingerprint evidence: the
    // fingerprints are hints, never identity (D7).
    let effectiveCanonical = try captureCanonical(
        effectiveRevisions.map {
            (typeIdentifier: $0.typeIdentifier, bytes: $0.bytes, fingerprint: 1)
        }
    )
    let incomingCanonical = try captureCanonical(
        effectiveRevisions.map {
            (typeIdentifier: $0.typeIdentifier, bytes: $0.bytes, fingerprint: 2)
        }
    )
    let activeRevision = ContentRevision(
        id: activeRevisionID,
        createdAt: Date(timeIntervalSinceReferenceDate: 50),
        content: EffectiveContent(
            representations: effectiveCanonical.representations.map(\.content)
        )
    )
    let hinted = captureItem(
        id: capturePlannerID(1),
        canonical: try captureCanonical([
            ("public.utf8-plain-text", "older-canonical", 3),
        ]),
        lastCopiedAt: 100,
        revisions: [activeRevision],
        activeRevisionID: activeRevisionID
    )

    let result = try planCapture(
        preparedCapture(
            canonical: incomingCanonical,
            observedAt: 200,
            hint: hinted.id
        ),
        facts: captureFacts(
            hintedItem: hinted,
            candidates: [],
            retained: [hinted]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10),
        hardMaximumRetainedItems: 10
    )

    guard case .commit(let plan) = result,
          case .coalesced(let winnerID) = plan.outcome,
          winnerID == hinted.id
    else {
        Issue.record(
            "A multi-representation byte-equal lineage hint did not coalesce"
        )
        return
    }
}

/// The same multi-representation shape with ONE differing representation
/// must refuse the lineage lane: byte-set equality is all-or-nothing
/// (docs/02-domain.md §9.3.1).
@Test func lineageHintWithOneDifferingRepresentationFallsThrough() throws {
    let largeText = String(repeating: "lineage", count: 512)
    let differingText = String(repeating: "mutated", count: 512)
    let activeRevisionID = capturePlannerRevisionID(9)
    let effectiveCanonical = try captureCanonical([
        ("public.rtf", String(repeating: "{\\rtf}", count: 512), 1),
        ("public.utf8-plain-text", largeText, 2),
    ])
    let incomingCanonical = try captureCanonical([
        ("public.rtf", String(repeating: "{\\rtf}", count: 512), 1),
        ("public.utf8-plain-text", differingText, 2),
    ])
    let activeRevision = ContentRevision(
        id: activeRevisionID,
        createdAt: Date(timeIntervalSinceReferenceDate: 50),
        content: EffectiveContent(
            representations: effectiveCanonical.representations.map(\.content)
        )
    )
    let hinted = captureItem(
        id: capturePlannerID(1),
        canonical: effectiveCanonical,
        lastCopiedAt: 100,
        revisions: [activeRevision],
        activeRevisionID: activeRevisionID
    )

    let result = try planCapture(
        preparedCapture(
            canonical: incomingCanonical,
            observedAt: 200,
            hint: hinted.id
        ),
        facts: captureFacts(
            hintedItem: hinted,
            candidates: [],
            retained: [hinted]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10),
        hardMaximumRetainedItems: 10
    )

    guard case .commit(let plan) = result,
          case .inserted(let insertedID) = plan.outcome,
          insertedID != hinted.id
    else {
        Issue.record("A one-representation-different hint incorrectly coalesced")
        return
    }
}

/// `effectiveContent` (docs/02-domain.md §6) resolves one active revision
/// among the Part VI maximum of 100 in a single linear walk, and still
/// detects a duplicated active ID at that depth.
@Test func effectiveContentResolvesAndRejectsAtTheHundredRevisionBound() throws {
    let canonical = try captureCanonical([
        ("public.utf8-plain-text", "canonical", 1),
    ])
    let revision = { (index: Int) in
        ContentRevision(
            id: capturePlannerRevisionID(UInt8(index)),
            createdAt: Date(timeIntervalSinceReferenceDate: Double(index)),
            content: EffectiveContent(
                representations: [
                    ContentRepresentation(
                        typeIdentifier: "public.utf8-plain-text",
                        bytes: Data("revision-\(index)".utf8)
                    ),
                ]
            )
        )
    }
    // Distinct revisions 1…99, then a 100th entry that reuses revision 1's
    // ID: resolving active ID 1 must see the duplicate and reject.
    var revisions: [ContentRevision] = (1...99).map(revision)
    let duplicateOfFirst = ContentRevision(
        id: capturePlannerRevisionID(1),
        createdAt: Date(timeIntervalSinceReferenceDate: 200),
        content: EffectiveContent(
            representations: [
                ContentRepresentation(
                    typeIdentifier: "public.utf8-plain-text",
                    bytes: Data("duplicate".utf8)
                ),
            ]
        )
    )
    let resolving = captureItem(
        id: capturePlannerID(1),
        canonical: canonical,
        lastCopiedAt: 100,
        revisions: (1...100).map(revision),
        activeRevisionID: capturePlannerRevisionID(100)
    )
    let resolved = try effectiveContent(of: resolving)
    #expect(
        resolved.representations.first?.bytes
            == Data("revision-100".utf8)
    )

    revisions.append(duplicateOfFirst)
    let rejecting = captureItem(
        id: capturePlannerID(2),
        canonical: canonical,
        lastCopiedAt: 100,
        revisions: revisions,
        activeRevisionID: capturePlannerRevisionID(1)
    )
    do {
        _ = try effectiveContent(of: rejecting)
        Issue.record("A duplicated active revision at full depth was accepted")
    } catch let error as DomainRejection {
        guard case .corruptLineage = error else {
            Issue.record("Unexpected rejection \(error)")
            return
        }
    }
}
