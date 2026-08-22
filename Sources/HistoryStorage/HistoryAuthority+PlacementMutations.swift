/// Placement mutations: pin/unpin/remove/clear (roadmap step 6).
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension HistoryAuthority {
    // MARK: - Mutation commits (docs/roadmap/03-historystorage.md step 6)

    // The step-6 mutation commits: pin placement, unpin, remove, clear,
    // retention policy, and the §6.2 two-phase revision. Each reuses the
    // capture path's spine — operation-local context, singleton position,
    // complete facts (§7.2–§7.3, via `MutationFactLoaders`), pure planning,
    // mechanical stamping, and the shared `executeStampedPlan` tail
    // (§9–§11) — with no `await` past context creation (§5).

    /// Commits one pin placement: load proven-complete pin facts, plan
    /// purely, stamp mechanically, then run the shared commit tail.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.2, §10, §11;
    /// docs/02-domain.md §10 (pinned order)
    ///
    /// Flow (§9): create operation-local context → read the singleton
    /// position → load `PinFacts` via `MutationFactLoaders` (target
    /// existence plus the validated complete pinned order, §7.2) →
    /// `planPinnedPlacement` → `.unchanged` releases the context and
    /// returns (no receipt, index delta, or invalidation,
    /// docs/04-coherence.md §4) → stamp (inputs `.none` — pin plans stamp
    /// from the Domain payloads alone) → `executeStampedPlan`.
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: the fact loader's typed failures
    ///   (`.temporarilyUnavailable(.factProof)`, `.persistence(...)`); the
    ///   mapped `DomainRejection` vocabulary — placement rejects through
    ///   `.invalidPinnedPlacement`, never `.notFound` (docs/02-domain.md §6,
    ///   §10; docs/03b-instruction-set.md §10); `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   (§16).
    internal func commitPinnedPlacement(
        _ itemID: HistoryItemID,
        _ placement: PinnedPlacement
    ) async throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.2: target existence plus every pinned row, validated into the
        // complete pinned order (D12).
        let facts = try MutationFactLoaders.loadPinFacts(
            itemID: itemID,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §10).
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
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none,
                createdAt: storageClock.now()
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    /// Commits one unpin: load proven-complete pin facts, plan purely,
    /// stamp mechanically, then run the shared commit tail.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.2, §10, §11;
    /// docs/02-domain.md §10 (pinned order)
    ///
    /// Identical spine to `commitPinnedPlacement`; `planUnpin` returns
    /// `.unchanged` when the target exists but is not pinned
    /// (docs/03a-instruction-set.md §5).
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: the fact loader's typed failures; the mapped
    ///   `DomainRejection` vocabulary — unpin rejects a missing target as
    ///   `.notFound` (docs/02-domain.md §6, §10); `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   (§16).
    internal func commitUnpin(_ itemID: HistoryItemID) async throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.2: target existence plus the complete pinned order — unpin
        // shifts every later pinned item (docs/02-domain.md §10).
        let facts = try MutationFactLoaders.loadPinFacts(
            itemID: itemID,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §10).
        let planningResult: PlanningResult
        do {
            planningResult = try planUnpin(itemID: itemID, facts: facts)
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none,
                createdAt: storageClock.now()
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    /// Commits one removal: load the target's scalar summary plus the
    /// complete pinned order, plan purely, stamp mechanically, then run the
    /// shared commit tail.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.3, §10, §11;
    /// docs/02-domain.md §10 (pinned-lane compaction), D15 (no tombstone)
    ///
    /// Flow (§9): create operation-local context → read the singleton
    /// position → load `RemoveFacts` via `MutationFactLoaders` (§7.3) →
    /// `planRemove` — removing a pinned item compacts the pinned lane in
    /// the same commit, so the §10 final-order revalidation cannot fail on
    /// a gap (docs/02-domain.md §10, D12) → stamp (inputs `.none`) →
    /// `executeStampedPlan`.
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: the fact loader's typed failures; the mapped
    ///   `DomainRejection` vocabulary — remove rejects a missing target as
    ///   `.notFound` (docs/02-domain.md §6); `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   (§16).
    internal func commitRemove(_ itemID: HistoryItemID) async throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.3: the target's scalar summary plus the complete pinned order
        // (the §7.2 load).
        let facts = try MutationFactLoaders.loadRemoveFacts(
            itemID: itemID,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §5.4).
        let planningResult: PlanningResult
        do {
            planningResult = try planRemove(itemID: itemID, facts: facts)
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .none,
                createdAt: storageClock.now()
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

        return try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
    }

    /// Commits one clear: load the complete affected set `scope` selects at
    /// this linearization point, plan purely, stamp mechanically, then run
    /// the shared commit tail. There is no partial clear
    /// (docs/02-domain.md §5.4).
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.3, §10, §11
    ///
    /// Flow (§9): create operation-local context → read the singleton
    /// position → load `ClearFacts` via `MutationFactLoaders` (§7.3) →
    /// `planClear` (non-throwing — an empty affected set is `.unchanged`,
    /// never a rejection, docs/02-domain.md §8) → stamp (inputs `.none`) →
    /// `executeStampedPlan`.
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: the fact loader's typed failures; `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   (§16).
    internal func commitClear(_ scope: ClearScope) async throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.3: every ID/pin value selected by scope.
        let facts = try MutationFactLoaders.loadClearFacts(
            scope: scope,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §5.4): retire exactly the
        // affected set in one commit.
        let planningResult = planClear(scope: scope, facts: facts)

        guard case .commit(let mutationPlan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
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
            in: context
        )
    }

    /// Phase one of the OCC-safe two-phase revision preparation (§6.2):
    /// fetch and fully hydrate the target in one non-suspending read-only
    /// interval, reject an already-stale `request.expected` immediately,
    /// and return the validated lineage as a Sendable
    /// `RevisionPreparationSnapshot` — no row or context escapes (§5).
    /// docs/05-authority-kernel.md §6.2, §5, §7.3
    ///
    /// This interval is not a commit: there is no receipt, index delta, or
    /// invalidation (docs/04-coherence.md §4).
    ///
    /// - Throws: `.notFound(request.itemID)` when the target is not
    ///   retained; `.staleContent(expected:current:)` when the item's
    ///   Content Version already differs from the request's OCC token
    ///   (§6.2); the hydration decode mappings
    ///   (`.persistence(.corruptStoredValue)`, §4/§16) and the bounded
    ///   business-ID fetch's `.temporarilyUnavailable(.factProof)` (§16).
}
