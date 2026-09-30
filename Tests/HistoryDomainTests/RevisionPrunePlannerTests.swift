/// R3's production planner selects the shortest oldest-inactive prefix from
/// scalar revision metadata; count and byte thresholds include the active
/// revision (V2-02 §5.1–§5.4).
import Foundation
import HistoryCore
import Testing
import HistoryDomain

private func pruneRevisionID(_ suffix: UInt8) -> RevisionID {
    RevisionID(rawValue: UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, suffix
    )))
}

private func summaries(_ bytes: [Int]) -> [RevisionRetentionSummary] {
    bytes.enumerated().map {
        RevisionRetentionSummary(id: pruneRevisionID(UInt8($0.offset + 1)), byteCount: $0.element)
    }
}

private func revisionPolicies(maxRevisions: Int?, maxRevisionBytes: Int?) -> HistoryRetentionPolicies {
    HistoryRetentionPolicies(age: nil, storage: nil, revisions: RevisionRetention(
        maxRevisionsPerItem: maxRevisions, maxRevisionBytesPerItem: maxRevisionBytes
    ))
}

@Test func revisionRetentionCombinesThresholdsAndSkipsAMidListActive() {
    let revisions = summaries([10, 20, 5, 100])
    let cases: [(maxCount: Int?, maxBytes: Int?, expected: [UInt8])] = [
        (nil, nil, []),
        (4, 135, []),
        (3, nil, [1]),
        (2, 105, [1, 2]),
        (nil, 15, [1, 2, 4]),
        // The active alone exceeds this threshold; it still survives.
        (nil, 4, [1, 2, 4]),
    ]
    for scenario in cases {
        let selected = planRevisionRetentionExpansion(
            revisions: revisions, activeRevisionID: revisions[2].id,
            policies: revisionPolicies(maxRevisions: scenario.maxCount, maxRevisionBytes: scenario.maxBytes)
        )
        #expect(selected == scenario.expected.map(pruneRevisionID))
    }
}

@Test func revisionRetentionSelectsTheOldestPrefixRatherThanAFewerVictimSubset() {
    // Removing the 100-byte second revision alone would satisfy the byte
    // threshold, but the oldest-inactive prefix must also remove the first.
    let revisions = summaries([10, 100, 5])
    let selected = planRevisionRetentionExpansion(
        revisions: revisions, activeRevisionID: revisions[2].id,
        policies: revisionPolicies(maxRevisions: nil, maxRevisionBytes: 15)
    )
    #expect(selected == [revisions[0].id, revisions[1].id])
}

@Test func revisionRetentionContinuesAfterAnActiveRevisionToMeetTheCountThreshold() {
    let revisions = summaries([10, 10, 10, 10, 10])
    let selected = planRevisionRetentionExpansion(
        revisions: revisions, activeRevisionID: revisions[2].id,
        policies: revisionPolicies(maxRevisions: 2, maxRevisionBytes: nil)
    )
    #expect(selected == [revisions[0].id, revisions[1].id, revisions[3].id])
}

@Test func revisionRetentionIncludesTheNewActiveInTheProjectedCountAndByteTotals() {
    // Storage supplies the post-append metadata and makes the new revision
    // active; the former active is now eligible for the same prefix walk.
    let revisions = summaries([10, 20, 50])
    let selected = planRevisionRetentionExpansion(
        revisions: revisions, activeRevisionID: revisions[2].id,
        policies: revisionPolicies(maxRevisions: 2, maxRevisionBytes: 55)
    )
    #expect(selected == [revisions[0].id, revisions[1].id])
}

@Test func revisionRetentionKeepsEmptyAndActiveOnlyLineages() {
    let policies = revisionPolicies(maxRevisions: 1, maxRevisionBytes: 1)
    #expect(planRevisionRetentionExpansion(revisions: [], activeRevisionID: nil, policies: policies).isEmpty)
    let activeOnly = summaries([10])
    #expect(planRevisionRetentionExpansion(
        revisions: activeOnly, activeRevisionID: activeOnly[0].id, policies: policies
    ).isEmpty)
}
