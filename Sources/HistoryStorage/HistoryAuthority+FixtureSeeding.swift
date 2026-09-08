/// Package performance-fixture seeding
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    // MARK: Package performance-fixture seeding

    /// Proves the package-only performance seeder starts from a new empty
    /// store and that its requested final row count fits both durable
    /// retention policy and the hard bound. This read-only operation exists
    /// solely to fail before a partial fixture is written.
    internal func beginPerformanceFixtureSeed(
        finalRetainedCount: Int
    ) async throws -> ChangePosition {
        try autoreleasepool {
            let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
            let (position, retention) = try Self.decodePositionRow(
                positionRow,
                limits: limits
            )
            let retainedCount = try performanceFixtureRetainedCount()

            guard retainedCount == 0,
                  position.rawValue == 0
            else {
                throw PerformanceFixtureSeedError.storeNotEmpty
            }
            guard retention.maximumUnpinnedItems.map({ finalRetainedCount <= $0 }) ?? true
            else {
                throw PerformanceFixtureSeedError.capacityExceeded
            }
            return position
        }
    }

    /// Commits one bounded fixture batch through the same stamped mutation,
    /// SQLite transaction, invalidation, and position tail as an
    /// ordinary History Commit. Each batch is one non-empty commit and thus
    /// advances Change Position exactly once, regardless of row count.
    internal func commitPerformanceFixtureSeedBatch(
        _ preparedItems: [PreparedCaptureBundle],
        expectedPreviousPosition: ChangePosition,
        expectedRetainedCount: Int
    ) async throws -> ChangePosition {
        try autoreleasepool {
            guard !preparedItems.isEmpty,
                  preparedItems.count <= SQLiteHistory.performanceFixtureSeedBatchSize
            else {
                throw PerformanceFixtureSeedError.invalidRowCount
            }
            let (nextRetainedCount, retainedOverflow) = expectedRetainedCount
                .addingReportingOverflow(preparedItems.count)
            guard !retainedOverflow else {
                throw PerformanceFixtureSeedError.capacityExceeded
            }

            var seenIDs = Set<HistoryItemID>(minimumCapacity: preparedItems.count)
            var mutations: [StampedMutation] = []
            mutations.reserveCapacity(preparedItems.count)
            for prepared in preparedItems {
                let capture = prepared.domain
                guard capture.origin.lineageHint == nil else {
                    throw PerformanceFixtureSeedError.invalidCaptureShape
                }
                let occurrence = CopyOccurrence(
                    firstCopiedAt: capture.observedAt,
                    lastCopiedAt: capture.observedAt,
                    count: 1,
                    firstSource: capture.origin.sourceApplication,
                    lastSource: capture.origin.sourceApplication
                )
                let stored = CommitPlanStamper.prepareNewItem(
                    id: capture.candidateID,
                    canonical: capture.canonical,
                    projection: prepared.projection,
                    occurrence: occurrence
                )
                guard seenIDs.insert(stored.id).inserted
                else {
                    throw PerformanceFixtureSeedError.stateChanged
                }
                mutations.append(.create(stored))
            }

            let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
            let (position, retention) = try Self.decodePositionRow(
                positionRow,
                limits: limits
            )
            guard position == expectedPreviousPosition,
                  try performanceFixtureRetainedCount() == expectedRetainedCount
            else {
                throw PerformanceFixtureSeedError.stateChanged
            }
            guard retention.maximumUnpinnedItems.map({ nextRetainedCount <= $0 }) ?? true
            else {
                throw PerformanceFixtureSeedError.capacityExceeded
            }
            guard let nextPosition = position.successor() else {
                throw HistoryFailure.capacityExceeded(.coherenceToken)
            }
            guard let finalMutation = mutations.last,
                  case .create(let finalItem) = finalMutation
            else {
                throw HistoryFailure.persistence(.invariantViolation)
            }

            let receiptOutcome = HistoryCommitOutcome.inserted(
                HistoryItemReference(
                    id: finalItem.id,
                    contentVersion: finalItem.contentVersion
                )
            )
            let hcrAppend = try HistoryChangeRecordPayload.derive(
                position: nextPosition,
                mutations: mutations,
                receiptOutcome: receiptOutcome,
                clearScope: nil,
                createdAt: storageClock.now()
            )
            let stamped = StampedCommitPlan(
                position: nextPosition,
                mutations: mutations,
                receiptOutcome: receiptOutcome,
                hcrAppend: hcrAppend
            )
            _ = try executeStampedPlan(
                stamped,
                expectedPreviousPosition: expectedPreviousPosition,
                in: database
            )
            return nextPosition
        }
    }

    /// The same durable aggregate changed by the production transaction;
    /// batch setup never materializes a process-wide retained ID collection.
    private func performanceFixtureRetainedCount() throws -> Int {
        let statement = try database.prepare(
            "SELECT retainedItemCount FROM history_state WHERE key = ?",
            bindings: [.text(Self.positionSingletonKey)]
        )
        defer { statement.finalize() }
        guard try statement.step(),
              let count = Int(exactly: try statement.integer(at: 0)),
              count >= 0 else {
            throw HistoryFailure.persistence(.corruptStoredValue)
        }
        return count
    }

}
