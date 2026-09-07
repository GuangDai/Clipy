/// V2-02 §4.4 / V2-09 §4/§6: R3 projection, R1/R2 selection and surviving
/// R3 writes use bounded passes inside one real SQLite transaction. No
/// complete victim-ID array, prune map or content lineage is retained.
import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    internal func commitRetentionPolicies(_ newPolicies: HistoryRetentionPolicies) async throws -> HistoryReceipt {
        if let failure = RetentionPolicyBounds.validate(newPolicies) { throw failure }
        let now = storageClock.now()
        let commit: HistoryCommit?
        do {
            commit = try database.writeTransaction {
                let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
                let (position, _) = try Self.decodePositionRow(positionRow, limits: limits)
                let currentPolicies = try RetentionConfigLoading.loadValidatedPolicies(in: database)
                var projectedTotal = try RetentionConfigLoading.totalRetainedBytes(in: database)
                var projectedPrunedCount = 0
                var hasUnsatisfiableRevision = false

                // Pass 1: R3's post-prune total, retaining one item's bounded
                // revision summaries. No write has occurred yet.
                if let policy = newPolicies.revisions {
                    var after = ""
                    while true {
                        let batch = try sweepRevisionCandidates(after: after, policy: policy)
                        guard !batch.isEmpty else { break }
                        for itemID in batch {
                            let projection = try sweepRevisionProjection(itemID, policies: newPolicies)
                            projectedTotal = try RetentionConfigLoading.checkedSubtract(
                                projectedTotal, projection.originalBytes - projection.scalars.bytes
                            )
                            projectedPrunedCount = try RetentionConfigLoading.checkedAdd(
                                projectedPrunedCount, projection.removed.count
                            )
                            hasUnsatisfiableRevision = hasUnsatisfiableRevision || projection.unsatisfiable
                        }
                        after = batch[batch.count - 1].rawValue.uuidString
                    }
                }

                // Pass 2: re-evaluate only each candidate's small R3 summary
                // while folding the eligible lane. Accounting in the prefix
                // remains pre-prune: retirement subsumes all of that content.
                let prefix: RetentionRetirementPrefix?
                do {
                    prefix = try RetentionConfigLoading.retirementPrefix(
                        in: database, policies: newPolicies, now: now,
                        protectedItemID: nil, projectedTotalBytes: projectedTotal,
                        projectRevisionBytes: { candidate in
                            guard let policy = newPolicies.revisions,
                                  Self.requiresRevisionPrune(
                                    count: candidate.revisionCount, bytes: candidate.revisionBytes, policy: policy
                                  ) else { return candidate.revisionBytes }
                            return try self.sweepRevisionProjection(candidate.id, policies: newPolicies).scalars.bytes
                        }
                    )
                } catch HistoryFailure.capacityExceeded(.storageBytes) {
                    throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
                }
                if prefix == nil, hasUnsatisfiableRevision {
                    throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
                }
                if newPolicies == currentPolicies, prefix == nil, projectedPrunedCount == 0 {
                    return nil
                }
                guard let nextPosition = position.successor() else {
                    throw HistoryFailure.capacityExceeded(.coherenceToken)
                }
                _ = try validateHistoryCommit(expectedPreviousPosition: position, in: database)
                if let prefix { try apply(.retirePrefix(prefix), published: nil, in: database) }

                // Pass 3: select a small ID batch, finalize that SELECT, then
                // prune its survivors. This avoids mutating a table under an
                // active scan and keeps retirement-subsumes-prune counts exact.
                var prunedCount = 0
                if let policy = newPolicies.revisions {
                    var after = ""
                    while true {
                        let batch = try sweepRevisionCandidates(after: after, policy: policy)
                        guard !batch.isEmpty else { break }
                        for itemID in batch {
                            let projection = try sweepRevisionProjection(itemID, policies: newPolicies)
                            guard !projection.unsatisfiable else {
                                throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
                            }
                            if !projection.removed.isEmpty {
                                try apply(.pruneRevisions(
                                    itemID: itemID, removedRevisionIDs: projection.removed,
                                    retainedRevisionScalars: projection.scalars
                                ), published: nil, in: database)
                                prunedCount = try RetentionConfigLoading.checkedAdd(prunedCount, projection.removed.count)
                            }
                        }
                        after = batch[batch.count - 1].rawValue.uuidString
                    }
                }
                try apply(.setRetentionPolicies(policies: newPolicies), published: nil, in: database)
                let retiredCount = prefix?.itemCount ?? 0
                let outcome = HistoryCommitOutcome.retentionPoliciesSet(
                    retiredItems: retiredCount, prunedRevisions: prunedCount
                )
                let hcr = HistoryChangeRecordPayload(
                    sequence: nextPosition.rawValue, changePositionRaw: nextPosition.rawValue,
                    changeKind: retiredCount > 0 ? .retire : (prunedCount > 0 ? .retireRevision : .policySet),
                    affectedItems: .retention(retiredItems: retiredCount, prunedRevisions: prunedCount),
                    createdAt: now
                )
                try finishHistoryCommit(
                    position: nextPosition, hcrAppend: hcr, expectedPreviousPosition: position, in: database
                )
                return HistoryCommit(
                    position: nextPosition, outcome: outcome,
                    hasDestructiveRetentionEffects: retiredCount > 0 || prunedCount > 0
                )
            }
        } catch {
            throw PersistenceErrorClassification.transactionFailure(for: error)
        }
        guard let commit else { return .unchanged }
        return publishCommittedHistory(commit)
    }

    private static func requiresRevisionPrune(count: Int, bytes: Int, policy: RevisionRetention) -> Bool {
        (policy.maxRevisionsPerItem.map { count > $0 } ?? false)
            || (policy.maxRevisionBytesPerItem.map { bytes > $0 } ?? false)
    }

    private func sweepRevisionCandidates(after: String, policy: RevisionRetention) throws -> [HistoryItemID] {
        var predicates: [String] = []
        var bindings: [SQLiteValue] = [.text(after)]
        if let maximum = policy.maxRevisionsPerItem {
            predicates.append("revisionCount > ?")
            bindings.append(.integer(Int64(maximum)))
        }
        if let maximum = policy.maxRevisionBytesPerItem {
            predicates.append("revisionBytes > ?")
            bindings.append(.integer(Int64(maximum)))
        }
        guard !predicates.isEmpty else { return [] }
        let rows = try database.prepare("""
            SELECT id FROM history_items WHERE id > ? AND (\(predicates.joined(separator: " OR ")))
            ORDER BY id LIMIT 32
            """, bindings: bindings)
        defer { rows.finalize() }
        var result: [HistoryItemID] = []
        while try rows.step() {
            result.append(HistoryItemID(rawValue: try HistoryItemRowHydration.uuid(rows.text(at: 0))))
        }
        return result
    }

    private func sweepRevisionProjection(
        _ itemID: HistoryItemID, policies: HistoryRetentionPolicies
    ) throws -> (removed: [RevisionID], scalars: RetainedRevisionScalars, originalBytes: Int, unsatisfiable: Bool) {
        let row = try database.prepare(
            "SELECT currentContentID, revisionCount, revisionBytes FROM history_items WHERE id = ?",
            bindings: [.text(itemID.rawValue.uuidString)]
        )
        defer { row.finalize() }
        guard try row.step() else { throw HistoryFailure.persistence(.invariantViolation) }
        let activeID = RevisionID(rawValue: try HistoryItemRowHydration.uuid(row.text(at: 0)))
        let storedCount = try HistoryItemRowHydration.integer(row, 1)
        let storedBytes = try HistoryItemRowHydration.integer(row, 2)
        let revisions = try MutationFactLoaders.revisionSummaries(itemID: itemID, in: database, limits: limits)
        let before = RetainedBytesStamping.revisionScalars(of: revisions)
        guard before.count == storedCount, before.bytes == storedBytes,
              revisions.contains(where: { $0.id == activeID }) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let removed = planRevisionRetentionExpansion(
            revisions: revisions, activeRevisionID: activeID, policies: policies
        )
        let removedSet = Set(removed)
        let after = RetainedBytesStamping.revisionScalars(of: revisions.lazy.filter { !removedSet.contains($0.id) })
        let unsatisfiable = policies.revisions?.maxRevisionBytesPerItem.map { after.bytes > $0 } ?? false
        return (removed, after, before.bytes, unsatisfiable)
    }
}
