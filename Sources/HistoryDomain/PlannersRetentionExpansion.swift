/// Pure R3 revision-threshold pruning over append-ordered lineage
/// (V2-02 §5.1–§5.4). R1/R2 use OrderedRetentionSelection.
import Foundation
import HistoryCore

/// Which caller shape an R3 prune is computed for, making the two callers
/// type-mutually-exclusive (avoids passing an inconsistent
/// `activeRevisionID` + `appendedRevision` pair).
/// docs/v2/V2-02-retention.md §6.5
package enum RevisionExpansionTarget: Sendable {
    /// Fires from a policy change (no append): the effective list is the
    /// loaded lineage and the active is `activeRevisionID`
    /// (`V2-02` §5.5/§4.4 PHASE A).
    case setRetentionPolicies(activeRevisionID: RevisionID?)

    /// Fires from a revision append: the effective list is
    /// `revisions + [appended]` and the active is `appended.id`
    /// (`V2-02` §4.3).
    case revise(appended: ContentRevision)
}

// MARK: - R3 (docs/v2/V2-02-retention.md §5.1–§5.3, §6.5)

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

/// Plans the R3 prune set for one item's revision lineage (already loaded).
/// docs/v2/V2-02-retention.md §5.1, §6.5
///
/// `revisions` is the pre-append loaded lineage. The `target` fixes the
/// effective list and its active revision: `.setRetentionPolicies(active)`
/// fires from a policy change (no append; the effective list is `revisions`
/// and the active is `active`), `.revise(appended)` fires from a revision
/// append (the effective list is `revisions + [appended]` and the active is
/// `appended.id`). The returned prune set is computed over the effective
/// post-append list and never contains the effective active ID.
///
/// The prune relation (§5.1, `RET-PRUNE-1`): the prune set is the shortest
/// append-order PREFIX of inactive revisions — oldest inactive first, NOT a
/// minimum-cardinality subset — whose removal makes the FULL retained set
/// (active included) satisfy `count <= maxRevisionsPerItem` and
/// `bytes <= maxRevisionBytesPerItem`. Append order over inactive revisions
/// is a total order with no ties (`02` §2.5 rule 1), so no ID tie-break is
/// required; the v1 `lastCopiedAt ascending, id ascending` eviction tie-break
/// (`02` §12) governs item retirement, not within-item revision order.
///
/// What pruning never does (§5.2, D23): it never removes the active revision
/// (D3), never changes a surviving revision's content or ID (D4), never
/// reorders survivors, and never touches Canonical Content, Effective
/// Content, `ContentVersion` (D5), projections, or Signature Index postings —
/// the payload is exactly the removed IDs, oldest-first; the Storage composer
/// rewrites the `RevisionStateBlobV1` from it (§5.3/§6.3).
///
/// This planner throws nothing (§6.5) and never returns more IDs than
/// inactive revisions present. An unsatisfiable R3 prune (the effective
/// active revision's bytes alone exceed `maxRevisionBytesPerItem`) is
/// detected on the V2-extended preparation path and fails
/// `.capacityExceeded(.revisionBytes)` (§4.3/§8.3), not returned as a partial
/// prune set; defensively this total function then returns the full inactive
/// prefix — every inactive ID, never the active — which the preparation-path
/// rejection prevents from ever being stamped. The count dimension is always
/// satisfiable on revise (pruning to the new active alone yields count 1 <=
/// `maxRevisionsPerItem` for any admitted `maxRevisionsPerItem >= 1`, §4.3).
package func planRevisionRetentionExpansion(
    revisions: [ContentRevision],
    target: RevisionExpansionTarget,
    policies: HistoryRetentionPolicies
) -> [RevisionID] {
    // §3.1/§7: a `RevisionRetention` with both thresholds nil is normalized
    // to `nil` at `HistoryRetentionPolicies.init`, so R3-disabled prunes
    // nothing and this planner is never the no-op's cause.
    guard policies.revisions != nil else { return [] }

    // §6.5: the target fixes the effective list and active revision.
    var summaries = revisions.map {
        RevisionRetentionSummary(id: $0.id, byteCount: revisionContentBytes($0))
    }
    let activeRevisionID: RevisionID?
    switch target {
    case .setRetentionPolicies(let activeID):
        activeRevisionID = activeID
    case .revise(let appended):
        summaries.append(RevisionRetentionSummary(
            id: appended.id, byteCount: revisionContentBytes(appended)
        ))
        activeRevisionID = appended.id
    }
    return planRevisionRetentionExpansion(
        revisions: summaries,
        activeRevisionID: activeRevisionID,
        policies: policies
    )
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

/// One revision's content bytes: the sum of its Effective representation
/// byte counts — the R3 representation-byte measure (§3.2/§5.4), commensurate
/// with `canonicalBytes` and with the v1 per-item-revision-byte hard bound
/// (measure identity gated by `RET-PLATFORM-4`).
private func revisionContentBytes(_ revision: ContentRevision) -> Int {
    var total = 0
    for representation in revision.content.representations {
        total = checkedByteAdd(total, representation.bytes.count)
    }
    return total
}
