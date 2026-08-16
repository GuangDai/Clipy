/// R.4 — the capture-lane retention-expansion composition: the
/// config→policy loader that turns the `RetentionExpansionConfigRow`
/// singleton into the public `HistoryRetentionPolicies` the capture path
/// plans with, and the `V2-02` §4.2 merge that folds the R1/R2 expansion
/// retirements into one v1 capture plan (v1 mutations first, retirements
/// after) committed through the unchanged v1 tail — one plan, one
/// `ChangePosition` stamp, one `ModelContext.transaction`, unchanged
/// receipt outcome.
/// Owning spec: docs/v2/V2-02-retention.md §4.1 (composition principle),
/// §4.2 (the authoritative capture pseudocode, the R3-only-takes-v1-path
/// note, and the `protected`/`now`/pre-plan-feasibility bullets), §3.2
/// (expansion-fact construction guarantees: `RetainedBytesRow` scalars,
/// projected post-primary post-count inventory, ZERO `revisionStateBlob`/
/// `SignatureBlobV1` envelope decodes on the planning path —
/// `RET-PLATFORM-2`/`RET-PERF-3`), §3.3 (the config singleton and its
/// fail-closed contract), §7 (trigger matrix: capture fires R1+R2 ONLY),
/// §8.3 (pre-plan R2 feasibility → `.capacityExceeded(.storageBytes)` at
/// capture; persisted-config corruption fails closed as
/// `.corruptStoredValue`/`.invariantViolation`, never `.invalidInput`);
/// roadmap: docs/v2/V2-roadmap.md §6 R.4 "Capture composition" (exit
/// fixtures: count+age+byte composition, pinned-over-budget hard failure,
/// one-position, disabled-public-semantics).
///
/// Boundary (roadmap R.4): the revise-path composition (R2+R3, §4.3) and
/// the `.setRetentionPolicies` sweep (§4.4) are owned by R.5/R.6 — this file
/// composes the CAPTURE lane only, and the RetentionClock seam (`V2-02`
/// §6.4) is deliberately unread here: capture's R1 reference `now` is the
/// capture's own `observedAt`, already a Domain input (§4.2; the DC-28
/// note — the clock exists for the R.6 sweep lane alone).
import Foundation
import HistoryCore
import HistoryDomain
import SwiftData

// MARK: - Config → policy loading (V2-02 §3.3, §4.2, §7)

/// Loads the persisted `RetentionExpansionConfigRow` singleton as the public
/// `HistoryRetentionPolicies` value the capture lane plans with.
internal enum RetentionConfigLoading {

    /// One item's three planning scalars, read from the `RetainedBytesRow`
    /// projection columns (`V2-02` §3.3b). A value type local to this loader
    /// because `RetainedRevisionScalars` (R.3) carries the revision pair
    /// only — `canonicalBytes` is projection-maintained separately and is
    /// never a revision fact.
    internal struct ProjectedItemScalars: Sendable, Equatable {
        internal let canonicalBytes: Int
        internal let revisionCount: Int
        internal let revisionBytes: Int
    }

    /// Fetches the config singleton inside the Authority's capture interval
    /// and maps it to `HistoryRetentionPolicies`: enabled flag + in-range
    /// value per lane, a disabled lane → `nil`.
    ///
    /// Capture-lane gate (`V2-02` §4.2/§7): R3 participates ONLY on the
    /// revise/sweep paths (capture does not grow any item's revisions), so
    /// this loader returns `nil` — "take the exact v1 route with NO
    /// expansion fact load and NO `planItemRetentionExpansion` call" —
    /// unless R1 or R2 is active. An R3-only config (R1 nil, R2 nil, R3
    /// enabled) and the all-disabled default therefore both return `nil`,
    /// preserving the `RET-PERF-1/3` budget for the R1/R2-active case only.
    ///
    /// Validation reuses the open-time bootstrap's unit validation exactly
    /// (`HistoryAuthority.validateRetentionExpansionConfig`): a corrupted row
    /// fails closed as `.persistence(.corruptStoredValue)` (unknown
    /// `configSchemaVersion`; non-finite `ageMaxSeconds`, DC-21) or
    /// `.persistence(.invariantViolation)` (out-of-range / contradictory
    /// combination, `V2-02` §8.3) — never `.invalidInput`, which is reserved
    /// for the caller-facing `.setRetentionPolicies` boundary (R.6).
    ///
    /// - Throws: `.temporarilyUnavailable(.factProof)` when the fetch itself
    ///   cannot complete (the §16 fact vocabulary `fetchExactlyOnePositionRow`
    ///   takes outside the transaction closure); `.persistence(
    ///   .invariantViolation)` when the singleton is absent or duplicated
    ///   mid-run (`open` bootstrapped it — absence proves divergence, the
    ///   same exactly-one stance as the position singleton); plus the unit
    ///   validation's typed failures above.
    internal static func loadCaptureLanePolicies(
        in context: ModelContext
    ) throws -> HistoryRetentionPolicies? {
        let key = HistoryAuthority.retentionExpansionConfigKey
        var descriptor = FetchDescriptor<RetentionExpansionConfigRow>(
            predicate: #Predicate { row in row.key == key }
        )
        descriptor.fetchLimit = 2
        let rows: [RetentionExpansionConfigRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count == 1, let row = rows.first else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        // The stored-row contract is the bootstrap's, re-run per capture so a
        // row corrupted after `open` fails closed identically (V2-02 §3.3).
        try HistoryAuthority.validateRetentionExpansionConfig(row)

        // Enabled flag + in-range value per lane; disabled → nil. A dormant
        // (disabled) lane's stored value is never read as a policy (§3.3:
        // "a disabled policy's dormant value is not range-checked" — the
        // validation above already enforced the bounds for non-nil
        // thresholds).
        let age = row.agePolicyEnabled
            ? AgeRetention(maxAge: row.ageMaxSeconds)
            : nil
        let storage = row.storagePolicyEnabled
            ? StorageRetention(maxTotalBytes: row.storageMaxBytes)
            : nil
        let revisions = row.revisionPolicyEnabled
            ? RevisionRetention(
                maxRevisionsPerItem: row.revisionMaxCount,
                maxRevisionBytesPerItem: row.revisionMaxBytes
            )
            : nil
        // The §3.1 construction-time normalization collapses a both-nil
        // `RevisionRetention` to nil (an impossible input here anyway: the
        // unit validation rejects `revisionPolicyEnabled` with both
        // thresholds nil), so the public value never carries an
        // enabled-but-no-op R3 lane.
        let policies = HistoryRetentionPolicies(
            age: age,
            storage: storage,
            revisions: revisions
        )
        // §4.2's v1-route gate: only R1/R2 activate the capture expansion.
        guard policies.age != nil || policies.storage != nil else {
            return nil
        }
        return policies
    }

    /// One bounded scalar fetch of every `RetainedBytesRow` projection
    /// column, keyed by business ID (`V2-02` §3.3b/§3.2). Scalar columns
    /// only: no Canonical or revision blob is fetched or decoded here
    /// (`RET-PLATFORM-2`; the `.externalStorage` blob columns are never
    /// touched), the `bytesSchemaVersion` coherence fence is enforced, and
    /// the result is proved complete BOTH directions against the retained
    /// set — a row naming no retained item or a retained item with no row is
    /// corruption, never a partial fact and never a zero-byte read (D8;
    /// `RET-PLATFORM-1b(a)`; `V2-02` §3.2/Record 5).
    ///
    /// - Throws: `.temporarilyUnavailable(.factProof)` when the fetch cannot
    ///   complete; `.persistence(.invariantViolation)` for an over-bound row
    ///   set, a duplicate `itemID`, an unknown `bytesSchemaVersion`, or the
    ///   both-directions mismatch.
    internal static func fetchProjectedScalars(
        in context: ModelContext,
        limits: HistoryLimits
    ) throws -> [HistoryItemID: ProjectedItemScalars] {
        var descriptor = FetchDescriptor<RetainedBytesRow>()
        descriptor.propertiesToFetch = [
            \.itemID,
            \.canonicalBytes,
            \.revisionCount,
            \.revisionBytes,
            \.bytesSchemaVersion
        ]
        // §7.3's bounded-inventory discipline: one row past the hard bound
        // proves corruption without fetching the rest.
        descriptor.fetchLimit = limits.hardMaximumRetainedItems + 1
        let rows: [RetainedBytesRow]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            throw HistoryFailure.temporarilyUnavailable(.factProof)
        }
        guard rows.count <= limits.hardMaximumRetainedItems else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        var scalarsByItem: [HistoryItemID: ProjectedItemScalars] = [:]
        scalarsByItem.reserveCapacity(rows.count)
        for row in rows {
            // The projection-coherence fence (§3.3b): an unknown
            // `bytesSchemaVersion` is never read as a possibly-correct byte
            // fact.
            guard row.bytesSchemaVersion == RetainedBytesStamping
                .bytesSchemaVersion else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let itemID = HistoryItemID(rawValue: row.itemID)
            guard scalarsByItem[itemID] == nil else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
            scalarsByItem[itemID] = ProjectedItemScalars(
                canonicalBytes: row.canonicalBytes,
                revisionCount: row.revisionCount,
                revisionBytes: row.revisionBytes
            )
        }
        return scalarsByItem
    }
}

// MARK: - Capture composition (V2-02 §4.1/§4.2; V2-roadmap §6 R.4)

extension HistoryAuthority {

    /// The `V2-02` §4.2 capture composition, run between `planCapture` and
    /// stamping inside the capture commit interval:
    ///
    /// 1. Load the persisted policies for the capture lane. `nil` (R3-only or
    ///    all-disabled config) returns the v1 plan untouched — the exact v1
    ///    route, with no expansion fact load (§4.2/§7).
    /// 2. Build the expansion inventory over the PROJECTED post-primary
    ///    post-count state: count-plan victims are excluded, the primary's
    ///    recency is its post-insert/post-coalesce value (the v1 plan's own
    ///    folded occurrence — the fold is consumed, never reconstructed,
    ///    `02` §7 plan invariant 3), and every existing item's bytes come
    ///    from the `RetainedBytesRow` scalar projection. The insert lane is
    ///    the one §3.2 exception: the new primary has no projection row yet,
    ///    so its `canonicalBytes` is summed in memory from the prepared
    ///    signature postings (the exact entries the index delta will add)
    ///    with `revisionCount == 0` / `revisionBytes == 0` (a v1 insert
    ///    carries an empty revision list). The coalesce lane reads the
    ///    WINNER's stored scalars — the incoming capture blob is never
    ///    substituted for them (`02` §9.5; undercounting would leave the
    ///    store over budget, §3.2 coalesce lane).
    /// 3. Pre-plan R2 feasibility (§8.3): when R2 is active, pinned bytes ∪
    ///    primary bytes (the irreducible union — counted once per item even
    ///    when the coalescing winner is itself pinned) over `maxTotalBytes`
    ///    throws `.capacityExceeded(.storageBytes)` BEFORE anything is
    ///    stamped or transacted, so the primary insert never lands
    ///    (atomicity, §2.2). The byte-total summation is checked (`06` §2
    ///    no-wrap rule): overflow — impossible within the validated §8.3
    ///    bounds but enforced defensively — fails closed as
    ///    `.persistence(.invariantViolation)`.
    /// 4. `planItemRetentionExpansion(inventory:policies:protected:now:)`
    ///    with `protected` = pinned ∪ {primary} ∪ count-plan victims
    ///    (D13/D14/plan invariant 7, `02` §7/§12) and `now` = the capture's
    ///    `observedAt` (NOT the Storage clock — §6.4/DC-28: the seam exists
    ///    for the R.6 sweep lane alone).
    /// 5. Merge: `mutations = v1Plan.mutations + expansion.retirements` (v1
    ///    mutations first, retirements after — deterministic), `outcome =
    ///    v1Plan.outcome` (retirements never change the capture receipt,
    ///    §4.2 "outcome = v1Plan.outcome"). The merged Domain plan flows
    ///    through the ONE existing tail unchanged: `CommitPlanStamper.stamp`
    ///    mints exactly one `ChangePosition` successor for the whole plan and
    ///    its `.retire` arm inserts every retirement into the index-delta
    ///    removals exactly as v1 count-retirements do (`05` §9/§11), and
    ///    `executeStampedPlan` → `executeCommitTransaction` applies the
    ///    deletes (each also removing the 1:1 projection row, R.3) in one
    ///    `ModelContext.transaction`.
    ///
    /// - Throws: the config loader's typed failures (above);
    ///   `.temporarilyUnavailable(.factProof)` when the scalar projection
    ///   fetch cannot complete; `.persistence(.invariantViolation)` for a
    ///   projection-row cardinality/version/coherence violation (a missing
    ///   row for an existing item is corruption, never a zero-byte read —
    ///   `V2-02` §3.2/Record 5), a non-primary-led v1 plan, or a retirement
    ///   naming the primary (defensive plan-invariant-7 backstops);
    ///   `.capacityExceeded(.storageBytes)` for the §8.3 pre-plan
    ///   infeasibility.
    internal func composeRetentionExpansionForCapture(
        _ v1Plan: MutationPlan,
        prepared: PreparedCaptureBundle,
        facts: IngestFacts,
        in context: ModelContext
    ) throws -> MutationPlan {
        // §4.2: "if neither R1 nor R2 active: stamp+transact v1Plan exactly
        // as v1" — nil means R3-only or all-disabled, both of which take the
        // v1 route with no expansion fact load (§7).
        guard let policies = try RetentionConfigLoading.loadCaptureLanePolicies(
            in: context
        ) else {
            return v1Plan
        }

        // The primary and its post-primary recency come from the v1 plan
        // itself: `planCapture` always leads `mutations` with the primary
        // (`.create` insert / `.recordCopy` coalesce carrying the complete
        // folded occurrence, `02` §9.3/§9.5). A plan not led by a primary is
        // a planner-contract violation, not data.
        let primaryID: HistoryItemID
        let primaryLastCopiedAt: Date
        let primaryIsInsert: Bool
        switch v1Plan.mutations.first {
        case .create(let item):
            primaryID = item.id
            primaryLastCopiedAt = item.occurrence.lastCopiedAt
            primaryIsInsert = true
        case .recordCopy(let itemID, let occurrence):
            primaryID = itemID
            primaryLastCopiedAt = occurrence.lastCopiedAt
            primaryIsInsert = false
        default:
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // The count dimension's already-decided victims (§4.1: the expansion
        // pass never re-runs v1 victim selection — it consumes the v1 plan's
        // victims as input so it never double-retires or conflicts).
        // `planCapture` emits only `.retention` retirements (`02` §12).
        var countVictimIDs = Set<HistoryItemID>()
        for mutation in v1Plan.mutations {
            if case .retire(let itemID, _) = mutation {
                countVictimIDs.insert(itemID)
            }
        }

        // ── Expansion facts over the projected inventory (§3.2/§4.2) ──
        let scalarsByItem = try RetentionConfigLoading.fetchProjectedScalars(
            in: context,
            limits: limits
        )
        // The pre-commit store retains exactly `facts.retention.allItems`,
        // and the 1:1 law makes the row set equal to it.
        let retainedIDs = Set(facts.retention.allItems.map(\.id))
        guard Set(scalarsByItem.keys) == retainedIDs else {
            throw HistoryFailure.persistence(.invariantViolation)
        }

        // The projected post-primary post-count inventory: count victims are
        // excluded from the inventory entirely (§4.2 — their bytes do not
        // count toward the R2 total; they are ALSO in `protected` below, so
        // the exclusion and the protection cannot drift apart), and the
        // primary's recency is its post-primary value. `lastCopiedAt` /
        // `pinOrdinal` for existing items come from the v1 retention
        // inventory (§3.2 — R1 reuses the v1 summary; the coalesce lane
        // preserves the winner's pin ordinal, `02` §9.5).
        var items: [RetentionExpansionItemSummary] = []
        items.reserveCapacity(
            facts.retention.allItems.count + (primaryIsInsert ? 1 : 0)
        )
        for summary in facts.retention.allItems {
            guard !countVictimIDs.contains(summary.id) else { continue }
            guard let scalars = scalarsByItem[summary.id] else {
                // Unreachable after the both-directions check; kept as the
                // fail-closed defensive path (§3.2: never a zero-byte read).
                throw HistoryFailure.persistence(.invariantViolation)
            }
            let recency = summary.id == primaryID
                ? primaryLastCopiedAt
                : summary.lastCopiedAt
            items.append(RetentionExpansionItemSummary(
                id: summary.id,
                lastCopiedAt: recency,
                pinOrdinal: summary.pinOrdinal,
                canonicalBytes: scalars.canonicalBytes,
                revisionCount: scalars.revisionCount,
                revisionBytes: scalars.revisionBytes
            ))
        }
        if primaryIsInsert {
            // The insert lane (§3.2): the primary's scalars are taken in
            // memory from the signature postings being written — the same
            // one-to-one entries the index delta adds and the R.3 insert
            // stamp persists — and a v1 insert carries an empty revision
            // list, so `revisionCount == 0` / `revisionBytes == 0` (DC-04).
            // Plain addition mirrors `stampForInsert`'s bound justification:
            // each `byteCount` is bounded by the per-representation hard
            // limit and the representation count by `06` §2, so the sum sits
            // far below `Int` overflow.
            var canonicalBytes = 0
            for entry in prepared.signatureEntries {
                canonicalBytes += entry.byteCount
            }
            items.append(RetentionExpansionItemSummary(
                id: primaryID,
                lastCopiedAt: primaryLastCopiedAt,
                pinOrdinal: nil,
                canonicalBytes: canonicalBytes,
                revisionCount: 0,
                revisionBytes: 0
            ))
        }
        // Deterministic fact values: identical stores yield identical
        // inventories regardless of fetch order (the v1 loader's discipline;
        // the planner is order-independent anyway, D16).
        items.sort { $0.id < $1.id }

        // `protected` = pinned ∪ {primary} ∪ count-plan victims (§4.2;
        // D13/D14/plan invariant 7). The pin lane is carried explicitly even
        // though the planner re-filters pinned items, so the composition and
        // the planner postcondition cannot drift apart.
        var protected = Set<HistoryItemID>(minimumCapacity: countVictimIDs.count + 1)
        protected.formUnion(countVictimIDs)
        protected.insert(primaryID)
        for summary in facts.retention.allItems
        where summary.pinOrdinal != nil {
            protected.insert(summary.id)
        }

        // ── Pre-plan R2 feasibility (§8.3) ──
        // The irreducible union — pinned bytes ∪ primary bytes — counted
        // once per item (a pinned coalescing winner is both): no victim
        // selection can reduce it, because pinned items are never retired
        // (D13) and the primary never is (plan invariant 7). This throw
        // lands BEFORE stamping and before the transaction, so nothing
        // durable exists — the primary insert does not land (atomicity).
        if let storagePolicy = policies.storage {
            var irreducibleBytes = 0
            for item in items
            where item.pinOrdinal != nil || item.id == primaryID {
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

        // ── Pure expansion planning (§4.2) ──
        // `now` is the capture's `observedAt` — already a Domain input; the
        // RetentionClock is NOT read on the capture lane (§6.4/DC-28).
        let expansion = planItemRetentionExpansion(
            inventory: CompleteRetentionExpansionInventory(items: items),
            policies: policies,
            protected: protected,
            now: prepared.domain.observedAt
        )

        // Defensive plan-invariant-7 backstop: the planner's `protected`
        // filter already makes a primary retirement impossible; failing
        // closed here keeps this composition honest if that contract ever
        // drifts (the stamper's additions/removals guard covers only the
        // insert lane, not a coalescing primary).
        for retirement in expansion.retirements {
            guard case .retire(let itemID, _) = retirement,
                  itemID != primaryID else {
                throw HistoryFailure.persistence(.invariantViolation)
            }
        }

        // The merge (§4.2): v1 mutations first, retirements after — one
        // deterministic order; the outcome is the v1 plan's (retirements do
        // NOT change the capture receipt). An empty retirement list yields
        // the v1 mutations unchanged.
        var mutations = v1Plan.mutations
        mutations.append(contentsOf: expansion.retirements)
        return MutationPlan(outcome: v1Plan.outcome, mutations: mutations)
    }
}
