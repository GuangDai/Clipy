/// Pure V2-02 expansion-planner tests for R1 (age) + R2 (storage bytes):
/// docs/v2/V2-02-retention.md §4.1/§4.2 (selection), §6.5 (signature,
/// non-throwing), §11 (D24). Discharges the Domain half of `RET-SELECT-1`
/// (strict R1 boundary, oldest-first eviction order, R1-before-R2 union with
/// no duplicate `HistoryItemID`, victim safety, satisfying-state no-op) plus
/// the D16 determinism fixture and the checked-overflow fixture
/// (`V2-roadmap` §6 R.2).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

private func expansionID(_ suffix: UInt8) -> HistoryItemID {
    HistoryItemID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

/// One projected-inventory row; `byteCount` splits into canonical bytes plus
/// revision content bytes so both R2 addends are exercised.
private func expansionItem(
    _ suffix: UInt8,
    copiedAt seconds: Double,
    pinned: PinOrdinal? = nil,
    canonicalBytes: Int,
    revisionBytes: Int = 0
) -> RetentionExpansionItemSummary {
    RetentionExpansionItemSummary(
        id: expansionID(suffix),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: seconds),
        pinOrdinal: pinned,
        canonicalBytes: canonicalBytes,
        revisionCount: revisionBytes > 0 ? 2 : 0,
        revisionBytes: revisionBytes
    )
}

private enum RetentionExpansionPlannerTestError: Error {
    case unexpectedMutation
    case countMismatch
}

/// Runs the planner and extracts the retired IDs, proving every retirement
/// is `.retire(itemID:, .retention)` and `retiredItems` agrees with the
/// payload list (D24 dedup surface).
private func plannedRetirements(
    inventory: [RetentionExpansionItemSummary],
    policies: HistoryRetentionPolicies,
    protected: Set<HistoryItemID> = [],
    now: Date
) throws -> [HistoryItemID] {
    let plan = planItemRetentionExpansion(
        inventory: CompleteRetentionExpansionInventory(items: inventory),
        policies: policies,
        protected: protected,
        now: now
    )
    var ids: [HistoryItemID] = []
    ids.reserveCapacity(plan.retirements.count)
    for mutation in plan.retirements {
        guard case .retire(let itemID, .retention) = mutation else {
            throw RetentionExpansionPlannerTestError.unexpectedMutation
        }
        ids.append(itemID)
    }
    guard plan.retiredItems == ids.count else {
        throw RetentionExpansionPlannerTestError.countMismatch
    }
    return ids
}

// MARK: - R1 strict age selection (V2-02 §4.2; RET-SELECT-1(a))

@Test func r1BoundaryIsStrictAgeExactlyMaxAgeIsNotRetired() throws {
    // now = 1000, maxAge = 100 → cutoff 900. The item copied at exactly 900
    // is exactly maxAge old: the comparison is strict `<`, so it stays.
    let exactlyAtBoundary = expansionItem(1, copiedAt: 900, canonicalBytes: 10)
    let justOver = expansionItem(2, copiedAt: 899, canonicalBytes: 10)
    let muchOlder = expansionItem(3, copiedAt: 500, canonicalBytes: 10)
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 100),
        storage: nil,
        revisions: nil
    )

    let retired = try plannedRetirements(
        inventory: [exactlyAtBoundary, justOver, muchOlder],
        policies: policies,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    // Oldest-first eviction order (02 §12): muchOlder(500), justOver(899).
    #expect(retired == [muchOlder.id, justOver.id])
}

@Test func r1RetiresOldestFirstWithTheStableItemIDTieBreaker() throws {
    let smallerID = expansionItem(1, copiedAt: 800, canonicalBytes: 10)
    let largerID = expansionItem(2, copiedAt: 800, canonicalBytes: 10)
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 100),
        storage: nil,
        revisions: nil
    )

    // Equal lastCopiedAt ties break on HistoryItemID bytes ascending
    // (02 §12) and the result is independent of inventory ordering (D16).
    let first = try plannedRetirements(
        inventory: [largerID, smallerID],
        policies: policies,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    let second = try plannedRetirements(
        inventory: [smallerID, largerID],
        policies: policies,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(first == [smallerID.id, largerID.id])
    #expect(second == first)
}

@Test func r1NeverRetiresPinnedPrimaryOrCountVictims() throws {
    // D13/D14 (V2-02 §4.2): `protected` = pinned ∪ {primary} ∪
    // already-retired-by-count victims; the pin filter restates D13 locally.
    let pinnedOld = expansionItem(
        1, copiedAt: 100, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 10
    )
    let primaryOld = expansionItem(2, copiedAt: 100, canonicalBytes: 10)
    let countVictimOld = expansionItem(3, copiedAt: 100, canonicalBytes: 10)
    let eligibleOld = expansionItem(4, copiedAt: 100, canonicalBytes: 10)
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 100),
        // A budget no retirement can restore: even retiring everything
        // eligible leaves pinned + primary + count-victim bytes over budget,
        // so this also proves protection holds under R2 pressure.
        storage: StorageRetention(maxTotalBytes: 1),
        revisions: nil
    )

    let retired = try plannedRetirements(
        inventory: [pinnedOld, primaryOld, countVictimOld, eligibleOld],
        policies: policies,
        protected: [primaryOld.id, countVictimOld.id],
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(retired == [eligibleOld.id])
}

@Test func noActiveItemDimensionYieldsTheEmptyPlan() throws {
    // §4.1: with no V2-02 policy active the pass is a no-op — including an
    // R3-only configuration (§7: R3 never fires through the item planner).
    let items = (1...3).map {
        expansionItem(UInt8($0), copiedAt: Double($0), canonicalBytes: 10)
    }
    let now = Date(timeIntervalSinceReferenceDate: 1000)
    for policies in [
        HistoryRetentionPolicies(age: nil, storage: nil, revisions: nil),
        HistoryRetentionPolicies(
            age: nil,
            storage: nil,
            revisions: RevisionRetention(
                maxRevisionsPerItem: 1,
                maxRevisionBytesPerItem: nil
            )
        ),
    ] {
        let plan = planItemRetentionExpansion(
            inventory: CompleteRetentionExpansionInventory(items: items),
            policies: policies,
            protected: [],
            now: now
        )
        #expect(plan.retirements.isEmpty)
        #expect(plan.retiredItems == 0)
    }
}

// MARK: - R2 byte budget (V2-02 §4.2; RET-SELECT-1(b))

@Test func r2RestoresTheBudgetUntilWithinBoundNeverFurther() throws {
    // Projected totals (canonical + revision bytes, protected included
    // because they remain retained): 100 + 300 + 200 + 150 + 100 = 850 over
    // a 700 budget. Retiring O1 (300, oldest eligible) restores 550 <= 700;
    // O2 and O3 must survive even though retiring them would also fit.
    let pinned = expansionItem(
        1, copiedAt: 50, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 100
    )
    let oldest = expansionItem(2, copiedAt: 100, canonicalBytes: 100, revisionBytes: 200)
    let middle = expansionItem(3, copiedAt: 200, canonicalBytes: 200)
    let newest = expansionItem(4, copiedAt: 300, canonicalBytes: 150)
    let primary = expansionItem(5, copiedAt: 400, canonicalBytes: 100)
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: StorageRetention(maxTotalBytes: 700),
        revisions: nil
    )

    let retired = try plannedRetirements(
        inventory: [pinned, oldest, middle, newest, primary],
        policies: policies,
        protected: [primary.id],
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(retired == [oldest.id])
}

@Test func alreadySatisfyingStateYieldsNoRetirement() throws {
    // RET-SELECT-1(e): a satisfying state yields no retirement — the
    // eviction order is never even established.
    let item = expansionItem(1, copiedAt: 100, canonicalBytes: 50)
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: StorageRetention(maxTotalBytes: 50),
        revisions: nil
    )

    let plan = planItemRetentionExpansion(
        inventory: CompleteRetentionExpansionInventory(items: [item]),
        policies: policies,
        protected: [],
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(plan.retirements.isEmpty)
    #expect(plan.retiredItems == 0)
}

// MARK: - R1-before-R2 union (V2-02 §4.1; RET-SELECT-1(d))

@Test func r1VictimsAreExcludedFromTheProjectedByteTotalAndDeduplicated() throws {
    // now = 1000, maxAge = 300 → cutoff 700. O1 (t=100, 500 bytes) is the
    // sole aged item, so it is the sole R1 victim. Post-R1 projected total:
    // 100 (pinned) + 200 (O2) + 150 (O3) + 100 (primary) = 550.
    let pinned = expansionItem(
        1, copiedAt: 50, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 100
    )
    let agedVictim = expansionItem(2, copiedAt: 100, canonicalBytes: 500)
    let newer = expansionItem(3, copiedAt: 800, canonicalBytes: 200)
    let newest = expansionItem(4, copiedAt: 900, canonicalBytes: 150)
    let primary = expansionItem(5, copiedAt: 950, canonicalBytes: 100)
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 300),
        storage: StorageRetention(maxTotalBytes: 700),
        revisions: nil
    )
    let now = Date(timeIntervalSinceReferenceDate: 1000)

    // Budget 700: the post-R1 total 550 already satisfies it, so the union
    // is exactly the R1 victim — emitted once, never double-counted or
    // double-retired.
    let withinBudget = try plannedRetirements(
        inventory: [pinned, agedVictim, newer, newest, primary],
        policies: policies,
        protected: [primary.id],
        now: now
    )
    #expect(withinBudget == [agedVictim.id])

    // Budget 500: post-R1 total 550 exceeds it, so R2 retires the oldest
    // eligible survivor O2 (200 bytes) → 350 <= 500. The union is
    // [O1, O2] — globally oldest-first (every R1 victim precedes every R2
    // candidate in the eviction order) and deduplicated.
    let tighter = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 300),
        storage: StorageRetention(maxTotalBytes: 500),
        revisions: nil
    )
    let union = try plannedRetirements(
        inventory: [pinned, agedVictim, newer, newest, primary],
        policies: tighter,
        protected: [primary.id],
        now: now
    )
    #expect(union == [agedVictim.id, newer.id])
    #expect(Set(union).count == union.count)
}

// MARK: - Unsatisfiable budget and checked bytes (V2-02 §4.2, §6.5)

@Test func unsatisfiableBudgetDefensivelyRetiresEveryEligibleVictim() throws {
    // §6.5: the pre-plan feasibility check (pinned + primary bytes >
    // maxTotalBytes) is Storage's `.capacityExceeded(.storageBytes)`
    // producer and runs before any R2 retirement is planned, so the
    // pipeline never builds a maximal-doomed plan. The pure planner is
    // nevertheless total: handed such facts it deterministically retires
    // every eligible victim and still never a protected one (D24(b)).
    let pinnedHeavy = expansionItem(
        1, copiedAt: 50, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 600
    )
    let primaryHeavy = expansionItem(2, copiedAt: 900, canonicalBytes: 200)
    let onlyEligible = expansionItem(3, copiedAt: 100, canonicalBytes: 100)
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: StorageRetention(maxTotalBytes: 500),
        revisions: nil
    )

    let retired = try plannedRetirements(
        inventory: [pinnedHeavy, primaryHeavy, onlyEligible],
        policies: policies,
        protected: [primaryHeavy.id],
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(retired == [onlyEligible.id])
}

@Test func byteTotalOverflowSaturatesAndNeverWrapsOrUnderRetires() throws {
    // §4.2 (06 §2 checked arithmetic): two footprints of
    // Int.max / 2 + 1_000 bytes each cannot be summed without overflowing
    // Int. Overflow is impossible within the validated 5,000 × 384 MiB
    // worst case (§8.3) but enforced defensively: the running total
    // saturates at Int.max — never wraps, never under-retires — while the
    // typed `.persistence(.invariantViolation)` fail-closed mapping stays
    // at the Storage pipeline boundary because §6.5 keeps the planner
    // non-throwing.
    let older = expansionItem(1, copiedAt: 100, canonicalBytes: Int.max / 2 + 1_000)
    let newer = expansionItem(2, copiedAt: 200, canonicalBytes: Int.max / 2 + 1_000)
    let pinned = expansionItem(
        3, copiedAt: 50, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 10
    )
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: StorageRetention(maxTotalBytes: 1_000),
        revisions: nil
    )

    let retired = try plannedRetirements(
        inventory: [pinned, newer, older],
        policies: policies,
        protected: [],
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    // The saturated total can never reach the budget, so both eligible
    // victims retire, oldest-first, and the pinned row survives (D13).
    #expect(retired == [older.id, newer.id])
}

// MARK: - Determinism and D24 postconditions (V2-02 §11)

@Test func identicalFactsInDifferentInventoryOrderProduceIdenticalPlans() throws {
    // D16: a deterministic pure function of (inventory, policies,
    // protected, now). Unique IDs make the eviction order total, so input
    // ordering cannot leak into the plan.
    let pinned = expansionItem(
        1, copiedAt: 50, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 100
    )
    let agedVictim = expansionItem(2, copiedAt: 100, canonicalBytes: 500)
    let newer = expansionItem(3, copiedAt: 800, canonicalBytes: 200)
    let newest = expansionItem(4, copiedAt: 900, canonicalBytes: 150)
    let primary = expansionItem(5, copiedAt: 950, canonicalBytes: 100)
    let inventoryOrderOne = [pinned, agedVictim, newer, newest, primary]
    let inventoryOrderTwo = [newest, primary, pinned, newer, agedVictim]
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 300),
        storage: StorageRetention(maxTotalBytes: 500),
        revisions: nil
    )
    let now = Date(timeIntervalSinceReferenceDate: 1000)

    let one = try plannedRetirements(
        inventory: inventoryOrderOne, policies: policies, protected: [primary.id], now: now
    )
    let two = try plannedRetirements(
        inventory: inventoryOrderTwo, policies: policies, protected: [primary.id], now: now
    )
    #expect(one == two)
    #expect(one == [agedVictim.id, newer.id])
}

@Test func d24VictimSafetyUnionShapeAndCountHold() {
    // D24 (V2-02 §11): one deduplicated R1 ∪ R2 union whose victims are a
    // subset of the unprotected, unpinned rows; `retiredItems` counts the
    // payload retirements exactly.
    let pinnedA = expansionItem(
        1, copiedAt: 50, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 400
    )
    let pinnedB = expansionItem(
        2, copiedAt: 60, pinned: PinOrdinal(rawValue: 1), canonicalBytes: 300
    )
    let primary = expansionItem(3, copiedAt: 990, canonicalBytes: 200)
    let countVictim = expansionItem(4, copiedAt: 120, canonicalBytes: 100)
    let eligibleA = expansionItem(5, copiedAt: 100, canonicalBytes: 500)
    let eligibleB = expansionItem(6, copiedAt: 700, canonicalBytes: 250)
    let eligibleC = expansionItem(7, copiedAt: 950, canonicalBytes: 50)
    let protected: Set<HistoryItemID> = [pinnedA.id, pinnedB.id, primary.id, countVictim.id]
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 300),
        storage: StorageRetention(maxTotalBytes: 800),
        revisions: nil
    )
    // Post-R1 (eligibleA aged) total: 400 + 300 + 200 + 100 + 250 + 50
    // = 1300 > 800 → R2 retires eligibleB (250) → 1050 > 800 → eligibleC
    // (50) → 1000 > 800, no eligible candidate remains: the defensively
    // total unsatisfiable tail (protected bytes alone exceed the budget;
    // §6.5 assigns the typed failure to Storage's pre-plan check).
    let plan = planItemRetentionExpansion(
        inventory: CompleteRetentionExpansionInventory(
            items: [pinnedA, eligibleA, primary, eligibleB, pinnedB, countVictim, eligibleC]
        ),
        policies: policies,
        protected: protected,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )

    var retiredIDs: [HistoryItemID] = []
    for mutation in plan.retirements {
        guard case .retire(let itemID, .retention) = mutation else {
            Issue.record("A non-retire mutation appeared in the expansion plan")
            return
        }
        retiredIDs.append(itemID)
    }
    #expect(retiredIDs == [eligibleA.id, eligibleB.id, eligibleC.id])
    #expect(Set(retiredIDs).count == retiredIDs.count)
    #expect(plan.retiredItems == 3)
    // D24(b): the victim set is disjoint from `protected` (pinned ∪
    // {primary} ∪ count victims) and from every pinned row.
    #expect(Set(retiredIDs).isDisjoint(with: protected))
    let pinnedIDs: Set<HistoryItemID> = [pinnedA.id, pinnedB.id]
    #expect(Set(retiredIDs).isDisjoint(with: pinnedIDs))
}
