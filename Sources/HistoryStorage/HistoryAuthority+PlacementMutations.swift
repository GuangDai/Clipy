/// Placement mutations use scalar SQLite facts and the shared atomic
/// commit tail (05 §7.2–§7.3/§9–§11; V2-09 §6). Each actor interval is
/// non-suspending through planning and commit. executeStampedPlan owns the
/// mutation transaction; external no-ops use their existing audit transaction.
import Foundation
import HistoryCore
import HistoryDomain

extension HistoryAuthority {
    internal func commitPinnedPlacement(
        _ itemID: HistoryItemID,
        _ placement: PinnedPlacement,
        externalWrite: ExternalWriteCommitContext? = nil
    ) async throws -> HistoryReceipt {
        let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        let facts = try MutationFactLoaders.loadPinFacts(
            itemID: itemID,
            placement: placement,
            in: database,
            limits: limits
        )

        let planningResult: PlanningResult
        do {
            planningResult = try planPinnedPlacement(
                itemID: itemID,
                placement: placement,
                facts: facts
            )
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            if let externalWrite {
                try commitExternalWriteNoOpAudit(
                    externalWrite,
                    in: database
                )
            }
            return .unchanged
        }

        let stamped: StampedCommitPlan
        do {
            let committedAt = storageClock.now()
            let internalPlan = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none,
                createdAt: committedAt
            )
            stamped = try externalWrite.map {
                try Self.attachExternalWriteAudit(
                    to: internalPlan,
                    write: $0,
                    committedAt: committedAt
                )
            } ?? internalPlan
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: database
        )
    }

    internal func commitUnpin(
        _ itemID: HistoryItemID,
        externalWrite: ExternalWriteCommitContext? = nil
    ) async throws -> HistoryReceipt {
        let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        let facts = try MutationFactLoaders.loadPinFacts(
            itemID: itemID,
            in: database,
            limits: limits
        )

        let planningResult: PlanningResult
        do {
            planningResult = try planUnpin(itemID: itemID, facts: facts)
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            if let externalWrite {
                try commitExternalWriteNoOpAudit(
                    externalWrite,
                    in: database
                )
            }
            return .unchanged
        }

        let stamped: StampedCommitPlan
        do {
            let committedAt = storageClock.now()
            let internalPlan = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none,
                createdAt: committedAt
            )
            stamped = try externalWrite.map {
                try Self.attachExternalWriteAudit(
                    to: internalPlan,
                    write: $0,
                    committedAt: committedAt
                )
            } ?? internalPlan
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: database
        )
    }

    internal func commitRemove(
        _ itemID: HistoryItemID,
        externalWrite: ExternalWriteCommitContext? = nil
    ) async throws -> HistoryReceipt {
        let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        let facts = try MutationFactLoaders.loadRemoveFacts(
            itemID: itemID,
            in: database,
            limits: limits
        )

        let planningResult: PlanningResult
        do {
            planningResult = try planRemove(itemID: itemID, facts: facts)
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            if let externalWrite {
                try commitExternalWriteNoOpAudit(
                    externalWrite,
                    in: database
                )
            }
            return .unchanged
        }

        let stamped: StampedCommitPlan
        do {
            let committedAt = storageClock.now()
            let internalPlan = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none,
                createdAt: committedAt
            )
            stamped = try externalWrite.map {
                try Self.attachExternalWriteAudit(
                    to: internalPlan,
                    write: $0,
                    committedAt: committedAt
                )
            } ?? internalPlan
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: database
        )
    }

    internal func commitClear(_ scope: ClearScope) async throws -> HistoryReceipt {
        let positionRow = try Self.fetchExactlyOnePositionRow(in: database)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        let facts = try MutationFactLoaders.loadClearFacts(
            scope: scope,
            in: database,
            limits: limits
        )

        let planningResult = planClear(scope: scope, facts: facts)

        guard case .commit(let mutationPlan) = planningResult else {
            return .unchanged
        }

        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none,
                createdAt: storageClock.now(),
                clearScope: scope
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: database
        )
    }
}
