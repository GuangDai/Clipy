/// Package performance-fixture seeding
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

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
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
            let (position, retention) = try Self.decodePositionRow(
                positionRow,
                limits: limits
            )
            let retainedCount: Int
            do {
                retainedCount = try context.fetchCount(
                    FetchDescriptor<HistoryItemRow>()
                )
            } catch {
                throw HistoryFailure.persistence(.openStore)
            }

            guard retainedCount == 0,
                  position.rawValue == 0,
                  signatureIndex.state == .ready,
                  signatureIndex.itemCount == 0
            else {
                throw PerformanceFixtureSeedError.storeNotEmpty
            }
            guard finalRetainedCount <= retention.maximumUnpinnedItems,
                  finalRetainedCount <= limits.hardMaximumRetainedItems
            else {
                throw PerformanceFixtureSeedError.capacityExceeded
            }
            return position
        }
    }

    /// Commits one bounded fixture batch through the same stamped mutation,
    /// transaction, Signature Index, invalidation, and position tail as an
    /// ordinary History Commit. Each batch is one non-empty commit and thus
    /// advances Change Position exactly once, regardless of row count.
    internal func commitPerformanceFixtureSeedBatch(
        _ preparedItems: [PreparedCaptureBundle],
        expectedPreviousPosition: ChangePosition,
        expectedRetainedCount: Int
    ) async throws -> ChangePosition {
        try autoreleasepool {
            guard !preparedItems.isEmpty,
                  preparedItems.count <= SwiftDataHistory.performanceFixtureSeedBatchSize
            else {
                throw PerformanceFixtureSeedError.invalidRowCount
            }
            let (nextRetainedCount, retainedOverflow) = expectedRetainedCount
                .addingReportingOverflow(preparedItems.count)
            guard !retainedOverflow else {
                throw PerformanceFixtureSeedError.capacityExceeded
            }

            var seenIDs = Set<HistoryItemID>(minimumCapacity: preparedItems.count)
            var additions: [HistoryItemID: [ContentSignatureEntry]] = [:]
            additions.reserveCapacity(preparedItems.count)
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
                let encoded: EncodedNewItem
                do {
                    encoded = try CommitPlanStamper.encodeNewItem(
                        id: capture.candidateID,
                        canonical: capture.canonical,
                        projection: prepared.projection,
                        occurrence: occurrence
                    )
                } catch let rejection as CodecRejection {
                    throw rejection.historyFailure
                }
                let stored = encoded.stored
                guard prepared.signatureEntries == encoded.signatureEntries,
                      seenIDs.insert(stored.id).inserted
                else {
                    throw PerformanceFixtureSeedError.stateChanged
                }
                additions[stored.id] = encoded.signatureEntries
                mutations.append(.create(stored))
            }

            let context = ModelContext(container)
            context.autosaveEnabled = false
            let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
            let (position, retention) = try Self.decodePositionRow(
                positionRow,
                limits: limits
            )
            guard position == expectedPreviousPosition,
                  signatureIndex.state == .ready,
                  signatureIndex.itemCount == expectedRetainedCount
            else {
                throw PerformanceFixtureSeedError.stateChanged
            }
            guard nextRetainedCount <= retention.maximumUnpinnedItems,
                  nextRetainedCount <= limits.hardMaximumRetainedItems
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

            let stamped = StampedCommitPlan(
                position: nextPosition,
                mutations: mutations,
                receiptOutcome: .inserted(HistoryItemReference(
                    id: finalItem.id,
                    contentVersion: finalItem.contentVersion
                )),
                indexDelta: SignatureIndexDelta(
                    additions: additions,
                    removals: []
                )
            )
            _ = try executeStampedPlan(
                stamped,
                expectedPreviousPosition: expectedPreviousPosition,
                in: context,
                createExistenceProof: .readySignatureIndex
            )
            return nextPosition
        }
    }

}
