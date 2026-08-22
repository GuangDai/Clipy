/// Pure V2-02 R3 revision-prune planner tests: docs/v2/V2-02-retention.md
/// §5.1 (prune relation), §5.2 (what pruning never does, D23), §6.5
/// (signature, non-throwing, never the active ID). Discharges the Domain
/// half of `RET-PRUNE-1` (shortest append-order prefix, oldest-inactive
/// first — not minimum-cardinality; active never pruned; thresholds bound
/// the full set, active included; D3-valid post-prune shape; nil-active /
/// empty-list no-op) plus the D16 purity fixture
/// (`V2-roadmap` §6 R.2).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

private func pruneRevisionID(_ suffix: UInt8) -> RevisionID {
    RevisionID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

/// One revision whose content bytes are the sum of its representation byte
/// counts — the R3 representation-byte measure of §3.2/§5.4 (multiple
/// `byteCounts` entries prove the summation).
private func pruneRevision(
    _ suffix: UInt8,
    byteCounts: [Int]
) -> ContentRevision {
    ContentRevision(
        id: pruneRevisionID(suffix),
        createdAt: Date(timeIntervalSinceReferenceDate: Double(suffix)),
        content: EffectiveContent(
            representations: byteCounts.enumerated().map { index, byteCount in
                ContentRepresentation(
                    typeIdentifier: "public.test-\(index)",
                    bytes: Data(repeating: 0x61, count: byteCount)
                )
            }
        )
    )
}

private func revisionPolicies(
    maxRevisions: Int?,
    maxRevisionBytes: Int?
) -> HistoryRetentionPolicies {
    HistoryRetentionPolicies(
        age: nil,
        storage: nil,
        revisions: RevisionRetention(
            maxRevisionsPerItem: maxRevisions,
            maxRevisionBytesPerItem: maxRevisionBytes
        )
    )
}

// MARK: - Prune relation (V2-02 §5.1; RET-PRUNE-1(a)/(b))

@Test func countThresholdPrunesOldestInactiveAroundAMidListActive() {
    // R = [r1..r5], each 10 bytes, active r3, maxRevisions = 2. The full
    // retained set (active included, §5.1) holds 5 > 2, so the shortest
    // append-order prefix of inactive revisions is r1, r2, r4 — r5 is the
    // first survivor once count reaches 2. The active r3 stays exactly where
    // it is; survivors keep append order ([r3, r5]).
    let revisions = (1...5).map { pruneRevision(UInt8($0), byteCounts: [10]) }
    let active = pruneRevisionID(3)

    let pruned = planRevisionRetentionExpansion(
        revisions: revisions,
        target: .setRetentionPolicies(activeRevisionID: active),
        policies: revisionPolicies(maxRevisions: 2, maxRevisionBytes: nil)
    )
    #expect(pruned == [pruneRevisionID(1), pruneRevisionID(2), pruneRevisionID(4)])
}

@Test func byteThresholdSelectsTheAppendOrderPrefixNotAMinimumCardinalitySubset() throws {
    // R = [r1(10), r2(100), r3(5)], active r3, maxBytes = 15. Total 115 > 15:
    // the prefix walk removes r1 (105 left) then r2 (5 left <= 15), yielding
    // [r1, r2]. Removing r2 ALONE would satisfy the threshold with fewer
    // pruned revisions, but it is not an append-order prefix — §5.1 selects
    // the shortest PREFIX, oldest-inactive first, never a
    // minimum-cardinality subset.
    let r1 = pruneRevision(1, byteCounts: [10])
    let r2 = pruneRevision(2, byteCounts: [100])
    let r3 = pruneRevision(3, byteCounts: [5])

    let pruned = planRevisionRetentionExpansion(
        revisions: [r1, r2, r3],
        target: .setRetentionPolicies(activeRevisionID: r3.id),
        policies: revisionPolicies(maxRevisions: nil, maxRevisionBytes: 15)
    )
    #expect(pruned == [r1.id, r2.id])
}

@Test func byteMeasureSumsEveryRepresentationOfARevision() throws {
    // rA carries two representations (20 + 10 = 30 content bytes). With
    // rB(5) active and maxBytes = 33, the total 35 > 33 prunes rA; a measure
    // that read only one representation (20) would see 25 <= 33 and prune
    // nothing.
    let rA = pruneRevision(1, byteCounts: [20, 10])
    let rB = pruneRevision(2, byteCounts: [5])

    let pruned = planRevisionRetentionExpansion(
        revisions: [rA, rB],
        target: .setRetentionPolicies(activeRevisionID: rB.id),
        policies: revisionPolicies(maxRevisions: nil, maxRevisionBytes: 33)
    )
    #expect(pruned == [rA.id])
}

@Test func bothThresholdsAreSatisfiedByOnePrefix() throws {
    // R = [r1(10), r2(20), r3(30), r4(40)], active r4, maxRevisions = 2 and
    // maxBytes = 75. count 4 > 2 prunes r1 (count 3, bytes 90); count still
    // > 2 prunes r2 (count 2, bytes 70 <= 75) — both thresholds hold at the
    // same prefix boundary.
    let r1 = pruneRevision(1, byteCounts: [10])
    let r2 = pruneRevision(2, byteCounts: [20])
    let r3 = pruneRevision(3, byteCounts: [30])
    let r4 = pruneRevision(4, byteCounts: [40])

    let pruned = planRevisionRetentionExpansion(
        revisions: [r1, r2, r3, r4],
        target: .setRetentionPolicies(activeRevisionID: r4.id),
        policies: revisionPolicies(maxRevisions: 2, maxRevisionBytes: 75)
    )
    #expect(pruned == [r1.id, r2.id])
}

@Test func alreadySatisfiedThresholdsYieldTheEmptyPrune() {
    // §5.3: `removedRevisionIDs` is non-empty in a real mutation because a
    // no-op prune never becomes one — a satisfying lineage prunes nothing.
    let r1 = pruneRevision(1, byteCounts: [10])
    let r2 = pruneRevision(2, byteCounts: [20])

    let pruned = planRevisionRetentionExpansion(
        revisions: [r1, r2],
        target: .setRetentionPolicies(activeRevisionID: r2.id),
        policies: revisionPolicies(maxRevisions: 5, maxRevisionBytes: 100)
    )
    #expect(pruned.isEmpty)
}

// MARK: - Active-revision safety (V2-02 §5.1/§5.2, §6.5; D3, D23)

@Test func unsatisfiableByteThresholdReturnsEveryInactiveNeverTheActive() {
    // R = [r1(10), r2(20)], active r2, maxBytes = 5: the active revision's
    // bytes alone exceed the threshold, so no prune set can satisfy it.
    // §6.5: the unsatisfiable case is detected on the V2-extended
    // preparation path and fails `.capacityExceeded(.revisionBytes)`
    // (§4.3/§8.3); this total planner then returns the full inactive prefix
    // — every inactive ID, never the active one — and never more IDs than
    // inactive revisions present.
    let r1 = pruneRevision(1, byteCounts: [10])
    let r2 = pruneRevision(2, byteCounts: [20])

    let pruned = planRevisionRetentionExpansion(
        revisions: [r1, r2],
        target: .setRetentionPolicies(activeRevisionID: r2.id),
        policies: revisionPolicies(maxRevisions: nil, maxRevisionBytes: 5)
    )
    #expect(pruned == [r1.id])
}

@Test func reviseTargetExemptsOnlyTheAppendedActiveRevision() {
    // .revise: the effective list is [r1, r2, appended] and the active is
    // the appended ID (§6.5) — the PREVIOUS active r2 loses its exemption
    // and is prunable like any other inactive revision. Effective count 3 >
    // 2 prunes r1 (count 2 <= 2); r2 survives as a plain inactive survivor,
    // appended survives as the active.
    let r1 = pruneRevision(1, byteCounts: [10])
    let r2 = pruneRevision(2, byteCounts: [20])
    let appended = pruneRevision(3, byteCounts: [30])

    let pruned = planRevisionRetentionExpansion(
        revisions: [r1, r2],
        target: .revise(appended: appended),
        policies: revisionPolicies(maxRevisions: 2, maxRevisionBytes: nil)
    )
    #expect(pruned == [r1.id])
}

@Test func reviseTargetCountsTheAppendedBytesAgainstTheThreshold() {
    // Effective bytes 50 + 50 + 200 = 300 > 210 prune r1 (250 left) then r2
    // (200 <= 210). The appended active (200 bytes) is never pruned even
    // though it alone carries most of the footprint.
    let r1 = pruneRevision(1, byteCounts: [50])
    let r2 = pruneRevision(2, byteCounts: [50])
    let appended = pruneRevision(3, byteCounts: [200])

    let pruned = planRevisionRetentionExpansion(
        revisions: [r1, r2],
        target: .revise(appended: appended),
        policies: revisionPolicies(maxRevisions: nil, maxRevisionBytes: 210)
    )
    #expect(pruned == [r1.id, r2.id])
}

// MARK: - Degenerate and disabled shapes (RET-PRUNE-1(f); V2-02 §3.1, §7)

@Test func emptyLineageWithNoActivePrunesNothing() {
    // A Canonical-state item (empty revision list, nil active) has no
    // inactive revisions to prune (D3-valid shape in, D3-valid shape out).
    let pruned = planRevisionRetentionExpansion(
        revisions: [],
        target: .setRetentionPolicies(activeRevisionID: nil),
        policies: revisionPolicies(maxRevisions: 1, maxRevisionBytes: 1)
    )
    #expect(pruned.isEmpty)
}

@Test func revisionPolicyDisabledByBothNilThresholdsPrunesNothing() {
    // §3.1: `HistoryRetentionPolicies.init` collapses a both-nil
    // `RevisionRetention` to nil, so R3 is disabled and prunes nothing.
    let r1 = pruneRevision(1, byteCounts: [10])
    let r2 = pruneRevision(2, byteCounts: [20])

    let pruned = planRevisionRetentionExpansion(
        revisions: [r1, r2],
        target: .setRetentionPolicies(activeRevisionID: r2.id),
        policies: HistoryRetentionPolicies(
            age: nil,
            storage: nil,
            revisions: RevisionRetention(
                maxRevisionsPerItem: nil,
                maxRevisionBytesPerItem: nil
            )
        )
    )
    #expect(pruned.isEmpty)
}

// MARK: - D23 postconditions and D16 purity (V2-02 §11)

@Test func d23PostconditionsHoldOnThePrunePayload() {
    // D23 (V2-02 §11): pruning removes only inactive revisions oldest-first,
    // never the active revision, never a survivor's content or ID, never a
    // reorder — the payload IS the ordered removed-ID list, and the
    // effective list minus it remains D3-valid with both thresholds
    // satisfied. Fixture: R = [r1(30), r2(60), r3(10), r4(45)], active r3,
    // maxRevisions = 3, maxBytes = 100. count 4 > 3 prunes r1 (count 3,
    // bytes 115); count is satisfied but bytes 115 > 100 prunes r2 (count 2,
    // bytes 55) — both thresholds hold, so r4 survives.
    let revisions = [
        pruneRevision(1, byteCounts: [30]),
        pruneRevision(2, byteCounts: [60]),
        pruneRevision(3, byteCounts: [10]),
        pruneRevision(4, byteCounts: [45]),
    ]
    let activeID = pruneRevisionID(3)
    let policies = revisionPolicies(maxRevisions: 3, maxRevisionBytes: 100)

    let pruned = planRevisionRetentionExpansion(
        revisions: revisions,
        target: .setRetentionPolicies(activeRevisionID: activeID),
        policies: policies
    )

    // Payload contents: the two oldest inactive IDs, oldest-first.
    #expect(pruned == [pruneRevisionID(1), pruneRevisionID(2)])

    // The active revision is never pruned; the prune set never exceeds the
    // inactive count (§6.5).
    let inactiveIDs = revisions.map(\.id).filter { $0 != activeID }
    #expect(!pruned.contains(activeID))
    #expect(pruned.count <= inactiveIDs.count)

    // The prune set is an append-order PREFIX of the inactive sequence —
    // survivor order is untouched because nothing after the cut moves.
    #expect(pruned == Array(inactiveIDs.prefix(pruned.count)))

    // D3-valid post-prune shape: the survivor list keeps append order and
    // still names the active revision; both thresholds hold over the FULL
    // retained set (active included, §5.1).
    let prunedSet = Set(pruned)
    let survivors = revisions.filter { !prunedSet.contains($0.id) }
    #expect(survivors.map(\.id) == [activeID, pruneRevisionID(4)])
    #expect(survivors.count <= 3)
    let survivorBytes = survivors.reduce(0) { total, revision in
        revision.content.representations.reduce(total) { $0 + $1.bytes.count }
    }
    #expect(survivorBytes <= 100)
}

@Test func identicalInputsProduceIdenticalPruneSets() {
    // D16: a deterministic pure function of (revisions, target, policies) —
    // two invocations over equal facts agree exactly.
    let revisions = [
        pruneRevision(1, byteCounts: [10]),
        pruneRevision(2, byteCounts: [20]),
        pruneRevision(3, byteCounts: [30]),
    ]
    let appended = pruneRevision(4, byteCounts: [40])
    let policies = revisionPolicies(maxRevisions: 2, maxRevisionBytes: 90)

    let first = planRevisionRetentionExpansion(
        revisions: revisions,
        target: .revise(appended: appended),
        policies: policies
    )
    let second = planRevisionRetentionExpansion(
        revisions: revisions,
        target: .revise(appended: appended),
        policies: policies
    )
    #expect(first == second)
    #expect(first == [pruneRevisionID(1), pruneRevisionID(2)])
}
