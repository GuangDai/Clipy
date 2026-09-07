/// Pure R1/R2 ordered-selection tests (V2-02 §4.1/§4.2): strict age
/// boundaries, oldest-first prefixes, protection, satisfying-state no-op,
/// byte accounting, and checked rejection of corrupt scalars.
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

/// Fixtures model SQL's scalar aggregate and oldest-first cursor. Arrays and
/// prefix membership materialization exist only here, not in the planner.
private func plannedRetirements(
    inventory: [RetentionExpansionItemSummary],
    policies: HistoryRetentionPolicies,
    protectedItemID: HistoryItemID? = nil,
    now: Date
) throws -> [HistoryItemID] {
    let ordered = inventory.sorted {
        RetentionEvictionKey(lastCopiedAt: $0.lastCopiedAt, itemID: $0.id)
            < RetentionEvictionKey(lastCopiedAt: $1.lastCopiedAt, itemID: $1.id)
    }
    var totalBytes = 0
    for item in ordered {
        let (footprint, footprintOverflow) = item.canonicalBytes
            .addingReportingOverflow(item.revisionBytes)
        let (total, totalOverflow) = totalBytes.addingReportingOverflow(footprint)
        guard !footprintOverflow, !totalOverflow else { throw DomainRejection.corruptLineage }
        totalBytes = total
    }
    var selection = OrderedRetentionSelection(
        policies: policies, now: now, protectedItemID: protectedItemID,
        projectedTotalBytes: totalBytes
    )
    for item in ordered {
        if try !selection.consider(item) { break }
    }
    guard let prefix = selection.prefix else {
        #expect(selection.remainingBytes == totalBytes)
        return []
    }
    let victims = ordered.filter {
        prefix.contains(RetainedItemSummary(
            id: $0.id, lastCopiedAt: $0.lastCopiedAt, pinOrdinal: $0.pinOrdinal
        ))
    }
    #expect(prefix.itemCount == victims.count)
    #expect(prefix.canonicalBytes == victims.reduce(0) { $0 + $1.canonicalBytes })
    #expect(prefix.revisionBytes == victims.reduce(0) { $0 + $1.revisionBytes })
    #expect(selection.remainingBytes == totalBytes - prefix.canonicalBytes - prefix.revisionBytes)
    return victims.map(\.id)
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

/// DEC-CAPTURE-CLOCK: the pure planner consumes exactly the caller-selected
/// reference fact. Storage decides which fact is admitted for each lane; the
/// planner neither samples a clock nor normalizes finite skew.
@Test func r1PastAndFutureReferenceSkewRemainDeterministic() throws {
    let item = expansionItem(1, copiedAt: 900, canonicalBytes: 10)
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 100),
        storage: nil,
        revisions: nil
    )

    // A past reference makes cutoff 800, so the t=900 item is not aged.
    let pastReference = try plannedRetirements(
        inventory: [item],
        policies: policies,
        now: Date(timeIntervalSinceReferenceDate: 900)
    )
    #expect(pastReference.isEmpty)

    // A future reference makes cutoff 1,000, so the same item is aged.
    // Repeating identical facts proves the result has no hidden clock read.
    let futureNow = Date(timeIntervalSinceReferenceDate: 1_100)
    let futureReference = try plannedRetirements(
        inventory: [item], policies: policies, now: futureNow
    )
    let repeatedFutureReference = try plannedRetirements(
        inventory: [item], policies: policies, now: futureNow
    )
    #expect(futureReference == [item.id])
    #expect(repeatedFutureReference == futureReference)
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
    // D13/D14 (V2-02 §4.2): pinned rows and the primary remain protected.
    // A count victim is already absent from the projected retained set.
    let pinnedOld = expansionItem(
        1, copiedAt: 100, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 10
    )
    let primaryOld = expansionItem(2, copiedAt: 100, canonicalBytes: 10)
    let countVictimOld = expansionItem(3, copiedAt: 100, canonicalBytes: 10)
    let eligibleOld = expansionItem(4, copiedAt: 100, canonicalBytes: 10)
    let policies = HistoryRetentionPolicies(
        age: AgeRetention(maxAge: 100),
        // A budget no retirement can restore: even retiring everything
        // eligible leaves pinned + primary bytes over budget, so this
        // also proves protection holds under R2 pressure.
        storage: StorageRetention(maxTotalBytes: 1),
        revisions: nil
    )

    let retired = try plannedRetirements(
        inventory: [pinnedOld, primaryOld, countVictimOld, eligibleOld]
            .filter { $0.id != countVictimOld.id },
        policies: policies,
        protectedItemID: primaryOld.id,
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
        let retired = try plannedRetirements(
            inventory: items, policies: policies, now: now
        )
        #expect(retired.isEmpty)
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
        protectedItemID: primary.id,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(retired == [oldest.id])
}

@Test func alreadySatisfyingStateYieldsNoRetirement() throws {
    // RET-SELECT-1(e): a satisfying state yields an empty prefix; the
    // first surviving eligible row ends the ordered scan.
    let item = expansionItem(1, copiedAt: 100, canonicalBytes: 50)
    let policies = HistoryRetentionPolicies(
        age: nil,
        storage: StorageRetention(maxTotalBytes: 50),
        revisions: nil
    )

    let retired = try plannedRetirements(
        inventory: [item],
        policies: policies,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(retired.isEmpty)
}

@Test(arguments: [false, true], [569, 570, 571])
func r2OldestPrefixRespectsByteBoundaryAndProtection(
    _ reverseInventory: Bool, _ budget: Int
) throws {
    let pinned = expansionItem(
        1, copiedAt: 0, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 50
    )
    let primary = expansionItem(2, copiedAt: 0, canonicalBytes: 50)
    let oldest = expansionItem(3, copiedAt: 100, canonicalBytes: 1)
    let tied = expansionItem(4, copiedAt: 100, canonicalBytes: 10, revisionBytes: 10)
    let newer = expansionItem(5, copiedAt: 200, canonicalBytes: 50, revisionBytes: 400)
    let inventory = [newer, tied, pinned, oldest, primary]
    // Total 571: 571 needs no victim, 570 removes the one-byte oldest, and
    // 569 must remove both age-tied rows despite the newer row's 450 bytes.
    let expected: [HistoryItemID] = switch budget {
    case 571: []
    case 570: [oldest.id]
    default: [oldest.id, tied.id]
    }
    let retired = try plannedRetirements(
        inventory: reverseInventory ? Array(inventory.reversed()) : inventory,
        policies: HistoryRetentionPolicies(
            age: nil, storage: StorageRetention(maxTotalBytes: budget), revisions: nil
        ),
        protectedItemID: primary.id,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(retired == expected)
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
        protectedItemID: primary.id,
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
        protectedItemID: primary.id,
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
        protectedItemID: primaryHeavy.id,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(retired == [onlyEligible.id])
}

@Test func overflowingCandidateBytesAreRejectedWithoutSelectingAVictim() {
    // A corrupt per-row footprint must not saturate or wrap into an
    // apparently valid retirement. The fold reports a typed rejection.
    let corrupt = expansionItem(
        1, copiedAt: 100, canonicalBytes: Int.max, revisionBytes: 1
    )
    var selection = OrderedRetentionSelection(
        policies: HistoryRetentionPolicies(
            age: nil, storage: StorageRetention(maxTotalBytes: 1_000), revisions: nil
        ),
        now: Date(timeIntervalSinceReferenceDate: 1000),
        protectedItemID: nil,
        projectedTotalBytes: Int.max
    )
    #expect(throws: DomainRejection.corruptLineage) {
        try selection.consider(corrupt)
    }
    #expect(selection.prefix == nil)
    #expect(selection.remainingBytes == Int.max)
}

// MARK: - Determinism and D24 postconditions (V2-02 §11)

@Test(arguments: [false, true], [0, 1, 2])
func largeInventoryRetainsTheSameProtectedOldestPrefix(
    _ reversed: Bool, _ additionalByteVictims: Int
) throws {
    let pinned = expansionItem(1, copiedAt: 10, pinned: PinOrdinal(rawValue: 0), canonicalBytes: 100)
    let primary = expansionItem(2, copiedAt: 20, canonicalBytes: 100)
    let aged = expansionItem(3, copiedAt: 100, canonicalBytes: 100)
    let oldestSurvivor = expansionItem(4, copiedAt: 800, canonicalBytes: 100)
    let nextSurvivor = expansionItem(5, copiedAt: 850, canonicalBytes: 100)
    var inventory = [pinned, primary, aged, oldestSurvivor, nextSurvivor]
    for index in 0..<4_995 {
        let id = HistoryItemID(rawValue: UUID(uuid: (
            1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            UInt8(index >> 8), UInt8(index & 0xFF)
        )))
        inventory.append(RetentionExpansionItemSummary(
            id: id, lastCopiedAt: Date(timeIntervalSinceReferenceDate: 900 + Double(index)),
            pinOrdinal: nil, canonicalBytes: 100, revisionCount: 0, revisionBytes: 0
        ))
    }
    if reversed { inventory.reverse() }
    let now = Date(timeIntervalSinceReferenceDate: 1000)
    // All 5,000 rows contribute bytes, including pinned and primary rows.
    #expect(try plannedRetirements(
        inventory: inventory,
        policies: HistoryRetentionPolicies(age: nil, storage: StorageRetention(maxTotalBytes: 500_000), revisions: nil),
        protectedItemID: primary.id, now: now
    ).isEmpty)
    // R1 selects only `aged`. R2 either needs no further victim, exactly
    // one, or two; later rows must survive every path and both input orders.
    let victims = try plannedRetirements(
        inventory: inventory,
        policies: HistoryRetentionPolicies(
            age: AgeRetention(maxAge: 300),
            storage: StorageRetention(maxTotalBytes: 500_000 - 100 * (1 + additionalByteVictims)),
            revisions: nil
        ),
        protectedItemID: primary.id, now: now
    )
    let expected = [aged.id] + Array([oldestSurvivor.id, nextSurvivor.id].prefix(additionalByteVictims))
    #expect(victims == expected)
}

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
        inventory: inventoryOrderOne, policies: policies, protectedItemID: primary.id, now: now
    )
    let two = try plannedRetirements(
        inventory: inventoryOrderTwo, policies: policies, protectedItemID: primary.id, now: now
    )
    #expect(one == two)
    #expect(one == [agedVictim.id, newer.id])
}

@Test func d24VictimSafetyUnionShapeAndCountHold() throws {
    // D24 (V2-02 §11): one deduplicated R1 ∪ R2 union whose victims are a
    // subset of the unprotected, unpinned rows; the prefix's item count
    // matches its materialized membership.
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
    // Count retirement has already removed countVictim. After R1 removes
    // eligibleA, 400 + 300 + 200 + 250 + 50 = 1200 bytes remain. R2 removes
    // eligibleB and eligibleC but cannot reach 800: protected bytes alone
    // total 900. Storage handles infeasibility; Domain preserves protection.
    let projectedInventory = [
        pinnedA, eligibleA, primary, eligibleB, pinnedB, countVictim, eligibleC,
    ].filter { $0.id != countVictim.id }
    let retiredIDs = try plannedRetirements(
        inventory: projectedInventory,
        policies: policies,
        protectedItemID: primary.id,
        now: Date(timeIntervalSinceReferenceDate: 1000)
    )
    #expect(retiredIDs == [eligibleA.id, eligibleB.id, eligibleC.id])
    #expect(Set(retiredIDs).count == retiredIDs.count)
    #expect(retiredIDs.count == 3)
    // D24(b): the victim set is disjoint from `protected` (pinned ∪
    // {primary} ∪ count victims) and from every pinned row.
    #expect(Set(retiredIDs).isDisjoint(with: protected))
    let pinnedIDs: Set<HistoryItemID> = [pinnedA.id, pinnedB.id]
    #expect(Set(retiredIDs).isDisjoint(with: pinnedIDs))
}
