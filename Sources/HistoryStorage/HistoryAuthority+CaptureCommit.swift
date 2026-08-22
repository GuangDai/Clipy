/// Capture-commit path (§7.1 fact loading, §9 stamped plan, §11 post-commit).
/// Split out of HistoryAuthority.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

extension HistoryAuthority {
    // MARK: Capture commit (docs/05-authority-kernel.md §7.1, §9–§11)

    /// Commits one prepared capture: load proven-complete facts, plan
    /// purely, stamp mechanically, apply one atomic transaction, then apply
    /// the post-commit order without suspension.
    /// docs/05-authority-kernel.md §9 (the exact flow), §7.1, §10, §11
    ///
    /// Flow (§9): create operation-local context → load exact facts via
    /// `IngestFactLoader` (which rebuilds the Signature Index first when
    /// unready, §7.1 step 1) → `planCapture` (which always commits insert or
    /// coalesce) → stamp via `CommitPlanStamper` →
    /// prevalidate the index delta (§9) → one `ModelContext.transaction`
    /// (§10) → nonthrowing Signature Index delta → synchronous invalidation
    /// yield → `.committed` receipt (§11).
    ///
    /// The single-writer interval contains no `await`: the only suspension
    /// is the roadmap-owned test point at entry, before the context exists
    /// (§5).
    ///
    /// - Throws: the fact loader's typed failures
    ///   (`.temporarilyUnavailable(.factProof)` / `.dedupIndexRebuild`,
    ///   `.persistence(...)`); the mapped `DomainRejection` vocabulary
    ///   (docs/02-domain.md §6); `StampingRejection` /
    ///   `CodecRejection.encodingFailed` via their §16 mappings;
    ///   `.persistence(.invariantViolation)` when the planner's winner is
    ///   absent from the loaded facts (defensive);
    ///   `.persistence(.transaction)` for any transaction-closure failure
    ///   including the armed WS13 injection (§16).
    internal func commitCapture(
        _ prepared: PreparedCaptureBundle
    ) async throws -> HistoryReceipt {
        // Roadmap-owned test seam: the one legal suspension point of this
        // path — no context, row, fact, or plan is live yet (§5).
        await suspendIfRequested(.captureCommitEntry)

        let receipt = try autoreleasepool {
            try commitCaptureInLocalContext(prepared)
        }
#if DEBUG
        storageLifecycleDebugProbe.record(phase: .captureAutoreleasePoolDrained)
#endif
        return receipt
    }

    /// The synchronous half of `commitCapture`, split out so every context,
    /// fetched row, fact, and plan is released before its caller drains the
    /// operation-local autorelease pool.
    internal func commitCaptureInLocalContext(
        _ prepared: PreparedCaptureBundle
    ) throws -> HistoryReceipt {
        let context = ModelContext(container)
        context.autosaveEnabled = false
#if DEBUG
        let captureFactLoadClock = ContinuousClock()
        let captureFactLoadStart = captureFactLoadClock.now
        storageLifecycleDebugProbe.record(phase: .captureFactLoadBegin)
#endif

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard) and the authoritative retention policy (§3.2).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, retention) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // §7.1: complete facts, rebuilding the index first when unready (the
        // loader returns the wholesale `SignatureIndex.build` replacement).
        let load = try IngestFactLoader.loadFacts(
            in: context,
            prepared: prepared.domain,
            signatureIndex: signatureIndex,
            limits: limits
        )
        signatureIndex = load.signatureIndex
#if DEBUG
        storageLifecycleDebugProbe.record(
            phase: .captureFactLoadComplete,
            elapsed: captureFactLoadStart.duration(to: captureFactLoadClock.now)
        )
#endif

        // Pure planning (docs/02-domain.md §8): insert-or-coalesce plus
        // same-commit retention victims.
        let planningResult: PlanningResult
        do {
            planningResult = try planCapture(
                prepared.domain,
                facts: load.facts,
                retention: retention,
                hardMaximumRetainedItems: limits.hardMaximumRetainedItems
            )
        } catch let rejection as DomainRejection {
            throw rejection.historyFailure
        }

        guard case .commit(let v1Plan) = planningResult else {
            // `planCapture` has no no-op outcome: equal content coalesces and
            // distinct content inserts (docs/02-domain.md §9). Fail closed if
            // that planner contract ever drifts behind the shared result type.
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // V2-02 §4.2 capture composition (roadmap R.4): when R1/R2 is
        // active, plan the retention expansion over the projected
        // post-primary post-count inventory and merge its retirements after
        // the v1 mutations — one Domain plan below, so the existing tail
        // still stamps ONE ChangePosition, builds ONE index delta (each
        // retirement entering the removals exactly as v1 count-retirements
        // do), and transacts ONE `ModelContext.transaction`, with the
        // receipt outcome unchanged (§4.2 "outcome = v1Plan.outcome"). An
        // R3-only or all-disabled config returns the v1 plan untouched with
        // NO expansion fact load (§4.2/§7), and the §8.3 pre-plan R2
        // infeasibility throws here — before any stamp or transaction — so
        // the primary insert never lands.
        let mutationPlan = try composeRetentionExpansionForCapture(
            v1Plan,
            prepared: prepared,
            facts: load.facts,
            in: context
        )

        // Copy Coalescing preserves the winner's loaded Content Version
        // (docs/02-domain.md §13); the receipt reference names that exact
        // state. The planner chose the winner from these facts, so absence
        // is a contract violation, not data.
        let coalescedWinnerVersion: ContentVersion?
        switch mutationPlan.outcome {
        case .inserted:
            coalescedWinnerVersion = nil
        case .coalesced(let winnerID):
            guard let version = Self.loadedContentVersion(
                of: winnerID,
                in: load.facts
            ) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            coalescedWinnerVersion = version
        default:
            // planCapture emits only .inserted / .coalesced
            // (docs/02-domain.md §9).
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // §9: mechanical stamping — the Domain never mints tokens
        // (docs/02-domain.md §4, §13).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .capture(
                    projection: prepared.projection,
                    coalescedWinnerVersion: coalescedWinnerVersion
                )
            )
        } catch let rejection as StampingRejection {
            throw rejection.historyFailure
        } catch let rejection as CodecRejection {
            throw rejection.historyFailure
        }

#if DEBUG
        let captureTransactionClock = ContinuousClock()
        let captureTransactionStart = captureTransactionClock.now
        storageLifecycleDebugProbe.record(phase: .captureTransactionBegin)
#endif
        let receipt = try executeStampedPlan(
            stamped,
            expectedPreviousPosition: currentPosition,
            in: context
        )
#if DEBUG
        storageLifecycleDebugProbe.record(
            phase: .captureTransactionComplete,
            elapsed: captureTransactionStart.duration(to: captureTransactionClock.now)
        )
#endif
        return receipt
    }

    // MARK: Stamped-plan commit tail (docs/05-authority-kernel.md §9–§11)

    /// §9–§11 tail shared by capture and mutation commits: prevalidate the index delta,
    /// execute the one atomic transaction, then apply the post-commit order
    /// without suspension (index delta → invalidation → committed receipt).
    /// docs/05-authority-kernel.md §9, §10, §11
    ///
    /// Capture owns its §7.1 rebuild before planning, then joins the same tail
    /// as every mutation: context → singleton → facts → plan → stamp → tail.
    ///
    /// - Throws: `.persistence(.invariantViolation)` when the delta
    ///   prevalidation fails — an internal invariant violation raised before
    ///   any durable write (§12, §16); `.persistence(.transaction)` for any
    ///   transaction-closure failure (§16).
    internal func executeStampedPlan(
        _ stamped: StampedCommitPlan,
        expectedPreviousPosition: ChangePosition,
        in context: ModelContext,
        createExistenceProof: CreateExistenceProof = .durableLookup
    ) throws -> HistoryReceipt {
        // §9: prevalidate the index delta before the transaction so the
        // §11 post-commit dictionary application cannot fail after durable
        // commit. A prevalidation failure happens before any durable write
        // and is an internal invariant violation (§12, §16).
        do {
            try signatureIndex.validate(stamped.indexDelta)
        } catch {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // The fixture-only fast path substitutes the complete ready index for
        // one durable point query per create. Prove the plan is exactly a set
        // of matching creates/additions before that proof can reach the
        // transaction executor. The ordinary public path never selects it.
        if case .readySignatureIndex = createExistenceProof {
            var createIDs = Set<HistoryItemID>(
                minimumCapacity: stamped.mutations.count
            )
            for mutation in stamped.mutations {
                guard case .create(let item) = mutation,
                      createIDs.insert(item.id).inserted
                else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
            }
            guard signatureIndex.state == .ready,
                  stamped.indexDelta.removals.isEmpty,
                  createIDs == Set(stamped.indexDelta.additions.keys)
            else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }

        // §10: the only durable History Commit primitive. Closure success is
        // the commit boundary — no trailing save, no compensating rollback.
        try executeCommitTransaction(
            stamped,
            expectedPreviousPosition: expectedPreviousPosition,
            in: context,
            createExistenceProof: createExistenceProof
        )

        // §11 post-commit order, still isolated and without suspension:
        // 1. apply the already validated nonthrowing Signature Index delta
        //    (on detected divergence the index marks itself unready and the
        //    committed state stays authoritative, §11–§12);
        signatureIndex.apply(stamped.indexDelta)
        // 2. synchronously yield one invalidation to registered
        //    continuations (docs/04-coherence.md §4);
        invalidationPublisher.publish(
            HistoryInvalidation(latestPosition: stamped.position)
        )
        // 3. construct and return the committed receipt, including the
        //    stamped retention-effect fact (never a victim list).
        return .committed(HistoryCommit(
            position: stamped.position,
            outcome: stamped.receiptOutcome,
            hasDestructiveRetentionEffects:
                stamped.hasDestructiveRetentionEffects
        ))
    }

}
