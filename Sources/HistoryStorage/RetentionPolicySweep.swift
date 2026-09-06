/// R.6 — the `.setRetentionPolicies` policy sweep (`V2-roadmap` §6 R.6
/// "Policy sweep"): the full R1 + R2 + R3 composition of `V2-02` §4.4,
/// committed through the unchanged v1 tail — one plan, one `ChangePosition`
/// stamp, one `ModelContext.transaction`, `.retentionPoliciesSet(retiredItems:
/// prunedRevisions:)` receipt.
/// Owning spec: docs/v2/V2-02-retention.md §4.4 (the authoritative sweep
/// pseudocode with the DC-27 resolution: PHASE A plans R3 prunes per
/// exceeding item WITHOUT the veto; PHASE B projects the post-prune inventory
/// and runs R1+R2 with `protected` = pinned only; PHASE C is the
/// unsatisfiable-R3 veto scoped to PHASE-B SURVIVORS; then the
/// same-policy-satisfied `.unchanged` no-op check; the merged mutations =
/// retirements + per-item `.pruneRevisions` (dropped for R2-retired items) +
/// `.setRetentionPolicies(newPolicies)`), §3.2 (the post-R3-prune projection:
/// the R2 inventory's `revisionBytes`/`revisionCount` computed over
/// `loadedRevisions \ removedRevisionIDs` — one Authority interval, not two
/// fact loads, `RET-PRUNE-2`), §5.5 (R3 on `.setRetentionPolicies`: no
/// append; the `.setRetentionPolicies(activeRevisionID:)` target), §5.6 (the
/// policy-persisting mutation and its stamping — D18: explicit mutation,
/// never an outcome side-effect), §6.3 (retire-subsumes-prune: the composer
/// drops `.pruneRevisions` for items the same commit retires BEFORE stamping,
/// `RET-STAMP-2`), §6.4 (the Storage clock is THIS lane's seam — `now` for
/// the sweep comes from `storageClock.now()`, captured once per commit inside
/// the serialized Authority interval before fact load), §7 (sweep =
/// R1+R2+R3), §8.3 (boundary validation via
/// `RetentionPolicyBounds.validate` → `.invalidInput(.invalidRetentionPolicy)`
/// before any store work; the PHASE-C veto and the pinned-byte/budget
/// boundary equivalent share that producer; a same-value satisfied state is
/// a true `.unchanged`: no commit, no position advance, no invalidation —
/// the v1 WS21 posture), §8.1 (`prunedRevisions` counts only SURVIVING
/// items' prunes), §11 D24 (single commit, victim safety); Record 3 gates
/// `RET-PERF-2` (scalar exceedance detection — lineages decoded ONLY for
/// exceeding items; each decoded item is then checked for exact projection /
/// lineage equality before planning), `RET-PRUNE-2`, `RET-STAMP-2`,
/// `RET-SECURITY-1`.
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - Policy sweep (V2-02 §4.4; V2-roadmap §6 R.6)

extension HistoryAuthority {

    /// Commits one V2 retention-policy change: the `V2-02` §4.4 sweep.
    ///
    /// Flow (§4.4's pseudocode, in order):
    ///
    /// 1. **Boundary validation** (§8.3) before any store work:
    ///    `RetentionPolicyBounds.validate` rejects an out-of-range / NaN /
    ///    inconsistent value as `.invalidInput(.invalidRetentionPolicy)` —
    ///    the analog of `commitRetentionPolicy`'s Part VI range check.
    /// 2. **Clock read** (§6.4): `now = storageClock.now()`, captured once
    ///    per commit inside the serialized Authority interval before fact
    ///    load. This is the clock's only retention-policy consumer (§6.4
    ///    assigns it to THIS retention lane); the Domain planner stays pure
    ///    and receives `now: Date`.
    /// 3. **Fact load**: the singleton position, the persisted
    ///    `currentPolicies` (the config loader's shared fetch/validate/map
    ///    core), and the full inventory scalars — the v1 retained summaries
    ///    plus the `RetainedBytesRow` scalar projection. Zero blob decodes
    ///    on this path (`RET-PERF-2`/`RET-PLATFORM-2`); the both-directions
    ///    1:1 check makes the scalar fact complete (D8).
    /// 4. **PHASE A — R3 first** (§4.4/§3.2, mirroring the revise path):
    ///    for each item whose `revisionCount`/`revisionBytes` scalars exceed
    ///    the NEW thresholds (scalar detection only, `RET-PERF-2`), load that
    ///    item's lineage (bounded; only exceeding items), require its three
    ///    projected scalars to exactly equal the hydrated Canonical/revision
    ///    lineage (DATA-2), and plan the prune via
    ///    `planRevisionRetentionExpansion(target:
    ///    .setRetentionPolicies(activeRevisionID:))` — NO veto here. Project
    ///    each pruned item's scalars to the post-prune state
    ///    (`loadedRevisions \ pruneSet`).
    /// 5. **PHASE B — R1 + R2 over the PROJECTED POST-PRUNE inventory**
    ///    (§4.4/§3.2): `planItemRetentionExpansion` with `protected` =
    ///    pinned items only (no primary, no count victims on this lane) and
    ///    `now` from step 2. R2 sees post-prune bytes — it never credits
    ///    soon-to-be-pruned revision bytes and never retires an item whose
    ///    post-prune bytes satisfy the budget (`RET-PRUNE-2`). The §8.3
    ///    `.setRetentionPolicies` budget boundary equivalent follows: if the
    ///    PHASE-B survivors' projected bytes alone still exceed
    ///    `maxTotalBytes` (pinned bytes irreducible, D13), the policy is
    ///    rejected `.invalidInput(.invalidRetentionPolicy)` — restore-or-fail
    ///    (§2.2), the sweep's analog of capture's
    ///    `.capacityExceeded(.storageBytes)` pre-plan check (§6.5).
    /// 6. **PHASE C — unsatisfiable-R3 veto, DC-27 option (a)**: scoped to
    ///    items SURVIVING the PHASE-B retirements. A surviving exceeding
    ///    item whose post-prune revision bytes still exceed
    ///    `maxRevisionBytesPerItem` has an active revision that alone breaks
    ///    the threshold (the planner already returned the full inactive
    ///    prefix, D3/D23) — the whole action fails
    ///    `.invalidInput(.invalidRetentionPolicy)` atomically (no policy
    ///    persisted, no retirement/prune applied). An item R1/R2 retires
    ///    does NOT block the sweep: retirement deletes it and its revisions
    ///    in the same commit (retire-subsumes-prune, §6.3). The count
    ///    dimension is always satisfiable (pruning to the active alone
    ///    yields count 1 ≤ any admitted threshold, §8.3), so only the byte
    ///    dimension is checked.
    /// 7. **The no-op check** (§4.4/§5.6, the v1 WS21 posture): no
    ///    retirement, no surviving prune, and `newPolicies == currentPolicies`
    ///    returns `.unchanged` — no commit, no position advance, no
    ///    invalidation.
    /// 8. **Merge + tail** (§4.4): `mutations = retirements + per-item
    ///    .pruneRevisions (retire-subsumes-prune-dropped, §6.3, BEFORE
    ///    stamping so the stamper's disjointness guard never sees a
    ///    prune+retire pair) + .setRetentionPolicies(newPolicies)` (the
    ///    explicit D18 policy write), `outcome =
    ///    .retentionPoliciesSet(retiredItems:prunedRevisions:)` with
    ///    `prunedRevisions` counting only SURVIVING items' prunes (§8.1) —
    ///    then the ONE existing stamp/execute tail: one `ChangePosition`
    ///    successor (D6), the per-case `.pruneRevisions` rows re-encoded
    ///    from the loaded lineages, the config-row write, each `.delete`
    ///    also removing its 1:1 projection row (R.3), all in one
    ///    `ModelContext.transaction` (`RET-SECURITY-1`).
    ///
    /// The single-writer interval contains no `await` (§5).
    ///
    /// - Throws: `.invalidInput(.invalidRetentionPolicy)` for a boundary
    ///   rejection (§8.3), the PHASE-C veto (§4.4), or the budget boundary
    ///   equivalent (§8.3); the config/scalar/lineage loaders' typed
    ///   failures (`.temporarilyUnavailable(.factProof)`,
    ///   `.persistence(...)`, `.notFound` defensively — every inventoried
    ///   item exists); `StampingRejection` / `CodecRejection` via their §16
    ///   mappings; `.persistence(.transaction)` for any transaction-closure
    ///   failure (§16).
    internal func commitRetentionPolicies(
        _ newPolicies: HistoryRetentionPolicies
    ) async throws -> HistoryReceipt {
        // §8.3 boundary validation before ANY store work — the same-value
        // no-op and every sweep phase run only on an admitted policy value.
        if let rejection = RetentionPolicyBounds.validate(newPolicies) {
            throw rejection
        }

        // §6.4: the clock read occurs inside the serialized Authority
        // interval before fact load and is captured once per commit; every
        // R1 comparison below reuses this value. This is the clock's only
        // retention-policy consumer.
        let now = storageClock.now()

        let context = ModelContext(container)
        context.autosaveEnabled = false

        // ── Non-suspending commit interval (§5): no `await` past this
        //    line while the context, facts, or commit plan is live. ──

        // The singleton supplies the current position (for stamping and the
        // §10 closure guard); its count policy is not this action's concern
        // (the count dimension stays on v1 `.setRetentionPolicy`, §1).
        let positionRow = try Self.fetchExactlyOnePositionRow(in: context)
        let (currentPosition, _) = try Self.decodePositionRow(
            positionRow,
            limits: limits
        )

        // The persisted V2 policies the sweep compares against (§4.4's
        // currentPolicies) — the shared fetch/validate/map core, so a row
        // corrupted after `open` fails closed identically to the bootstrap.
        let currentPolicies = try RetentionConfigLoading.loadValidatedPolicies(
            in: context
        )

        // The full inventory scalars: v1 retained summaries
        // (`lastCopiedAt`/`pinOrdinal`, §3.2) plus the `RetainedBytesRow`
        // scalar projection. Scalar columns only — zero blob decodes on the
        // planning path (`RET-PERF-2`/`RET-PLATFORM-2`). Fact completeness
        // both directions (§3.2, D8): the 1:1 law makes the row set equal to
        // the retained set; a divergence is corruption, never a partial fact.
        let inventory = try HistoryItemRowHydration.fetchRetainedInventory(
            in: context,
            limits: limits
        )
        let scalarsByItem = try RetentionConfigLoading.fetchProjectedScalars(
            in: context,
            limits: limits
        )
        guard Set(scalarsByItem.keys) == Set(inventory.map(\.id)) else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // ── PHASE A — R3 first (§4.4/§3.2): prunes per exceeding item,
        //    planned WITHOUT the veto (the veto is PHASE C, post-PHASE-B). ──
        // The loaded lineage of every item with prunes — the stamping inputs
        // the per-case `.pruneRevisions` rows re-encode from (§5.3/§6.3).
        var lineagesByItem: [HistoryItemID: PruneLineage] = [:]
        // Non-empty prune sets only (§5.3: a no-op prune never reaches a plan).
        var pruneIDsByItem: [HistoryItemID: [RevisionID]] = [:]
        // The post-prune scalar projection of every exceeding item (§3.2) —
        // the R2 inventory's revision facts for those items, and the PHASE-C
        // byte comparison's subject.
        var projectedByItem: [HistoryItemID: RetentionConfigLoading.ProjectedItemScalars] = [:]
        if let revisionPolicy = newPolicies.revisions {
            // Deterministic walk: `inventory` is sorted by History Item ID.
            for summary in inventory {
                guard let scalars = scalarsByItem[summary.id] else {
                    // Unreachable after the both-directions check; kept as
                    // the fail-closed defensive path (§3.2: never a
                    // zero-byte read).
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                // Scalar exceedance detection only (§4.4/`RET-PERF-2`): an
                // item whose stored count/bytes already satisfy both NEW
                // thresholds is never decoded.
                let countExceeds = revisionPolicy.maxRevisionsPerItem
                    .map { scalars.revisionCount > $0 } ?? false
                let bytesExceeds = revisionPolicy.maxRevisionBytesPerItem
                    .map { scalars.revisionBytes > $0 } ?? false
                guard countExceeds || bytesExceeds else { continue }

                // §4.4 PHASE A: load THAT item's revision lineage (bounded;
                // only exceeding items) — the same complete-target decode
                // the revise path performs (05 §7.3).
                let facts = try MutationFactLoaders.loadRevisionFacts(
                    itemID: summary.id,
                    in: context,
                    limits: limits
                )
                // DATA-2: scalar exceedance is only the bounded selector for
                // this R3 slow path. Once the item is hydrated, require the
                // selected projection row to equal the exact Canonical and
                // revision lineage it summarizes before destructive
                // planning. This preserves `RET-PERF-2`: non-exceeding rows
                // are not decoded or cross-checked, while a plausible stale
                // scalar cannot choose victims for an exceeding item.
                var hydratedCanonicalBytes = 0
                for representation in facts.item.canonical.representations {
                    hydratedCanonicalBytes += representation.content.bytes.count
                }
                let hydratedRevisionScalars = RetainedBytesStamping
                    .revisionScalars(of: facts.item.revisions)
                guard scalars.canonicalBytes == hydratedCanonicalBytes,
                      scalars.revisionCount == hydratedRevisionScalars.count,
                      scalars.revisionBytes == hydratedRevisionScalars.bytes
                else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                // §5.5/§6.5: the policy-change target flavor — no append;
                // the effective list is the loaded lineage and the active is
                // the stored active. The planner never returns the active
                // (D3/D23).
                let pruneSet = planRevisionRetentionExpansion(
                    revisions: facts.item.revisions,
                    target: .setRetentionPolicies(
                        activeRevisionID: facts.item.activeRevisionID
                    ),
                    policies: HistoryRetentionPolicies(
                        age: nil,
                        storage: nil,
                        revisions: revisionPolicy
                    )
                )
                // §3.2 post-R3-prune projection: the item's revision scalars
                // over `loadedRevisions \ pruneSet` — computed in-commit over
                // the loaded lineage, never a second fact load. An empty
                // prune set (an active-only lineage that still exceeds the
                // byte threshold) projects to the loaded scalars themselves,
                // which is exactly the PHASE-C subject.
                let survivorScalars: RetainedRevisionScalars
                if pruneSet.isEmpty {
                    survivorScalars = hydratedRevisionScalars
                } else {
                    let removedIDs = Set(pruneSet)
                    survivorScalars = RetainedBytesStamping.revisionScalars(
                        of: facts.item.revisions.lazy.filter { !removedIDs.contains($0.id) }
                    )
                    lineagesByItem[summary.id] = PruneLineage(
                        revisions: facts.item.revisions,
                        activeRevisionID: facts.item.activeRevisionID
                    )
                    pruneIDsByItem[summary.id] = pruneSet
                }
                projectedByItem[summary.id] = RetentionConfigLoading
                    .ProjectedItemScalars(
                        canonicalBytes: scalars.canonicalBytes,
                        revisionCount: survivorScalars.count,
                        revisionBytes: survivorScalars.bytes
                    )
            }
        }

        // ── PHASE B — R1 + R2 over the PROJECTED POST-PRUNE inventory ──
        // (§4.4/§3.2). Exceeding items contribute their projected revision
        // scalars; every other item its stored projection row. Deterministic
        // fact values regardless of fetch order (the v1 loader's discipline;
        // the planner is order-independent anyway, D16).
        var items: [RetentionExpansionItemSummary] = []
        items.reserveCapacity(inventory.count)
        for summary in inventory {
            // The projected value exists only for exceeding items under the
            // NEW R3 lane; everything else reads its stored scalars (already
            // proven present by the both-directions check above).
            let scalars: RetentionConfigLoading.ProjectedItemScalars
            if let projected = projectedByItem[summary.id] {
                scalars = projected
            } else if let stored = scalarsByItem[summary.id] {
                scalars = stored
            } else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            items.append(RetentionExpansionItemSummary(
                id: summary.id,
                lastCopiedAt: summary.lastCopiedAt,
                pinOrdinal: summary.pinOrdinal,
                canonicalBytes: scalars.canonicalBytes,
                revisionCount: scalars.revisionCount,
                revisionBytes: scalars.revisionBytes
            ))
        }

        // `protected` = pinned items only (§4.4: no primary, no count
        // victims on this lane). The planner's own pin filter restates D13.
        var protected = Set<HistoryItemID>(minimumCapacity: inventory.count)
        for summary in inventory
        where summary.pinOrdinal != nil {
            protected.insert(summary.id)
        }

        // §6.4: `now` is the Storage clock value captured at entry — the
        // sweep lane's one and only clock read.
        let expansion = planItemRetentionExpansion(
            inventory: CompleteRetentionExpansionInventory(items: items),
            policies: newPolicies,
            protected: protected,
            now: now
        )
        var retiredIDs = Set<HistoryItemID>(
            minimumCapacity: expansion.retirements.count
        )
        for retirement in expansion.retirements {
            if case .retire(let itemID, _) = retirement {
                retiredIDs.insert(itemID)
            }
        }

        // ── §8.3 budget boundary equivalent (§6.5/§2.2 restore-or-fail) ──
        // The PHASE-B survivors' projected bytes are the irreducible
        // remainder once every eligible victim is retired: if they alone
        // exceed `maxTotalBytes` (pinned bytes irreducible, D13), the POLICY
        // is unsatisfiable for this store and is rejected at the boundary
        // with the §8.3 producer — the sweep's analog of capture's
        // `.capacityExceeded(.storageBytes)` pre-plan check. Checked
        // arithmetic (`06` §2 no-wrap rule): overflow — impossible within
        // the validated §8.3 bounds but enforced defensively — fails closed
        // as `.persistence(.invariantViolation)`.
        if let storagePolicy = newPolicies.storage {
            var survivorBytes = 0
            for item in items
            where !retiredIDs.contains(item.id) {
                let (footprint, footprintOverflow) = item.canonicalBytes
                    .addingReportingOverflow(item.revisionBytes)
                guard !footprintOverflow else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                let (total, totalOverflow) = survivorBytes
                    .addingReportingOverflow(footprint)
                guard !totalOverflow else {
                    throw HistoryFailure.persistence(.invariantViolation)
                }
                survivorBytes = total
            }
            guard survivorBytes <= storagePolicy.maxTotalBytes else {
                throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
            }
        }

        // ── PHASE C — unsatisfiable-R3 veto, DC-27 option (a) (§4.4) ──
        // Scoped to items SURVIVING the PHASE-B retirements: a surviving
        // exceeding item whose POST-PRUNE revision bytes still exceed
        // `maxRevisionBytesPerItem` has an active revision that alone breaks
        // the threshold (the planner already returned the full inactive
        // prefix; the active is never prunable, D3/D23), so the threshold is
        // unsatisfiable for that item — the ENTIRE action fails
        // `.invalidInput(.invalidRetentionPolicy)` atomically. An item this
        // commit retires never reaches this check: retirement deletes it and
        // its revisions (retire-subsumes-prune, §6.3), so its active
        // revision no longer constrains the post-commit state. Only
        // exceeding items have projections; a non-exceeding item's active
        // bytes are bounded by its (already-compliant) total. The count
        // dimension is always satisfiable (§8.3) and is not checked.
        if let maxRevisionBytes = newPolicies.revisions?.maxRevisionBytesPerItem {
            for (itemID, projected) in projectedByItem
            where !retiredIDs.contains(itemID) {
                if projected.revisionBytes > maxRevisionBytes {
                    throw HistoryFailure.invalidInput(.invalidRetentionPolicy)
                }
            }
        }

        // ── Retire-subsumes-prune (§6.3, `RET-STAMP-2`) ──
        // Drop every `.pruneRevisions` for an item this commit retires
        // BEFORE the plan exists: retirement deletes the row and all its
        // revisions, so a separate prune write would fetch a deleted row (the
        // 05 §10 row-existence rule) — the stamper's disjointness guard
        // never sees the pair. `prunedRevisions` consequently counts only
        // SURVIVING items' prunes (§8.1). Deterministic order: History Item
        // ID ascending.
        var survivingPruneItemIDs: [HistoryItemID] = []
        var prunedRevisions = 0
        for itemID in pruneIDsByItem.keys.sorted()
        where !retiredIDs.contains(itemID) {
            survivingPruneItemIDs.append(itemID)
            if let pruneSet = pruneIDsByItem[itemID] {
                prunedRevisions += pruneSet.count
            }
        }

        // ── The no-op check (§4.4/§5.6; v1 WS21 posture) ──
        // A same-value policy the current state already satisfies (no
        // retirement, no surviving prune) is a TRUE no-op: no commit, no
        // position advance, no invalidation. Every other shape commits — a
        // changed value with a satisfied state still persists the policy
        // (§5.6: the write advances ChangePosition exactly once when the
        // value actually changes or victims retire).
        if newPolicies == currentPolicies,
           expansion.retirements.isEmpty,
           survivingPruneItemIDs.isEmpty {
            return .unchanged
        }

        // ── Merge (§4.4's exact order) ──
        // Retirements (the planner's oldest-first eviction order), then the
        // surviving per-item prunes, then the explicit policy write (D18 —
        // never an outcome-inferred side effect of `.retentionPoliciesSet`).
        var mutations: [HistoryMutation] = expansion.retirements
        for itemID in survivingPruneItemIDs {
            guard let pruneSet = pruneIDsByItem[itemID], !pruneSet.isEmpty else {
                // Unreachable: only non-empty sets enter `pruneIDsByItem`,
                // and the drop above preserves them; kept as the fail-closed
                // defensive path (§5.3: a plan never carries an empty prune).
                throw HistoryFailure.persistence(.invariantViolation)
            }
            mutations.append(.pruneRevisions(
                itemID: itemID,
                removedRevisionIDs: pruneSet
            ))
        }
        mutations.append(.setRetentionPolicies(newPolicies))
        let mutationPlan = MutationPlan(
            outcome: .retentionPoliciesSet(
                retiredItems: expansion.retirements.count,
                prunedRevisions: prunedRevisions
            ),
            mutations: mutations
        )

        // §9: mechanical stamping from the loaded lineages — one checked
        // ChangePosition successor for the whole plan (D6), each prune
        // re-encoded through the shorter-blob helper (§5.3/§6.3), the policy
        // write mapped to its config-row stamping (§5.6).
        let stamped: StampedCommitPlan
        do {
            stamped = try CommitPlanStamper.stamp(
                mutationPlan,
                currentPosition: currentPosition,
                inputs: .prune(lineagesByItem: lineagesByItem),
                createdAt: now
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

    // MARK: Config-row access (V2-02 §5.6 execution)

    /// Fetches the one `RetentionExpansionConfigRow` singleton the
    /// `.setRetentionPolicies` stamping writes, inside the transaction
    /// closure. The fetch is bounded (`fetchLimit = 2`) and keyed by the
    /// well-known singleton key: `open` bootstrapped the row (absence proves
    /// divergence mid-run, the same exactly-one stance as the position
    /// singleton), and the single writer makes a duplicate impossible through
    /// public behavior — both are `.persistence(.invariantViolation)`
    /// corruption, remapped with every other closure failure to
    /// `.persistence(.transaction)` (§16).
    internal static func fetchRetentionConfigRow(
        in context: ModelContext
    ) throws -> RetentionExpansionConfigRow {
        let key = retentionExpansionConfigKey
        var descriptor = FetchDescriptor<RetentionExpansionConfigRow>(
            predicate: #Predicate { row in row.key == key }
        )
        descriptor.fetchLimit = 2
        let rows: [RetentionExpansionConfigRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.persistence(.transaction)
        }
        guard rows.count == 1, let row = rows.first else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return row
    }
}
