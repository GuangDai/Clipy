/// Revision retention composition: R3 over append-ordered metadata, then R2
/// over the projected aggregate and an ordered SQL victim cursor. One merged
/// plan commits the append, prune, and retirements atomically (V2-02 §4.3).
import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    internal func composeRetentionExpansionForRevision(
        _ v1Plan: MutationPlan,
        bundle: PreparedRevisionBundle,
        facts: RevisionFacts,
        in database: SQLiteDatabase
    ) throws -> MutationPlan {
        // Phase two rereads policies: preparation's speculative R3 result
        // cannot survive an interleaving policy change (V2-02 §4.3).
        let policies = try RetentionConfigLoading.loadReviseLanePolicies(in: database)
        guard case .appendRevision(let revisedItemID, let appendedRevision, _) = v1Plan.mutations.first else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        var appendedBytes = 0
        for representation in appendedRevision.content.representations {
            appendedBytes = try RetentionConfigLoading.checkedAdd(appendedBytes, representation.bytes.count)
        }
        var postAppendRevisions = facts.revisions
        postAppendRevisions.append(RevisionRetentionSummary(id: appendedRevision.id, byteCount: appendedBytes))
        let pruneSet: [RevisionID]
        if let revisionPolicy = policies?.revisions {
            pruneSet = planRevisionRetentionExpansion(
                revisions: postAppendRevisions,
                activeRevisionID: appendedRevision.id,
                policies: HistoryRetentionPolicies(age: nil, storage: nil, revisions: revisionPolicy)
            )
        } else {
            pruneSet = []
        }

        let prunedIDs = Set(pruneSet)
        var oldRevisionBytes = 0
        var projectedRevisionBytes = appendedBytes
        for revision in facts.revisions {
            oldRevisionBytes = try RetentionConfigLoading.checkedAdd(oldRevisionBytes, revision.byteCount)
            if !prunedIDs.contains(revision.id) {
                projectedRevisionBytes = try RetentionConfigLoading.checkedAdd(projectedRevisionBytes, revision.byteCount)
            }
        }
        // R3 precedes hard bounds, including when its configuration changed
        // after preparation. The appended active revision is never prunable
        // (V2-02 §5.4/§8.3; 06 §2).
        if let maximumBytes = policies?.revisions?.maxRevisionBytesPerItem,
           projectedRevisionBytes > maximumBytes {
            throw HistoryFailure.capacityExceeded(.revisionBytes)
        }
        guard facts.revisions.count - pruneSet.count < limits.maximumRevisionsPerItem else {
            throw HistoryFailure.capacityExceeded(.revisionCount)
        }
        guard projectedRevisionBytes <= limits.maximumTotalRevisionBytesPerItem else {
            throw HistoryFailure.capacityExceeded(.revisionBytes)
        }

        var mutations = v1Plan.mutations
        if !pruneSet.isEmpty {
            mutations.append(.pruneRevisions(itemID: revisedItemID, removedRevisionIDs: pruneSet))
        }
        if let storagePolicy = policies?.storage {
            // Only the revised item's revision bytes change before R2. The
            // durable aggregate accounts for every other retained item; SQL
            // streams oldest unpinned victims, retaining only selected IDs.
            let currentTotal = try RetentionConfigLoading.totalRetainedBytes(in: database)
            let withoutOldRevisions = try RetentionConfigLoading.checkedSubtract(currentTotal, oldRevisionBytes)
            let projectedTotal = try RetentionConfigLoading.checkedAdd(withoutOldRevisions, projectedRevisionBytes)
            let victims = try RetentionConfigLoading.itemRetirements(
                in: database,
                policies: HistoryRetentionPolicies(age: nil, storage: storagePolicy, revisions: nil),
                now: bundle.domain.createdAt,
                protectedItemID: revisedItemID,
                alreadyRemoved: [],
                projectedTotalBytes: projectedTotal,
                revisionByteOverrides: [revisedItemID: projectedRevisionBytes]
            )
            mutations.append(contentsOf: victims.map { .retire(itemID: $0, reason: .retention) })
        }
        return MutationPlan(outcome: v1Plan.outcome, mutations: mutations)
    }
}
