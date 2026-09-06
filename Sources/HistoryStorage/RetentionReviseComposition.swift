/// R.5 — the revise-lane retention-expansion composition (`V2-roadmap` §6
/// R.5 "Revise composition"): the `V2-02` §4.3 PHASE-2 merge that folds the
/// recomputed R3 prune and the R2 retirements into one v1 revise plan (v1
/// append first, prune after, retirements last) committed through the
/// unchanged v1 tail — one plan, one `ChangePosition` stamp, one
/// `ModelContext.transaction`, unchanged `.revised` receipt outcome.
/// Owning spec: docs/v2/V2-02-retention.md §4.3 (the authoritative revise
/// pseudocode: phase-2 prune recomputation over the reloaded lineage, the
/// projected post-prune post-append R2 inventory, `protected` =
/// pinned ∪ {revised item}, the merge order, and the phase-2 policy
/// re-read), §3.2 (the post-R3-prune projection: the R2 inventory's
/// `revisionBytes`/`revisionCount` computed over
/// `loadedRevisions \ removedRevisionIDs + [appendedRevision]` — one
/// Authority interval, not two fact loads), §5.1/§6.5 (the prune relation
/// and the `.revise(appended:)` target flavor), §6.3 (ONE merged plan:
/// compose-with-append folds the prune into the append's single blob write;
/// retire-subsumes-prune never arises on revise — R2 retires only OTHER
/// items and the revised item is protected, §7: revise = R2 + R3 only),
/// §7 (trigger matrix), §8.3 (revise-time unsatisfiable →
/// `.capacityExceeded(.revisionBytes)` atomic; R2 budget failure at revise →
/// `.capacityExceeded(.storageBytes)`), §11 D24 (single commit, victim
/// safety, byte-budget failure producer); Record 3 gates RET-PLATFORM-2
/// (scalar-only planning facts; the only revision decode is the v1-required
/// target load), RET-PRUNE-2 (R2 never credits soon-to-be-pruned revision
/// bytes), RET-CONCUR-1 (the phase-2 recomputation over reloaded facts).
///
/// Boundary (roadmap R.5/R.6): this file composes the REVISE lane only; the
/// `.setRetentionPolicies` sweep (§4.4) lives in RetentionPolicySweep.swift.
/// The StorageClock (`V2-02` §6.4) is deliberately unread here: §6.4 assigns
/// the Storage-side clock's retention use to the `.setRetentionPolicies`
/// sweep lane, and the revise lane's R1
/// reference is structurally skipped (§4.3/§7 — a revision does not change
/// `lastCopiedAt`), so `now` is the revision's own authoritative Storage
/// input (`PreparedRevision.createdAt`, minted in preparation exactly like
/// capture's `observedAt` is the capture's input) and the planner receives
/// it with the age lane stripped, where it selects nothing.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - Revise composition (V2-02 §4.3; V2-roadmap §6 R.5)

extension HistoryAuthority {

    /// The `V2-02` §4.3 revise composition, run between `planRevision` and
    /// stamping inside the revise commit interval:
    ///
    /// 1. Re-read the persisted policies for the revise lane (§4.3
    ///    "Phase-2 policy re-read" — the CURRENT config row, never the
    ///    phase-1 copy, so an interleaving policy change between the phases
    ///    is respected). `nil` (R1-only or all-disabled config) returns the
    ///    v1 plan untouched — the exact v1 revise route, with no prune
    ///    planning and no expansion fact load (§7).
    /// 2. **R3 first** (§3.2's compose-R3-then-R2 ordering): recompute the
    ///    prune set over the RELOADED lineage with the revise-path target
    ///    `.revise(appended:)` (§6.5) — the same pure computation phase 1
    ///    ran speculatively; it agrees whenever only a
    ///    coalescing/lineage-preserving commit interleaved (D16), and it is
    ///    correct for a reloaded post-interleave lineage whenever one did
    ///    not (the committed set is always computed from the reloaded
    ///    facts). The §8.3 revise-time unsatisfiable check re-runs here:
    ///    post-prune bytes still over `maxRevisionBytesPerItem` (the
    ///    appended now-active revision alone exceeds it) throws
    ///    `.capacityExceeded(.revisionBytes)` BEFORE anything is stamped or
    ///    transacted — the revise commits nothing.
    /// 3. When R2 is active, build the expansion inventory over the
    ///    PROJECTED post-revision state: every retained item's scalars come
    ///    from the `RetainedBytesRow` projection (§3.3b — scalar columns
    ///    only, zero blob decodes for the non-primary items,
    ///    `RET-PLATFORM-2`), while the REVISED item's
    ///    `revisionCount`/`revisionBytes` are projected in memory to
    ///    `(reloaded \ pruneSet) + [appendedRevision]` (§3.2's post-R3-prune
    ///    projection — the row is pre-commit and would understate the
    ///    append; R2 never credits soon-to-be-pruned revision bytes,
    ///    `RET-PRUNE-2`). `lastCopiedAt`/`pinOrdinal` come from the v1
    ///    retained inventory (a revision does not change `lastCopiedAt`,
    ///    §7).
    /// 4. Pre-plan R2 feasibility (§8.3): pinned bytes ∪ revised-item bytes
    ///    (the irreducible union — pinned items are never retired, D13, and
    ///    the revised item is the primary, plan invariant 7 / `02` §12)
    ///    over `maxTotalBytes` throws `.capacityExceeded(.storageBytes)`
    ///    before anything is stamped or transacted. Checked arithmetic
    ///    (`06` §2 no-wrap rule): overflow — impossible within the validated
    ///    §8.3 bounds but enforced defensively — fails closed as
    ///    `.persistence(.invariantViolation)`.
    /// 5. `planItemRetentionExpansion` with the age lane stripped (§4.3's
    ///    `policies.replacingAge(with: nil)` — R1 structurally skipped on
    ///    revise, §7), `protected` = pinned ∪ {revised item} (D13/D14/plan
    ///    invariant 7), and `now` = the revision's authoritative
    ///    `PreparedRevision.createdAt` (the Storage-minted Domain input the
    ///    lane has; the §6.4 clock belongs to the R.6 sweep lane, and the
    ///    stripped age lane makes `now` selection-inert on this path).
    /// 6. Merge (§4.3's exact order): `mutations = v1Plan.mutations +
    ///    .pruneRevisions(item, pruneSet) + expansion.retirements`, `outcome
    ///    = v1Plan.outcome` (retirements never change the `.revised`
    ///    receipt, §4.3). The merged Domain plan flows through the ONE
    ///    existing tail: `CommitPlanStamper.stamp` mints exactly one
    ///    `ChangePosition` successor and folds the prune into the append's
    ///    single blob write (§6.3 compose-with-append, `RET-STAMP-1`), each
    ///    retirement enters the index-delta removals exactly as v1
    ///    count-retirements do (`05` §9/§11), and `executeStampedPlan` →
    ///    `executeCommitTransaction` applies everything in one
    ///    `ModelContext.transaction` — the retirements' `.delete` arms also
    ///    removing each 1:1 projection row (R.3).
    ///
    /// - Throws: the config loader's typed failures;
    ///   `.temporarilyUnavailable(.factProof)` when a fact fetch cannot
    ///   complete; `.persistence(.invariantViolation)` for a
    ///   projection-row cardinality/coherence violation (a missing row for
    ///   an existing item is corruption, never a zero-byte read —
    ///   `V2-02` §3.2/Record 5), a non-append-led v1 plan, or a retirement
    ///   naming the revised item (defensive plan-invariant-7 backstop);
    ///   `.capacityExceeded(.revisionBytes)` for the §8.3 revise-time
    ///   unsatisfiable prune; `.capacityExceeded(.storageBytes)` for the
    ///   §8.3 pre-plan infeasibility.
    internal func composeRetentionExpansionForRevision(
        _ v1Plan: MutationPlan,
        bundle: PreparedRevisionBundle,
        facts: RevisionFacts,
        in context: ModelContext
    ) throws -> MutationPlan {
        // §4.3 PHASE 2 policy re-read; §7: nil (R1-only or all-disabled)
        // means the revise is exactly v1 — no prune, no expansion load.
        guard let policies = try RetentionConfigLoading.loadReviseLanePolicies(
            in: context
        ) else {
            return v1Plan
        }

        // The appended revision comes from the v1 plan itself: `planRevision`
        // always commits exactly one `.appendRevision` mutation (docs/02-
        // domain.md §11 step 6). A plan not led by the append is a
        // planner-contract violation, not data.
        guard case .appendRevision(
            let revisedItemID,
            let appendedRevision,
            _
        ) = v1Plan.mutations.first else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // ── R3 first: recompute the prune set over the RELOADED lineage ──
        // (§4.3 PHASE 2; §6.5's `.revise(appended:)` target flavor — the
        // effective list is `reloaded + [appended]` and the active is the
        // appended ID, so the planner can never return the appended or any
        // revision it saw as the active.)
        var pruneSet: [RevisionID] = []
        if let revisionPolicy = policies.revisions {
            pruneSet = planRevisionRetentionExpansion(
                revisions: facts.item.revisions,
                target: .revise(appended: appendedRevision),
                policies: HistoryRetentionPolicies(
                    age: nil,
                    storage: nil,
                    revisions: revisionPolicy
                )
            )
        }
        // §3.2: measure only the retained lineage plus the appended active
        // revision. A lazy filter avoids copying a survivor array, and R3
        // no longer measures the full unpruned list before measuring it again.
        let prunedIDs = Set(pruneSet)
        let retained = RetainedBytesStamping.revisionScalars(
            of: facts.item.revisions.lazy.filter { !prunedIDs.contains($0.id) }
        )
        let appended = RetainedBytesStamping.revisionScalars(
            of: CollectionOfOne(appendedRevision)
        )
        let projectedRevisionScalars = RetainedRevisionScalars(
            count: retained.count + appended.count,
            bytes: retained.bytes + appended.bytes
        )
        if let revisionPolicy = policies.revisions {
            // §8.3 revise-time unsatisfiable, re-checked at commit: a
            // post-prune byte total still over `maxRevisionBytesPerItem`
            // means the appended (now-active) revision alone exceeds the
            // threshold (the active is never prunable, D3/D23 — the planner
            // already returned the full inactive prefix). Fail closed before
            // any stamp or transaction; the revise commits nothing (§2.2).
            // The count dimension is always satisfiable on revise (§4.3),
            // so only the byte dimension is checked.
            if let maxRevisionBytes = revisionPolicy.maxRevisionBytesPerItem,
               projectedRevisionScalars.bytes > maxRevisionBytes {
                throw HistoryFailure.capacityExceeded(.revisionBytes)
            }
        }

        // ── R2 over the projected post-prune post-append inventory (§3.2) ──
        var retirements: [HistoryMutation] = []
        if policies.storage != nil {
            // The v1 retained inventory supplies `lastCopiedAt`/`pinOrdinal`
            // (scalar projection columns, §7.2/§7.3); the byte/revision
            // scalars come from the `RetainedBytesRow` projection — zero
            // blob decodes for the non-primary items (`RET-PLATFORM-2`; the
            // only revision decode on this path is the v1-required target
            // load `commitRevision` already performed, §4.3 "no extra
            // revision decode for the revised item").
            let inventory = try HistoryItemRowHydration.fetchRetainedInventory(
                in: context,
                limits: limits
            )
            let scalarsByItem = try RetentionConfigLoading.fetchProjectedScalars(
                in: context,
                limits: limits
            )
            // Fact completeness both directions (§3.2, D8): the 1:1 law makes
            // the row set equal to the retained set; a divergence is
            // corruption, never a partial fact.
            guard Set(scalarsByItem.keys) == Set(inventory.map(\.id)) else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            var items: [RetentionExpansionItemSummary] = []
            items.reserveCapacity(inventory.count)
            for summary in inventory {
                guard let scalars = scalarsByItem[summary.id] else {
                    // Unreachable after the both-directions check; kept as
                    // the fail-closed defensive path (§3.2: never a
                    // zero-byte read).
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                // §3.2 post-R3-prune projection: the revised item is credited
                // its post-prune post-append revision summary, not its
                // (pre-commit) row; every other item reads its row scalars.
                let revisionCount: Int
                let revisionBytes: Int
                if summary.id == revisedItemID {
                    revisionCount = projectedRevisionScalars.count
                    revisionBytes = projectedRevisionScalars.bytes
                } else {
                    revisionCount = scalars.revisionCount
                    revisionBytes = scalars.revisionBytes
                }
                items.append(RetentionExpansionItemSummary(
                    id: summary.id,
                    // §7: a revision does not change `lastCopiedAt`, so the
                    // stored occurrence recency IS the post-revision value.
                    lastCopiedAt: summary.lastCopiedAt,
                    pinOrdinal: summary.pinOrdinal,
                    canonicalBytes: scalars.canonicalBytes,
                    revisionCount: revisionCount,
                    revisionBytes: revisionBytes
                ))
            }
            // The inventory loader already orders by ID; mapping its rows
            // preserves that order without another sort (D16).

            // `protected` = pinned ∪ {revised item} (§4.3; D13/D14/plan
            // invariant 7). No count victims exist on this lane — the v1
            // revise plan is the append alone (`02` §11).
            var protected = Set<HistoryItemID>(minimumCapacity: inventory.count)
            protected.insert(revisedItemID)
            for summary in inventory
            where summary.pinOrdinal != nil {
                protected.insert(summary.id)
            }

            // ── Pre-plan R2 feasibility (§8.3) ──
            // The irreducible union — pinned bytes ∪ revised-item bytes —
            // counted once per item (a pinned revised item is both): no
            // victim selection can reduce it, because pinned items are never
            // retired (D13) and the revised item never is (plan invariant
            // 7). This throw lands BEFORE stamping and before the
            // transaction, so nothing durable exists — the revise does not
            // land (atomicity).
            if let storagePolicy = policies.storage {
                var irreducibleBytes = 0
                for item in items
                where item.pinOrdinal != nil || item.id == revisedItemID {
                    let (footprint, footprintOverflow) = item.canonicalBytes
                        .addingReportingOverflow(item.revisionBytes)
                    guard !footprintOverflow else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    let (total, totalOverflow) = irreducibleBytes
                        .addingReportingOverflow(footprint)
                    guard !totalOverflow else {
                        throw HistoryFailure.persistence(.invariantViolation)
                    }
                    irreducibleBytes = total
                }
                guard irreducibleBytes <= storagePolicy.maxTotalBytes else {
                    throw HistoryFailure.capacityExceeded(.storageBytes)
                }
            }

            // ── Pure R2 planning (§4.3) ──
            // The age lane is stripped ("policies.replacingAge(with: nil)",
            // §4.3 — R1 structurally skipped on revise, §7), so this call is
            // R2-only; `now` is the revision's authoritative Storage-minted
            // input and is selection-inert with the age lane nil (§6.4
            // assigns the clock's retention use to the R.6 sweep lane).
            let expansion = planItemRetentionExpansion(
                inventory: CompleteRetentionExpansionInventory(items: items),
                policies: HistoryRetentionPolicies(
                    age: nil,
                    storage: policies.storage,
                    revisions: nil
                ),
                protected: protected,
                now: bundle.domain.createdAt
            )
            retirements = expansion.retirements

            // Defensive plan-invariant-7 backstop: the planner's `protected`
            // filter already makes a revised-item retirement impossible;
            // failing closed here keeps this composition honest if that
            // contract ever drifts.
            for retirement in retirements {
                guard case .retire(let itemID, _) = retirement,
                      itemID != revisedItemID else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
            }
        }

        // The merge (§4.3's exact order): v1 append first, the prune after,
        // retirements last — one deterministic order; the outcome is the v1
        // plan's (the prune/retirements do NOT change the `.revised`
        // receipt). The prune mutation is emitted only when non-empty (§5.3:
        // a no-op prune never reaches the plan), and the stamper's §6.3
        // compose-with-append fold consumes it into the append's single blob
        // write (RET-STAMP-1).
        var mutations = v1Plan.mutations
        if !pruneSet.isEmpty {
            mutations.append(.pruneRevisions(
                itemID: revisedItemID,
                removedRevisionIDs: pruneSet
            ))
        }
        mutations.append(contentsOf: retirements)
        return MutationPlan(outcome: v1Plan.outcome, mutations: mutations)
    }
}
