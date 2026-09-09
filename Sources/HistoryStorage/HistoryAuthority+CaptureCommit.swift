import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    /// Capture inputs are prepared off-actor. This interval loads indexed
    /// candidates, byte-confirms a winner, plans, and commits without suspension.
    internal func commitCapture(_ prepared: PreparedCaptureBundle) async throws -> HistoryReceipt {
        await suspendIfRequested(.captureCommitEntry)
        let receipt = try autoreleasepool { try commitCaptureInLocalContext(prepared) }
#if DEBUG
        storageLifecycleDebugProbe.record(phase: .captureAutoreleasePoolDrained)
#endif
        return receipt
    }

    internal func commitCaptureInLocalContext(_ prepared: PreparedCaptureBundle) throws -> HistoryReceipt {
        let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
        let (currentPosition, retention) = try Self.decodePositionRow(positionRow, limits: limits)
#if DEBUG
        let clock = ContinuousClock()
        let start = clock.now
        storageLifecycleDebugProbe.record(phase: .captureFactLoadBegin)
#endif
        let facts = try IngestFactLoader.loadFacts(
            in: database, blobStore: blobStore, prepared: prepared.domain,
            retention: retention, limits: limits
        )
#if DEBUG
        storageLifecycleDebugProbe.record(
            phase: .captureFactLoadComplete, elapsed: start.duration(to: clock.now)
        )
#endif
        let result: PlanningResult
        do {
            result = try planCapture(
                prepared.domain, facts: facts, retention: retention
            )
        } catch let rejection as DomainRejection {
            if case .candidateItemIDCollision(let itemID) = rejection {
                throw CaptureCandidateIDCollision(itemID: itemID)
            }
            throw rejection.historyFailure
        }
        guard case .commit(let primaryPlan) = result else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let plan = try composeRetentionExpansionForCapture(primaryPlan, prepared: prepared, in: database)
        let winnerVersion: ContentVersion?
        switch plan.outcome {
        case .inserted:
            winnerVersion = nil
        case .coalesced(let itemID):
            let statement = try database.prepare(
                "SELECT contentVersion FROM history_items WHERE id = ?",
                bindings: [.text(itemID.rawValue.uuidString)]
            )
            defer { statement.finalize() }
            guard try statement.step() else { throw HistoryFailure.persistence(.invariantViolation) }
            winnerVersion = ContentVersion(rawValue: try sqliteUInt64(statement.blob(at: 0)))
        default:
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                plan, currentPosition: currentPosition,
                inputs: .capture(projection: prepared.projection, coalescedWinnerVersion: winnerVersion),
                createdAt: storageClock.now()
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }
#if DEBUG
        let transactionStart = clock.now
        storageLifecycleDebugProbe.record(phase: .captureTransactionBegin)
#endif
        let receipt = try executeStampedPlan(
            stamped, expectedPreviousPosition: currentPosition, in: database,
            captureObservation: (prepared.domain.origin.sourceApplication, prepared.domain.observedAt)
        )
#if DEBUG
        storageLifecycleDebugProbe.record(
            phase: .captureTransactionComplete, elapsed: transactionStart.duration(to: clock.now)
        )
#endif
        return receipt
    }

    /// Commit first, then publish once. Cleanup cannot turn a durable success
    /// into failure: unreferenced files remain recoverable by later bounded
    /// cleanup, while the database remains the authoritative reference set.
    internal func executeStampedPlan(
        _ stamped: StampedCommitPlan,
        expectedPreviousPosition: ChangePosition,
        in database: SQLiteDatabase,
        captureObservation: (application: String?, copiedAt: Date)? = nil
    ) throws -> HistoryReceipt {
        try executeCommitTransaction(stamped, expectedPreviousPosition: expectedPreviousPosition, in: database,
                                     captureObservation: captureObservation)
        return publishCommittedHistory(HistoryCommit(
            position: stamped.position, outcome: stamped.receiptOutcome,
            hasDestructiveRetentionEffects: stamped.hasDestructiveRetentionEffects
        ))
    }

    /// Ordinary actions and bounded sweeps publish only after their single
    /// SQL transaction has returned successfully.
    internal func publishCommittedHistory(_ commit: HistoryCommit) -> HistoryReceipt {
        invalidationPublisher.publish(HistoryInvalidation(latestPosition: commit.position))
        let removedContent: Bool
        switch commit.outcome {
        case .removed(let count), .cleared(let count):
            removedContent = count > 0
        case .retentionPolicySet(let count):
            removedContent = count > 0
        case .retentionPoliciesSet(let retiredItems, let prunedRevisions):
            removedContent = retiredItems > 0 || prunedRevisions > 0
        case .inserted, .coalesced, .placedPinned, .unpinned, .revised:
            removedContent = false
        }
        // This existing receipt fact includes capture/revise retention and
        // append-with-prune. Ordinary copy/pin does not start another scan.
        if removedContent || commit.hasDestructiveRetentionEffects { requestBlobCleanup() }
        return .committed(commit)
    }
}
