/// Revision and retention-policy mutations (roadmap step 6).
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension HistoryAuthority {
    /// The phase-1 inputs of the V2-extended two-phase revise (`V2-02` §4.3
    /// PHASE 1; `V2-roadmap` §6 R.5): the v1 OCC snapshot plus the current
    /// retention policies, both captured inside ONE serialized Authority
    /// interval over one operation-local context — Record 2's
    /// policy-sourcing mechanism ("the `HistoryAuthority` reads the current
    /// `RetentionExpansionConfigRow` R3 policies in the same serialized
    /// Authority interval that captures the snapshot ... and threads them as
    /// a sibling V2 input to the V2-extended preparation call"). The
    /// off-Authority preparation actor performs no durable-state read of its
    /// own.
    ///
    /// The policy read uses the revise-lane gate (`loadReviseLanePolicies`):
    /// `nil` for an R1-only or all-disabled config means phase 1 runs the
    /// v1 preparation unchanged. Phase 2 re-reads the policies
    /// independently (`commitRevision`'s composition), never this copy
    /// (§4.3 "Phase-2 policy re-read").
    ///
    /// - Throws: exactly `revisionPreparationSnapshot`'s failures plus the
    ///   config loader's typed failures (`.temporarilyUnavailable(
    ///   .factProof)` / `.persistence(...)`).
    internal func revisionPreparationInputs(
        _ request: RevisionRequest
    ) async throws -> (
        snapshot: RevisionPreparationSnapshot,
        retentionPolicies: HistoryRetentionPolicies?
    ) {
        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending read interval (§5): no `await` past this line
        //    while the context or fetched row is live. ──

        // §7.3: fetch and decode exactly the target item.
        guard let row = try HistoryItemRowHydration.fetchRow(
            businessID: request.itemID,
            in: context
        ) else {
            throw HistoryFailure.notFound(request.itemID)
        }
        let item = try HistoryItemRowHydration.hydrate(row, limits: limits)

        // §6.2: reject immediately when the OCC token is already stale —
        // the expensive resolution/projection phase never runs for a
        // proposal that cannot commit.
        guard request.expected == item.contentVersion else {
            throw HistoryFailure.staleContent(
                expected: request.expected,
                current: item.contentVersion
            )
        }

        return (
            snapshot: RevisionPreparationSnapshot(
                canonical: item.canonical,
                revisions: item.revisions,
                activeRevisionID: item.activeRevisionID,
                contentVersion: item.contentVersion
            ),
            retentionPolicies: try RetentionConfigLoading.loadReviseLanePolicies(
                in: context
            )
        )
    }

    /// The v1 phase-1 snapshot entry (docs/05-authority-kernel.md §6.2),
    /// retained as the v1 seam the WS20 harness drives; it is the snapshot
    /// half of `revisionPreparationInputs` (the V2 sibling-input read is
    /// simply skipped for callers that do not thread policies).
    internal func revisionPreparationSnapshot(
        _ request: RevisionRequest
    ) async throws -> RevisionPreparationSnapshot {
        try await revisionPreparationInputs(request).snapshot
    }

    /// Phase two of the OCC-safe revision commit (§6.2): reload the
    /// target's complete lineage, recheck the OCC token through pure
    /// planning, stamp from the reloaded facts, then run the shared commit
    /// tail.
    /// docs/05-authority-kernel.md §6.2, §9 (the exact flow), §7.3, §10,
    /// §11; docs/02-domain.md §11 (revision planning and OCC)
    ///
    /// Flow (§9): create operation-local context → read the singleton
    /// position → load `RevisionFacts` via `MutationFactLoaders` — exactly
    /// the target item, fully decoded (§7.3); a missing target fails the
    /// load as `.notFound` → `planRevision` (OCC, base-version, and
    /// normalization rechecks; a byte-identical proposal is `.unchanged`)
    /// → the V2-02 §4.3 revise composition when R2/R3 is active (roadmap
    /// R.5; prune recomputed over the reloaded lineage, R2 planned over the
    /// projected post-prune post-append inventory, one merged plan)
    /// → stamp with `.revision` inputs taken from the reloaded facts →
    /// `executeStampedPlan` (the transaction executor re-verifies
    /// `expectedCurrentVersion`, §10).
    ///
    /// The single-writer interval contains no `await`: the only suspension
    /// is the roadmap-owned WS20 test point at entry, before the context
    /// exists (§5).
    ///
    /// - Throws: the fact loader's typed failures (`.notFound`,
    ///   `.temporarilyUnavailable(.factProof)`, `.persistence(...)`); the
    ///   mapped `DomainRejection` vocabulary — `.staleContent` on the OCC
    ///   recheck, `.invalidInput(.incoherentRevisionDraft)` on a draft
    ///   failing Domain revalidation (docs/02-domain.md §6, §11);
    ///   `StampingRejection` / `CodecRejection.encodingFailed` via their
    ///   §16 mappings; `.persistence(.transaction)` for any
    ///   transaction-closure failure (§16).
    internal func commitRevision(
        _ request: RevisionRequest,
        _ bundle: PreparedRevisionBundle
    ) async throws -> HistoryReceipt {
        // Roadmap-owned WS20 test seam: the one legal suspension point of
        // this path — no context, row, fact, or plan is live yet (§5).
        await suspendIfRequested(.revisionCommitEntry)

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

        // §7.3: fetch and decode exactly the target item.
        let facts = try MutationFactLoaders.loadRevisionFacts(
            itemID: request.itemID,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §11): the Domain rechecks
        // the OCC token and the preparation's base version against the
        // reloaded facts.
        let planningResult: PlanningResult
        do {
            planningResult = try planRevision(
                request: request,
                prepared: bundle.domain,
                facts: facts
            )
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let v1Plan) = planningResult else {
            // §9: release the context and return — nothing is retained
            // across the operation (§5), and a no-op yields no receipt,
            // index delta, or invalidation (docs/04-coherence.md §4).
            return .unchanged
        }

        // V2-02 §4.3 revise composition (roadmap R.5): when R2 or R3 is
        // active, recompute the prune set over the RELOADED lineage, project
        // the R2 inventory to the post-prune post-append state, and merge
        // the prune + R2 retirements after the v1 mutations — one Domain
        // plan below, so the existing tail still stamps ONE ChangePosition
        // and the stamper's compose-with-append fold (§6.3, RET-STAMP-1)
        // emits ONE `.appendRevision` blob write for the revised item. An
        // R1-only or all-disabled config returns the v1 plan untouched (§7);
        // the §8.3 revise-time failures (`.capacityExceeded(.revisionBytes)`
        // unsatisfiable prune, `.capacityExceeded(.storageBytes)`
        // irreducible budget) throw here — before any stamp or transaction,
        // so nothing durable exists.
        let mutationPlan = try composeRetentionExpansionForRevision(
            v1Plan,
            bundle: bundle,
            facts: facts,
            in: context
        )

        // §9: mechanical stamping from the reloaded facts — the item's
        // current Content Version, its complete existing revision list,
        // and the prepared revision projection (§6.2). The §6.3
        // compose-with-append fold reads the prune set from the Domain plan
        // itself, so these inputs are exactly the v1 shape.
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .revision(
                    currentVersion: facts.item.contentVersion,
                    existingRevisions: facts.item.revisions,
                    projection: bundle.projection
                )
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

    /// Commits one retention-policy change: validate the value against the
    /// fixed Part VI user range at the boundary (§2, D19), load the
    /// complete retained-set inventory, plan purely, stamp mechanically,
    /// then run the shared commit tail.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.3, §10, §11;
    /// docs/02-domain.md §12 (retention)
    ///
    /// Flow (§9): boundary validation → create operation-local context →
    /// read the singleton position and the authoritative current policy
    /// (§3.2) → load `RetentionFacts` via `MutationFactLoaders` (§7.3) →
    /// `planRetention` (non-throwing — a same-value no-victim set is
    /// `.unchanged` before stamping, §9; docs/02-domain.md §12) → stamp
    /// (inputs `.none`) → `executeStampedPlan`.
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: `.invalidInput(.invalidRetentionPolicy)` for an
    ///   out-of-range value (§2, §16); the fact loader's typed failures;
    ///   `StampingRejection` / `CodecRejection.encodingFailed` via their
    ///   §16 mappings; `.persistence(.transaction)` for any
    ///   transaction-closure failure (§16).
    internal func commitRetentionPolicy(
        _ maximumUnpinnedItems: Int
    ) async throws -> HistoryReceipt {
        // §2, §16, D19: boundary validation before any context — the value
        // must lie in the fixed Part VI user range (which always permits at
        // least one unpinned item).
        guard limits.userMaximumUnpinnedRange.contains(maximumUnpinnedItems) else {
            throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
        }

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard) and the authoritative current retention policy
        // (§3.2).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, currentPolicy) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.3: every retained ID, last-copied time, and pin ordinal.
        let facts = try MutationFactLoaders.loadRetentionFacts(
            currentPolicy: currentPolicy,
            in: context,
            limits: limits
        )

        // Pure planning (docs/02-domain.md §8, §12): the policy write plus
        // any eviction victims, or `.unchanged` for a same-value no-victim
        // set.
        let planningResult = planRetention(
            facts: facts,
            policy: RetentionPolicy(maximumUnpinnedItems: maximumUnpinnedItems)
        )

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
                inputs: .none
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

}
