/// Pure R3 revision-threshold pruning over append-ordered lineage
/// (V2-02 §5.1–§5.4). R1/R2 use OrderedRetentionSelection.
import Foundation
import HistoryCore

/// R3 needs append order, revision identity, and the complete representation
/// byte count (§3.2/§5.4), without retaining the revision's content bytes.
/// Storage supplies these summaries in persisted append order.
package struct RevisionRetentionSummary: Sendable {
    package let id: RevisionID
    package let byteCount: Int

    package init(id: RevisionID, byteCount: Int) {
        self.id = id
        self.byteCount = byteCount
    }
}

/// Selects the shortest oldest-inactive prefix from append-ordered metadata
/// (V2-02 §5.1). Thresholds include the active revision's count and bytes;
/// the active ID is never returned. Storage validates persisted byte counts
/// when constructing the facts, so planning does not read content blobs.
package func planRevisionRetentionExpansion(
    revisions: [RevisionRetentionSummary],
    activeRevisionID: RevisionID?,
    policies: HistoryRetentionPolicies
) -> [RevisionID] {
    guard let revisionPolicy = policies.revisions else { return [] }

    // A nil active over a non-empty list is corrupt lineage Storage rejects
    // at fact load (D3, `02` §6/§11 step 3); with no active revision there
    // is simply no revision exempt from pruning, and the planner stays total
    // and deterministic on the defensive path.

    // §5.1: both thresholds bound the FULL retained revision set, active
    // included — `count(R)` and `bytes(R)` count the active revision, not
    // inactive-only. Bytes use the representation-byte measure of §3.2/§5.4
    // (sum of stored-revision representation bytes; checked, never wrapping).
    var retainedCount = revisions.count
    var retainedBytes = 0
    for revision in revisions {
        retainedBytes = checkedByteAdd(retainedBytes, revision.byteCount)
    }

    // §5.1: take the shortest append-order prefix of inactive revisions —
    // walking append order, stop as soon as both thresholds hold. Each
    // removal reduces both count and bytes, so the greedy prefix is the
    // shortest under oldest-inactive-first selection.
    var prunedIDs: [RevisionID] = []
    for revision in revisions where revision.id != activeRevisionID {
        let countSatisfied = revisionPolicy.maxRevisionsPerItem
            .map { retainedCount <= $0 } ?? true
        let bytesSatisfied = revisionPolicy.maxRevisionBytesPerItem
            .map { retainedBytes <= $0 } ?? true
        if countSatisfied && bytesSatisfied {
            break
        }
        prunedIDs.append(revision.id)
        retainedCount -= 1
        retainedBytes = checkedByteSubtract(
            retainedBytes,
            revision.byteCount
        )
    }
    return prunedIDs
}

// MARK: - File-private helpers

/// Checked per-item revision-byte accumulation (`06` §2: no calculation may
/// wrap). Validated revision summaries fit the per-item byte bounds, well
/// inside Int64. Saturation keeps this non-throwing planner from wrapping on
/// invalid facts; Storage owns persisted-byte validation and typed failure.
private func checkedByteAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}

/// Checked budget restore. Subtracting one previously accumulated footprint
/// cannot underflow on well-formed facts; the guarded form keeps even a
/// corrupt negative scalar from wrapping the running total past `Int.max`.
private func checkedByteSubtract(_ lhs: Int, _ rhs: Int) -> Int {
    let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
    return overflow ? Int.max : difference
}
