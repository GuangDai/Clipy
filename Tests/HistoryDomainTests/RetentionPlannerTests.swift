/// Pure retention-planner tests (docs/02-domain.md §12, D13/D16/D18–D19).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

private func retentionID(_ suffix: UInt8) -> HistoryItemID {
    HistoryItemID(rawValue: UUID(uuid: (
        0, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0, 0, suffix
    )))
}

private enum RetentionPlannerTestError: Error {
    case expectedCommit
    case unexpectedMutation
}

private func retentionVictims(
    inventory: [RetainedItemSummary],
    policy: RetentionPolicy
) throws -> [HistoryItemID] {
    let result = planRetention(
        facts: RetentionFacts(
            inventory: CompleteRetentionInventory(allItems: inventory),
            currentPolicy: RetentionPolicy(maximumUnpinnedItems: 3)
        ),
        policy: policy
    )
    guard case .commit(let plan) = result,
          case .retentionPolicySet(let removedCount) = plan.outcome,
          plan.mutations.count == removedCount + 1,
          case .setRetentionPolicy(let plannedMaximum) = plan.mutations[0],
          plannedMaximum == policy.maximumUnpinnedItems
    else {
        throw RetentionPlannerTestError.expectedCommit
    }
    return try plan.mutations.dropFirst().map { mutation in
        guard case .retire(let itemID, .retention) = mutation else {
            throw RetentionPlannerTestError.unexpectedMutation
        }
        return itemID
    }
}

@Test func unchangedRetentionPolicyWithinBoundProducesNoPlan() {
    let inventory = CompleteRetentionInventory(allItems: [
        RetainedItemSummary(
            id: retentionID(3),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 300),
            pinOrdinal: nil
        ),
        RetainedItemSummary(
            id: retentionID(1),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            pinOrdinal: nil
        ),
        RetainedItemSummary(
            id: retentionID(2),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 200),
            pinOrdinal: PinOrdinal(rawValue: 0)
        ),
    ])
    let policy = RetentionPolicy(maximumUnpinnedItems: 2)
    let facts = RetentionFacts(
        inventory: inventory,
        currentPolicy: policy
    )

    switch planRetention(facts: facts, policy: policy) {
    case .unchanged:
        break
    case .commit:
        Issue.record("An already-satisfied retention policy produced a commit")
    }
}

@Test func changingAnAlreadySatisfiedPolicyCommitsOnlyThePolicyPayload() {
    let item = RetainedItemSummary(
        id: retentionID(1),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
        pinOrdinal: nil
    )
    let result = planRetention(
        facts: RetentionFacts(
            inventory: CompleteRetentionInventory(allItems: [item]),
            currentPolicy: RetentionPolicy(maximumUnpinnedItems: 3)
        ),
        policy: RetentionPolicy(maximumUnpinnedItems: 2)
    )

    guard case .commit(let plan) = result,
          case .retentionPolicySet(let removedCount) = plan.outcome,
          removedCount == 0,
          plan.mutations.count == 1,
          case .setRetentionPolicy(let maximum) = plan.mutations[0]
    else {
        Issue.record("A changed but already-satisfied policy emitted an incomplete plan")
        return
    }
    #expect(maximum == 2)
}

@Test func unchangedButOverLimitPolicyStillRetiresTheCompleteExcess() throws {
    let oldest = RetainedItemSummary(
        id: retentionID(1),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
        pinOrdinal: nil
    )
    let newest = RetainedItemSummary(
        id: retentionID(2),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 200),
        pinOrdinal: nil
    )
    let policy = RetentionPolicy(maximumUnpinnedItems: 1)
    let result = planRetention(
        facts: RetentionFacts(
            inventory: CompleteRetentionInventory(allItems: [newest, oldest]),
            currentPolicy: policy
        ),
        policy: policy
    )

    guard case .commit(let plan) = result,
          case .retentionPolicySet(let removedCount) = plan.outcome,
          removedCount == 1,
          plan.mutations.count == 2,
          case .setRetentionPolicy(let maximum) = plan.mutations[0],
          case .retire(let retiredID, .retention) = plan.mutations[1]
    else {
        Issue.record("An over-limit inventory incorrectly took the policy no-op branch")
        return
    }
    #expect(maximum == 1)
    #expect(retiredID == oldest.id)
}

@Test func loweringRetentionPolicyProducesCompleteDeterministicVictimPayloads() throws {
    let oldest = RetainedItemSummary(
        id: retentionID(1),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
        pinOrdinal: nil
    )
    let middle = RetainedItemSummary(
        id: retentionID(2),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 200),
        pinOrdinal: nil
    )
    let newest = RetainedItemSummary(
        id: retentionID(3),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 300),
        pinOrdinal: nil
    )
    let pinnedOldest = RetainedItemSummary(
        id: retentionID(4),
        lastCopiedAt: Date(timeIntervalSinceReferenceDate: 1),
        pinOrdinal: PinOrdinal(rawValue: 0)
    )
    let policy = RetentionPolicy(maximumUnpinnedItems: 1)

    #expect(
        try retentionVictims(
            inventory: [newest, pinnedOldest, oldest, middle],
            policy: policy
        ) == [oldest.id, middle.id]
    )
    #expect(
        try retentionVictims(
            inventory: [middle, oldest, pinnedOldest, newest],
            policy: policy
        ) == [oldest.id, middle.id]
    )
}

@Test func equalRecencyVictimsUseTheStableItemIDTieBreaker() throws {
    let copiedAt = Date(timeIntervalSinceReferenceDate: 100)
    let smallerID = RetainedItemSummary(
        id: retentionID(1),
        lastCopiedAt: copiedAt,
        pinOrdinal: nil
    )
    let largerID = RetainedItemSummary(
        id: retentionID(2),
        lastCopiedAt: copiedAt,
        pinOrdinal: nil
    )
    let policy = RetentionPolicy(maximumUnpinnedItems: 1)

    #expect(
        try retentionVictims(
            inventory: [largerID, smallerID],
            policy: policy
        ) == [smallerID.id]
    )
    #expect(
        try retentionVictims(
            inventory: [smallerID, largerID],
            policy: policy
        ) == [smallerID.id]
    )
}

@Test func oneVictimFromALargerInventoryPreservesStableOrdering() throws {
    let oldestDate = Date(timeIntervalSinceReferenceDate: 100)
    let expected = RetainedItemSummary(
        id: retentionID(1),
        lastCopiedAt: oldestDate,
        pinOrdinal: nil
    )
    let sameAgeLargerID = RetainedItemSummary(
        id: retentionID(2),
        lastCopiedAt: oldestDate,
        pinOrdinal: nil
    )
    let newer = (3...5).map { suffix in
        RetainedItemSummary(
            id: retentionID(UInt8(suffix)),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: Double(suffix * 100)),
            pinOrdinal: nil
        )
    }
    let inventory = [newer[1], sameAgeLargerID, newer[0], expected, newer[2]]

    #expect(try retentionVictims(
        inventory: inventory,
        policy: RetentionPolicy(maximumUnpinnedItems: 4)
    ) == [expected.id])
}
