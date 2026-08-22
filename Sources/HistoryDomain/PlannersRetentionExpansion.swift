/// PlannersRetentionExpansion.swift — the pure V2-02 expansion planners:
/// R1 (age) + R2 (storage-byte) item retirement over a projected inventory,
/// and R3 (revision-threshold) pruning over one item's loaded lineage.
/// Owning spec: docs/v2/V2-02-retention.md §4.1/§4.2 (R1+R2 selection and the
/// R1-before-R2 union), §5.1–§5.4 (the prune relation and what pruning never
/// does), §6.5 (planner signatures), §11 (D23/D24); roadmap slice:
/// docs/v2/V2-roadmap.md §6 R.2 "Pure Domain" (`RET-PRUNE-1`, `RET-SELECT-1`).
/// Pure value planning only — no I/O, no clocks (the planner receives
/// `now: Date` and mints none, `02` §1; the Storage-side clock seam is
/// `V2-02` §6.4), no UUID/ContentVersion/ChangePosition minting, no async.
import Foundation
import HistoryCore

// MARK: - Expansion plan (docs/v2/V2-02-retention.md §6.5)

/// The R1+R2 item-retirement result of one expansion pass.
/// docs/v2/V2-02-retention.md §6.5
///
/// R3 revision prunes are NOT in this plan: `planRevisionRetentionExpansion`
/// returns `[RevisionID]` per item; the Storage composer builds
/// `.pruneRevisions` mutations from those results (`V2-02` §4.4). R1+R2
/// retirements are a single deduplicated union pass: R1 victims are removed
/// from the projected byte total before R2 selects (`V2-02` §4.1), so
/// `retirements` contains no duplicate `HistoryItemID` — itemID-uniqueness
/// is the pure function's postcondition (D24; `RET-SELECT-1(d)`).
package struct RetentionExpansionPlan: Sendable {
    /// Every `.retire(itemID:, .retention)` of the pass, oldest-first in the
    /// v1 eviction order (`lastCopiedAt` ascending, `HistoryItemID` bytes
    /// ascending, `02` §12), deduplicated.
    package let retirements: [HistoryMutation]

    /// The number of retired items; equals `retirements.count`.
    package let retiredItems: Int

    package init(retirements: [HistoryMutation], retiredItems: Int) {
        self.retirements = retirements
        self.retiredItems = retiredItems
    }
}

/// Which caller shape an R3 prune is computed for, making the two callers
/// type-mutually-exclusive (avoids passing an inconsistent
/// `activeRevisionID` + `appendedRevision` pair).
/// docs/v2/V2-02-retention.md §6.5
package enum RevisionExpansionTarget: Sendable {
    /// Fires from a policy change (no append): the effective list is the
    /// loaded lineage and the active is `activeRevisionID`
    /// (`V2-02` §5.5/§4.4 PHASE A).
    case setRetentionPolicies(activeRevisionID: RevisionID?)

    /// Fires from a revision append: the effective list is
    /// `revisions + [appended]` and the active is `appended.id`
    /// (`V2-02` §4.3).
    case revise(appended: ContentRevision)
}

// MARK: - R1 + R2 (docs/v2/V2-02-retention.md §4.1, §4.2, §6.5)

/// Plans the R1 + R2 item-retirement pass over a projected item inventory.
/// docs/v2/V2-02-retention.md §4.1, §4.2, §6.5
///
/// Selection (`RET-SELECT-1`):
///
/// 1. **R1** (age) selects eligible items with `lastCopiedAt < (now −
///    age.maxAge)` — the comparison is strict; an item exactly `maxAge` old
///    is NOT retired — oldest-first in the v1 eviction order
///    (`lastCopiedAt` ascending, `HistoryItemID` bytes ascending, `02` §12).
/// 2. **R1-before-R2**: R1 victims are removed from both the projected byte
///    total and the R2 candidate set before R2 selects, so R2 never
///    over-retires by crediting soon-to-be-R1-retired bytes and no item is
///    retired twice (`V2-02` §4.1).
/// 3. **R2** (storage bytes) retires oldest eligible unpinned items, in the
///    same eviction order for determinism (D16; D9 governs dedup-winner
///    ties, not retirement), until projected retained bytes — per-item
///    `canonicalBytes + revisionBytes` over the post-R1 inventory, protected
///    items included because they remain retained — reach
///    `<= storage.maxTotalBytes`, never further.
///
/// Victim safety (D13/D14, D24(b)): an item is eligible only when it is
/// neither pinned nor in `protected` (pinned items ∪ {primary} ∪
/// already-retired-by-count victims, `V2-02` §4.2; for `.setRetentionPolicies`
/// `protected` is the pinned items only, `V2-02` §4.4). The pin filter
/// restates D13 locally even though `protected` already carries the pinned
/// lane: victim safety is a planner postcondition, not only a caller
/// contract.
///
/// This planner throws nothing (`V2-02` §6.5: retirement is deterministic
/// victim selection, not a `DomainRejection` producer). An unsatisfiable R2
/// budget (`pinned + primary bytes > maxTotalBytes`) is detected by Storage's
/// pre-plan feasibility check and fails `.capacityExceeded(.storageBytes)`
/// before any R2 retirement is planned, so no maximal-doomed retirement plan
/// is ever built by the pipeline; defensively, if this total function is
/// handed such facts anyway, it deterministically retires every eligible
/// victim and still never retires a protected one. The R2 byte-total
/// summation uses checked arithmetic (`06` §2: no byte-count calculation may
/// wrap); overflow — impossible within the validated `Int64` / 5,000 ×
/// 384 MiB worst case (`V2-02` §8.3) but enforced defensively — saturates at
/// `Int.max` rather than wrapping, and the typed fail-closed
/// `.persistence(.invariantViolation)` mapping is the Storage pipeline
/// boundary's (`V2-02` §4.2), exactly because §6.5 keeps this signature
/// non-throwing.
///
/// Deterministic pure function of `(inventory, policies, protected, now)`
/// (D16): identical inputs produce identical plans regardless of inventory
/// ordering, because unique IDs make the eviction order total.
package func planItemRetentionExpansion(
    inventory: CompleteRetentionExpansionInventory,
    policies: HistoryRetentionPolicies,
    protected: Set<HistoryItemID>,
    now: Date
) -> RetentionExpansionPlan {
    // `V2-02` §4.1: when no V2-02 policy is active the pass is a no-op (both
    // item dimensions disabled; R3 alone never reaches this planner, §7).
    let agePolicy = policies.age
    let storagePolicy = policies.storage
    guard agePolicy != nil || storagePolicy != nil else {
        return RetentionExpansionPlan(retirements: [], retiredItems: 0)
    }

    // Eligibility (§4.2): never pinned (D13), never a member of `protected`
    // — pinned ∪ {primary} ∪ already-retired-by-count (D14 / plan invariant
    // 7, `02` §7 and §12).
    let eligible = inventory.items.filter {
        $0.pinOrdinal == nil && !protected.contains($0.id)
    }

    // R1 — strict age selection (§4.2): `lastCopiedAt < now − maxAge`.
    // `maxAge` is finiteness-checked at the Storage boundary (DC-21); the
    // planner receives a finite value and mints no clock (§6.4).
    var r1Victims: [RetentionExpansionItemSummary] = []
    if let agePolicy {
        let ageCutoff = now.addingTimeInterval(-agePolicy.maxAge)
        r1Victims = eligible.filter { $0.lastCopiedAt < ageCutoff }
    }
    let r1VictimIDs = Set(r1Victims.map(\.id))

    // R2 — the projected byte total over the post-R1 inventory (§4.1): R1
    // victims' bytes are excluded from the total AND from selection below.
    // Protected items remain retained, so their bytes stay in the total —
    // that irreducible remainder is what Storage's pre-plan feasibility
    // check turns into `.capacityExceeded(.storageBytes)` (§6.5, D24(c)).
    var projectedTotalBytes = 0
    if let storagePolicy {
        for item in inventory.items where !r1VictimIDs.contains(item.id) {
            projectedTotalBytes = checkedByteAdd(
                projectedTotalBytes,
                retainedBytes(of: item)
            )
        }
        // The satisfying state (RET-SELECT-1(e)): no aged victim and the
        // budget already restored — the eviction order is never established.
        if r1Victims.isEmpty && projectedTotalBytes <= storagePolicy.maxTotalBytes {
            return RetentionExpansionPlan(retirements: [], retiredItems: 0)
        }
    } else if r1Victims.isEmpty {
        return RetentionExpansionPlan(retirements: [], retiredItems: 0)
    }

    // Establish the eviction order only now that a victim is certain to
    // exist (mirroring `planCapture`'s derive-before-sort discipline,
    // `02` §12). Every R1 victim precedes every R2 candidate in this order:
    // aged items have `lastCopiedAt < cutoff <=` each survivor's, so the
    // concatenation R1 ++ R2 below is globally oldest-first and structurally
    // deduplicated — R2 candidates exclude R1 victims by ID.
    r1Victims.sort(by: expansionEvictionRanksBefore)
    var retirements: [HistoryMutation] = r1Victims.map {
        .retire(itemID: $0.id, reason: .retention)
    }

    if let storagePolicy {
        var candidates = eligible.filter { !r1VictimIDs.contains($0.id) }
        candidates.sort(by: expansionEvictionRanksBefore)
        // Retire oldest eligible until the budget is restored — never
        // further (RET-SELECT-1(b)). Exhausting the candidates while still
        // over budget is the defensively-total unsatisfiable case documented
        // above: the pipeline's pre-plan feasibility check prevents it.
        for item in candidates {
            guard projectedTotalBytes > storagePolicy.maxTotalBytes else { break }
            retirements.append(.retire(itemID: item.id, reason: .retention))
            projectedTotalBytes = checkedByteSubtract(
                projectedTotalBytes,
                retainedBytes(of: item)
            )
        }
    }

    return RetentionExpansionPlan(
        retirements: retirements,
        retiredItems: retirements.count
    )
}

// MARK: - R3 (docs/v2/V2-02-retention.md §5.1–§5.3, §6.5)

/// Plans the R3 prune set for one item's revision lineage (already loaded).
/// docs/v2/V2-02-retention.md §5.1, §6.5
///
/// `revisions` is the pre-append loaded lineage. The `target` fixes the
/// effective list and its active revision: `.setRetentionPolicies(active)`
/// fires from a policy change (no append; the effective list is `revisions`
/// and the active is `active`), `.revise(appended)` fires from a revision
/// append (the effective list is `revisions + [appended]` and the active is
/// `appended.id`). The returned prune set is computed over the effective
/// post-append list and never contains the effective active ID.
///
/// The prune relation (§5.1, `RET-PRUNE-1`): the prune set is the shortest
/// append-order PREFIX of inactive revisions — oldest inactive first, NOT a
/// minimum-cardinality subset — whose removal makes the FULL retained set
/// (active included) satisfy `count <= maxRevisionsPerItem` and
/// `bytes <= maxRevisionBytesPerItem`. Append order over inactive revisions
/// is a total order with no ties (`02` §2.5 rule 1), so no ID tie-break is
/// required; the v1 `lastCopiedAt ascending, id ascending` eviction tie-break
/// (`02` §12) governs item retirement, not within-item revision order.
///
/// What pruning never does (§5.2, D23): it never removes the active revision
/// (D3), never changes a surviving revision's content or ID (D4), never
/// reorders survivors, and never touches Canonical Content, Effective
/// Content, `ContentVersion` (D5), projections, or Signature Index postings —
/// the payload is exactly the removed IDs, oldest-first; the Storage composer
/// rewrites the `RevisionStateBlobV1` from it (§5.3/§6.3).
///
/// This planner throws nothing (§6.5) and never returns more IDs than
/// inactive revisions present. An unsatisfiable R3 prune (the effective
/// active revision's bytes alone exceed `maxRevisionBytesPerItem`) is
/// detected on the V2-extended preparation path and fails
/// `.capacityExceeded(.revisionBytes)` (§4.3/§8.3), not returned as a partial
/// prune set; defensively this total function then returns the full inactive
/// prefix — every inactive ID, never the active — which the preparation-path
/// rejection prevents from ever being stamped. The count dimension is always
/// satisfiable on revise (pruning to the new active alone yields count 1 <=
/// `maxRevisionsPerItem` for any admitted `maxRevisionsPerItem >= 1`, §4.3).
package func planRevisionRetentionExpansion(
    revisions: [ContentRevision],
    target: RevisionExpansionTarget,
    policies: HistoryRetentionPolicies
) -> [RevisionID] {
    // §3.1/§7: a `RevisionRetention` with both thresholds nil is normalized
    // to `nil` at `HistoryRetentionPolicies.init`, so R3-disabled prunes
    // nothing and this planner is never the no-op's cause.
    guard let revisionPolicy = policies.revisions else { return [] }

    // §6.5: the target fixes the effective list and active revision.
    let effectiveRevisions: [ContentRevision]
    let activeRevisionID: RevisionID?
    switch target {
    case .setRetentionPolicies(let activeID):
        effectiveRevisions = revisions
        activeRevisionID = activeID
    case .revise(let appended):
        effectiveRevisions = revisions + [appended]
        activeRevisionID = appended.id
    }
    // A nil active over a non-empty list is corrupt lineage Storage rejects
    // at fact load (D3, `02` §6/§11 step 3); with no active revision there
    // is simply no revision exempt from pruning, and the planner stays total
    // and deterministic on the defensive path.

    // §5.1: both thresholds bound the FULL retained revision set, active
    // included — `count(R)` and `bytes(R)` count the active revision, not
    // inactive-only. Bytes use the representation-byte measure of §3.2/§5.4
    // (sum of stored-revision representation bytes; checked, never wrapping).
    var retainedCount = effectiveRevisions.count
    var retainedBytes = 0
    for revision in effectiveRevisions {
        retainedBytes = checkedByteAdd(retainedBytes, revisionContentBytes(revision))
    }

    // §5.1: take the shortest append-order prefix of inactive revisions —
    // walking append order, stop as soon as both thresholds hold. Each
    // removal reduces both count and bytes, so the greedy prefix is the
    // shortest under oldest-inactive-first selection.
    var prunedIDs: [RevisionID] = []
    for revision in effectiveRevisions where revision.id != activeRevisionID {
        let countSatisfied = revisionPolicy.maxRevisionsPerItem
            .map { retainedCount <= $0 } ?? true
        let bytesSatisfied = revisionPolicy.maxRevisionBytesPerItem
            .map { retainedBytes <= $0 } ?? true
        if countSatisfied && bytesSatisfied {
            break
        }
        prunedIDs.append(revision.id)
        retainedCount -= 1
        retainedBytes = checkedByteSubtract(
            retainedBytes,
            revisionContentBytes(revision)
        )
    }
    return prunedIDs
}

// MARK: - File-private helpers

/// Per-item retained content bytes for R2: `canonicalBytes + revisionBytes`
/// over the expansion inventory (§4.2). Both addends are content-byte
/// measures (§3.2), so their sum is a coherent content-byte footprint.
/// Checked: a per-item overflow saturates at `Int.max` and never wraps.
private func retainedBytes(of item: RetentionExpansionItemSummary) -> Int {
    let (sum, overflow) = item.canonicalBytes.addingReportingOverflow(item.revisionBytes)
    return overflow ? Int.max : sum
}

/// Checked byte-total accumulation (`06` §2: no byte-count calculation may
/// wrap). Overflow is impossible within the validated `Int64` / 5,000 ×
/// 384 MiB worst case (`V2-02` §4.2/§8.3) but enforced defensively: the
/// running total saturates at `Int.max` — never wraps, never under-retires —
/// while the typed `.persistence(.invariantViolation)` fail-closed mapping
/// stays at the Storage pipeline boundary, because §6.5 keeps the planner
/// signatures non-throwing.
private func checkedByteAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int.max : sum
}

/// Checked budget restore. Subtracting one previously accumulated footprint
/// cannot underflow on well-formed facts; the guarded form keeps even a
/// corrupt negative scalar from wrapping the running total past `Int.max`.
private func checkedByteSubtract(_ lhs: Int, _ rhs: Int) -> Int {
    let (difference, overflow) = lhs.subtractingReportingOverflow(rhs)
    return overflow ? Int.max : difference
}

/// One revision's content bytes: the sum of its Effective representation
/// byte counts — the R3 representation-byte measure (§3.2/§5.4), commensurate
/// with `canonicalBytes` and with the v1 per-item-revision-byte hard bound
/// (measure identity gated by `RET-PLATFORM-4`).
private func revisionContentBytes(_ revision: ContentRevision) -> Int {
    var total = 0
    for representation in revision.content.representations {
        total = checkedByteAdd(total, representation.bytes.count)
    }
    return total
}

/// The v1 eviction order (`02` §12): `lastCopiedAt` ascending, then
/// `HistoryItemID` bytes ascending. Fact completeness gives every retained
/// item exactly once, so unique IDs make this a total order and R1/R2
/// selection independent of input ordering (D16).
private func expansionEvictionRanksBefore(
    _ lhs: RetentionExpansionItemSummary,
    _ rhs: RetentionExpansionItemSummary
) -> Bool {
    if lhs.lastCopiedAt != rhs.lastCopiedAt {
        return lhs.lastCopiedAt < rhs.lastCopiedAt
    }
    return lhs.id < rhs.id
}
