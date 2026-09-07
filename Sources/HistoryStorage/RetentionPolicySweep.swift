/// V2-02 §4.4: R3 first, R1/R2 over post-prune logical bytes, then the
/// survivor-only R3 veto. SQLite streams candidates; only actual pruning
/// metadata and retirement IDs survive into the single stamped commit.
import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    internal func commitRetentionPolicies(_ newPolicies: HistoryRetentionPolicies) async throws -> HistoryReceipt {
        if let failure = RetentionPolicyBounds.validate(newPolicies) { throw failure }
        let now = storageClock.now()
        let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
        let (position, _) = try Self.decodePositionRow(positionRow, limits: limits)
        let currentPolicies = try RetentionConfigLoading.loadValidatedPolicies(in: database)
        var total = try RetentionConfigLoading.totalRetainedBytes(in: database)
        var lineages: [HistoryItemID: PruneLineage] = [:]
        var pruneIDs: [HistoryItemID: [RevisionID]] = [:]
        var revisionByteOverrides: [HistoryItemID: Int] = [:]

        if let policy = newPolicies.revisions {
            var conditions: [String] = []
            var bindings: [SQLiteValue] = []
            if let maximum = policy.maxRevisionsPerItem {
                conditions.append("revisionCount > ?")
                bindings.append(.integer(Int64(maximum)))
            }
            if let maximum = policy.maxRevisionBytesPerItem {
                conditions.append("revisionBytes > ?")
                bindings.append(.integer(Int64(maximum)))
            }
            let rows = try database.prepare("""
                SELECT id,currentContentID,revisionCount,revisionBytes FROM history_items
                WHERE \(conditions.joined(separator: " OR ")) ORDER BY id
                """, bindings: bindings)
            defer { rows.finalize() }
            while try rows.step() {
                let itemID = HistoryItemID(rawValue: try HistoryItemRowHydration.uuid(rows.text(at: 0)))
                let activeID = RevisionID(rawValue: try HistoryItemRowHydration.uuid(rows.text(at: 1)))
                let storedCount = try HistoryItemRowHydration.integer(rows, 2)
                let storedBytes = try HistoryItemRowHydration.integer(rows, 3)
                let revisions = try MutationFactLoaders.revisionSummaries(itemID: itemID, in: database, limits: limits)
                let before = RetainedBytesStamping.revisionScalars(of: revisions)
                guard before.count == storedCount, before.bytes == storedBytes,
                      revisions.contains(where: { $0.id == activeID }) else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                let removed = planRevisionRetentionExpansion(
                    revisions: revisions, activeRevisionID: activeID, policies: newPolicies)
                let removedSet = Set(removed)
                let after = RetainedBytesStamping.revisionScalars(
                    of: revisions.lazy.filter { !removedSet.contains($0.id) })
                total = try RetentionConfigLoading.checkedSubtract(total,
                    RetentionConfigLoading.checkedSubtract(before.bytes, after.bytes))
                revisionByteOverrides[itemID] = after.bytes
                if !removed.isEmpty {
                    pruneIDs[itemID] = removed
                    lineages[itemID] = PruneLineage(revisions: revisions, activeRevisionID: activeID)
                }
            }
        }

        let victims: [HistoryItemID]
        do {
            victims = try RetentionConfigLoading.itemRetirements(
                in: database, policies: newPolicies, now: now, protectedItemID: nil,
                alreadyRemoved: [], projectedTotalBytes: total,
                revisionByteOverrides: revisionByteOverrides)
        } catch HistoryFailure.capacityExceeded(.storageBytes) {
            // Policy sweeps reject an impossible pinned budget as invalid
            // input; capture/revise use capacityExceeded (V2-02 §8.3).
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }
        let retired = Set(victims)
        if let maximum = newPolicies.revisions?.maxRevisionBytesPerItem {
            for (id, bytes) in revisionByteOverrides where !retired.contains(id) && bytes > maximum {
                throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
            }
        }
        // A retirement subsumes its revisions; do not stamp prune effects
        // or count them in the receipt when the same commit deletes the item.
        for id in victims {
            pruneIDs.removeValue(forKey: id)
            lineages.removeValue(forKey: id)
        }
        if newPolicies == currentPolicies, victims.isEmpty, pruneIDs.isEmpty { return .unchanged }
        var mutations: [HistoryMutation] = victims.map { .retire(itemID: $0, reason: .retention) }
        var prunedCount = 0
        for id in pruneIDs.keys.sorted() {
            guard let removed = pruneIDs[id] else { throw HistoryFailure.persistence(.invariantViolation) }
            mutations.append(.pruneRevisions(itemID: id, removedRevisionIDs: removed))
            prunedCount += removed.count
        }
        mutations.append(.setRetentionPolicies(newPolicies))
        let plan = MutationPlan(
            outcome: .retentionPoliciesSet(retiredItems: victims.count, prunedRevisions: prunedCount),
            mutations: mutations)
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(plan, currentPosition: position,
                inputs: .prune(lineagesByItem: lineages), createdAt: now)
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        }
        return try executeStampedPlan(stamped, expectedPreviousPosition: position, in: database)
    }
}
