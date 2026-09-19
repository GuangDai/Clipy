/// V2-02 §4.4 / V2-09 §4/§6: R3 projection, R1/R2 selection and surviving
/// R3 writes use bounded preparation followed by one SQLite transaction. No
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
            let preparation = try await prepareRetentionSweep(newPolicies, now: now)
            commit = try database.writeTransaction(checkingCancellation: true) {
                let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
                let (position, _) = try Self.decodePositionRow(positionRow, limits: limits)
                guard position == preparation.position else {
                    throw HistoryFailure.snapshotExpired(current: position)
                }
                let currentPolicies = try RetentionConfigLoading.loadValidatedPolicies(in: database)
                let prefix = preparation.prefix
                let projectedPrunedCount = preparation.prunedCount
                let hasUnsatisfiableRevision = preparation.hasUnsatisfiableRevision
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
                // No second walk is needed when projection found no work.
                // An active-only byte violation still needs the survivor veto
                // even if its inactive prune count is zero (V2-02 DC-27).
                var prunedCount = 0
                if let policy = newPolicies.revisions,
                   projectedPrunedCount > 0 || hasUnsatisfiableRevision {
                    var after = ""
                    while true {
                        guard let batch = try sweepRevisionCandidates(after: after, policy: policy) else { break }
                        for itemID in batch.itemIDs {
                            try Task.checkCancellation()
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
                        after = batch.after
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PersistenceErrorClassification.transactionFailure(for: error)
        }
        guard let commit else { return .unchanged }
        return publishCommittedHistory(commit)
    }

    /// V2-02 §4.4: projection does not need a write transaction. Release all
    /// statements before yielding, then reject stale facts before another
    /// batch can use them. Capture, paste and page requests can run meanwhile.
    private func prepareRetentionSweep(
        _ policies: HistoryRetentionPolicies, now: Date
    ) async throws -> RetentionSweepPreparation {
        try Task.checkCancellation()
        let position = try Self.decodePositionRow(
            Self.fetchExactlyOnePositionRow(in: database), limits: limits
        ).position
        var total = try RetentionConfigLoading.totalRetainedBytes(in: database)
        var prunedCount = 0
        var unsatisfiable = false
        if let policy = policies.revisions {
            var after = ""
            while true {
                guard let batch = try sweepRevisionCandidates(after: after, policy: policy) else { break }
                for itemID in batch.itemIDs {
                    try Task.checkCancellation()
                    let projection = try sweepRevisionProjection(itemID, policies: policies)
                    total = try RetentionConfigLoading.checkedSubtract(
                        total, projection.originalBytes - projection.scalars.bytes
                    )
                    prunedCount = try RetentionConfigLoading.checkedAdd(prunedCount, projection.removed.count)
                    unsatisfiable = unsatisfiable || projection.unsatisfiable
                }
                after = batch.after
                try await yieldRetentionPreparation(at: position)
            }
        }
        var selection = OrderedRetentionSelection(
            policies: policies, now: now, protectedItemID: nil, projectedTotalBytes: total
        )
        if policies.age != nil || policies.storage.map({ total > $0.maxTotalBytes }) == true {
            var after: RetentionEvictionKey?
            var complete = false
            while !complete {
                let batch = try retentionSweepCandidates(after: after)
                guard !batch.isEmpty else { break }
                for candidate in batch {
                    try Task.checkCancellation()
                    let revisions: Int
                    if let policy = policies.revisions, Self.requiresRevisionPrune(
                        count: candidate.revisionCount, bytes: candidate.revisionBytes, policy: policy
                    ) {
                        revisions = try sweepRevisionProjection(candidate.id, policies: policies).scalars.bytes
                    } else { revisions = candidate.revisionBytes }
                    do {
                        if try !selection.consider(candidate, projectedRevisionBytes: revisions) {
                            complete = true
                            break
                        }
                    } catch let rejection as DomainRejection { throw rejection.historyFailure }
                    after = RetentionEvictionKey(lastCopiedAt: candidate.lastCopiedAt, itemID: candidate.id)
                }
                if !complete { try await yieldRetentionPreparation(at: position) }
            }
        }
        if let budget = policies.storage?.maxTotalBytes, selection.remainingBytes > budget {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }
        return RetentionSweepPreparation(
            position: position, prefix: selection.prefix,
            prunedCount: prunedCount, hasUnsatisfiableRevision: unsatisfiable
        )
    }

    private func yieldRetentionPreparation(at expected: ChangePosition) async throws {
        await suspendIfRequested(.retentionPlanningBatch)
        await Task.yield()
        try Task.checkCancellation()
        let current = try Self.decodePositionRow(
            Self.fetchExactlyOnePositionRow(in: database), limits: limits
        ).position
        guard current == expected else { throw HistoryFailure.snapshotExpired(current: current) }
    }

    private func retentionSweepCandidates(after: RetentionEvictionKey?) throws -> [RetentionExpansionItemSummary] {
        let predicate = after == nil ? "" : " AND (lastCopiedAt, id) > (?, ?)"
        let bindings: [SQLiteValue] = after.map {
            [.real($0.lastCopiedAt.timeIntervalSinceReferenceDate), .text($0.itemID.rawValue.uuidString)]
        } ?? []
        let rows = try database.prepare("""
            SELECT id,lastCopiedAt,canonicalBytes,revisionCount,revisionBytes
            FROM history_items WHERE pinOrdinal IS NULL\(predicate)
            ORDER BY lastCopiedAt,id LIMIT 32
            """, bindings: bindings)
        defer { rows.finalize() }
        var result: [RetentionExpansionItemSummary] = []
        while try rows.step() {
            try Task.checkCancellation()
            result.append(try RetentionExpansionItemSummary(
                id: HistoryItemID(rawValue: HistoryItemRowHydration.uuid(rows.text(at: 0))),
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: rows.real(at: 1)), pinOrdinal: nil,
                canonicalBytes: HistoryItemRowHydration.integer(rows, 2),
                revisionCount: HistoryItemRowHydration.integer(rows, 3),
                revisionBytes: HistoryItemRowHydration.integer(rows, 4)
            ))
        }
        return result
    }

    private static func requiresRevisionPrune(count: Int, bytes: Int, policy: RevisionRetention) -> Bool {
        (policy.maxRevisionsPerItem.map { count > $0 } ?? false)
            || (policy.maxRevisionBytesPerItem.map { bytes > $0 } ?? false)
    }

    /// Bound visited index entries, not just threshold matches: a satisfied
    /// policy must still release the Authority between pages (V2-09 §4).
    /// The covering index supplies only scalars; content lineage is loaded
    /// for threshold violations. An empty match page still advances its key.
    private func sweepRevisionCandidates(
        after: String, policy: RevisionRetention
    ) throws -> (after: String, itemIDs: [HistoryItemID])? {
        let rows = try database.prepare("""
            SELECT id,revisionCount,revisionBytes FROM history_items
            WHERE id > ? AND (revisionCount > 0 OR revisionBytes > 0)
            ORDER BY id LIMIT 32
            """, bindings: [.text(after)])
        defer { rows.finalize() }
        var result: [HistoryItemID] = []
        var lastID: String?
        while try rows.step() {
            try Task.checkCancellation()
            let id = try rows.text(at: 0)
            let itemID = HistoryItemID(rawValue: try HistoryItemRowHydration.uuid(id))
            let count = try HistoryItemRowHydration.integer(rows, 1)
            let bytes = try HistoryItemRowHydration.integer(rows, 2)
            if Self.requiresRevisionPrune(count: count, bytes: bytes, policy: policy) {
                result.append(itemID)
            }
            lastID = id
        }
        return lastID.map { (after: $0, itemIDs: result) }
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

private struct RetentionSweepPreparation {
    let position: ChangePosition
    let prefix: RetentionRetirementPrefix?
    let prunedCount: Int
    let hasUnsatisfiableRevision: Bool
}
