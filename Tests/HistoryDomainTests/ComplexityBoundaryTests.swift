/// Constant-size retention planning, lane-1 byte equality, and bounded
/// revision lineage resolution (02 §9, §12).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

/// Only scalar count/ordinal facts represent these large lanes. There is no
/// fixture array of pinned IDs and no per-item mutation list to expand.
@Test(arguments: [100_000, 1_000_000])
func largePinnedCountStillProducesConstantSizeRelocations(pinnedCount: Int) throws {
    let target = pinRevisionItemID(1)
    let insertion = try planPinnedPlacement(itemID: target, placement: .first, facts: PinFacts(
        targetExists: true, targetOrdinal: nil, anchorOrdinal: nil, pinnedCount: pinnedCount
    ))
    guard case .commit(let insertPlan) = insertion, insertPlan.mutations.count == 1,
          case .relocatePin(let inserted) = insertPlan.mutations[0] else {
        Issue.record("A large first pin must remain one interval relocation")
        return
    }
    #expect(inserted.itemID == target)
    #expect(inserted.previousOrdinal == nil)
    #expect(inserted.destinationOrdinal?.rawValue == 0)
    #expect(inserted.pinnedCountBefore == pinnedCount)
    #expect(inserted.shift?.range == 0...(pinnedCount - 1))
    #expect(inserted.shift?.delta == 1)

    let firstFacts = PinFacts(targetExists: true, targetOrdinal: PinOrdinal(rawValue: 0),
        anchorOrdinal: nil, pinnedCount: pinnedCount)
    let reordered = try planPinnedPlacement(itemID: target, placement: .last, facts: firstFacts)
    guard case .commit(let reorderPlan) = reordered, reorderPlan.mutations.count == 1,
          case .relocatePin(let moved) = reorderPlan.mutations[0] else {
        Issue.record("Moving across a large pinned lane must remain one relocation")
        return
    }
    #expect(moved.itemID == target)
    #expect(moved.previousOrdinal?.rawValue == 0)
    #expect(moved.destinationOrdinal?.rawValue == pinnedCount - 1)
    #expect(moved.pinnedCountBefore == pinnedCount)
    #expect(moved.shift?.range == 1...(pinnedCount - 1))
    #expect(moved.shift?.delta == -1)

    let unpinned = try planUnpin(itemID: target, facts: firstFacts)
    guard case .commit(let unpinPlan) = unpinned, unpinPlan.mutations.count == 1,
          case .relocatePin(let unpin) = unpinPlan.mutations[0] else {
        Issue.record("Unpinning a large lane must remain one relocation")
        return
    }
    #expect(unpin.itemID == target)
    #expect(unpin.previousOrdinal?.rawValue == 0)
    #expect(unpin.destinationOrdinal == nil)
    #expect(unpin.pinnedCountBefore == pinnedCount)
    #expect(unpin.shift?.range == 1...(pinnedCount - 1))
    #expect(unpin.shift?.delta == -1)

    let removed = try planRemove(itemID: target, facts: RemoveFacts(item: RetainedItemSummary(
        id: target, lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100), pinOrdinal: PinOrdinal(rawValue: 0)
    ), pinnedCount: pinnedCount))
    guard case .commit(let removePlan) = removed, removePlan.mutations.count == 2,
          case .relocatePin(let cleared) = removePlan.mutations[0],
          case .retire(let retiredID, .userRemoval) = removePlan.mutations[1] else {
        Issue.record("Large pinned removal must remain relocation plus one retirement")
        return
    }
    #expect(cleared.itemID == target)
    #expect(cleared.previousOrdinal?.rawValue == 0)
    #expect(cleared.destinationOrdinal == nil)
    #expect(cleared.pinnedCountBefore == pinnedCount)
    #expect(cleared.shift?.range == 1...(pinnedCount - 1))
    #expect(cleared.shift?.delta == -1)
    #expect(retiredID == target)
}

@Test func largeRetentionPrefixStillProducesOneRetirementMutation() {
    let inventory: [RetainedItemSummary] = (1...100).map { index in
        RetainedItemSummary(
            id: capturePlannerID(UInt8(index)),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: Double(index)),
            pinOrdinal: nil
        )
    }
    for maximum in [75, 74, 1] {
        let prefix = retentionTestPrefix(inventory: inventory.reversed(), maximumUnpinnedItems: maximum)
        let result = planRetention(
            currentPolicy: RetentionPolicy(maximumUnpinnedItems: 100),
            policy: RetentionPolicy(maximumUnpinnedItems: maximum),
            retirementPrefix: prefix
        )
        guard case .commit(let plan) = result,
              plan.mutations.count == 2,
              case .retirePrefix(let selected) = plan.mutations[1] else {
            Issue.record("Many victims must not expand into per-item mutations")
            continue
        }
        #expect(selected.itemCount == 100 - maximum)
        #expect(selected.through.itemID == capturePlannerID(UInt8(100 - maximum)))
        #expect(inventory.filter { selected.contains($0) }.count == selected.itemCount)
    }
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
            incoming: incomingCanonical,
            hintedItem: hinted,
            candidates: [],
            retained: [hinted]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10)
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
            incoming: incomingCanonical,
            hintedItem: hinted,
            candidates: [],
            retained: [hinted]
        ),
        retention: RetentionPolicy(maximumUnpinnedItems: 10)
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
