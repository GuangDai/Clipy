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

@Test func revisionRetentionSelectsOnlyTheRequiredOldestInactivePrefix() {
    let cases: [(bytes: [Int], active: Int?, count: Int?, limit: Int?, victims: [Int])] = [
        ([10, 20, 5, 100], 2, nil, nil, []),
        ([10, 20, 5, 100], 2, 4, 135, []),
        ([10, 20, 5, 100], 2, 3, nil, [1]),
        ([10, 20, 5, 100], 2, 2, 105, [1, 2]),
        ([10, 20, 5, 100], 2, nil, 15, [1, 2, 4]),
        // Active content alone can exceed the threshold and must still survive.
        ([10, 20, 5, 100], 2, nil, 4, [1, 2, 4]),
        // A large younger victim cannot replace the required oldest prefix.
        ([10, 100, 5], 2, nil, 15, [1, 2]),
        // Prefix selection continues past an active revision in the middle.
        ([10, 10, 10, 10, 10], 2, 2, nil, [1, 2, 4]),
        // The newly active append participates in both projected totals.
        ([10, 20, 50], 2, 2, 55, [1, 2]),
        ([], nil, 1, 1, []),
        ([10], 0, 1, 1, []),
    ]
    for sample in cases {
        let revisions = summaries(sample.bytes)
        let selected = planRevisionRetentionExpansion(
            revisions: revisions, activeRevisionID: sample.active.map { revisions[$0].id },
            policies: revisionPolicies(maxRevisions: sample.count, maxRevisionBytes: sample.limit)
        )
        #expect(selected == sample.victims.map { pruneRevisionID(UInt8($0)) })
    }
}
