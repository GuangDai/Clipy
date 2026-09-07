/// Pure count-policy planning tests (02 §12, D13/D16/D18–D19).
import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

private func retentionID(_ suffix: UInt8) -> HistoryItemID {
    capturePlannerID(suffix)
}

/// Test-only inventory reference: summary fixtures have one Canonical byte
/// and no revisions. Production selects this boundary and aggregates in SQL.
internal func retentionTestPrefix(
    inventory: [RetainedItemSummary],
    maximumUnpinnedItems: Int
) -> RetentionRetirementPrefix? {
    let eligible = inventory.filter { $0.pinOrdinal == nil }.sorted {
        RetentionEvictionKey(lastCopiedAt: $0.lastCopiedAt, itemID: $0.id)
            < RetentionEvictionKey(lastCopiedAt: $1.lastCopiedAt, itemID: $1.id)
    }
    let victims = eligible.prefix(max(0, eligible.count - maximumUnpinnedItems))
    return victims.last.map {
        RetentionRetirementPrefix(
            through: RetentionEvictionKey(lastCopiedAt: $0.lastCopiedAt, itemID: $0.id),
            excludedItemID: nil, itemCount: victims.count,
            canonicalBytes: victims.count, revisionBytes: 0
        )
    }
}

@Test func exactRetentionPrefixPreservesPolicyAndRemovalSemantics() {
    let policy = RetentionPolicy(maximumUnpinnedItems: 2)
    if case .commit = planRetention(currentPolicy: policy, policy: policy, retirementPrefix: nil) {
        Issue.record("Same policy without required victims must not commit")
    }
    // Boundary identity need not be the largest ID: time ranks first.
    for count in [1, 2, 5_000] {
        let prefix = RetentionRetirementPrefix(
            through: RetentionEvictionKey(
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: 10), itemID: retentionID(1)),
            excludedItemID: nil, itemCount: count,
            canonicalBytes: count * 7, revisionBytes: count * 3
        )
        for oldLimit in [2, 3] {
            let result = planRetention(
                currentPolicy: RetentionPolicy(maximumUnpinnedItems: oldLimit),
                policy: policy, retirementPrefix: prefix
            )
            guard case .commit(let plan) = result,
                  case .retentionPolicySet(let removedCount) = plan.outcome,
                  plan.mutations.count == 2,
                  case .setRetentionPolicy(let maximum) = plan.mutations[0],
                  case .retirePrefix(let planned) = plan.mutations[1] else {
                Issue.record("Expected one policy and one bounded retirement payload")
                continue
            }
            #expect(maximum == 2)
            #expect(removedCount == count)
            #expect(planned == prefix)
        }
    }
}

@Test func changingAnAlreadySatisfiedPolicyCommitsOnlyThePolicyPayload() {
    let result = planRetention(
        currentPolicy: RetentionPolicy(maximumUnpinnedItems: 3),
        policy: RetentionPolicy(maximumUnpinnedItems: 2), retirementPrefix: nil
    )
    guard case .commit(let plan) = result,
          case .retentionPolicySet(let removedCount) = plan.outcome,
          removedCount == 0,
          plan.mutations.count == 1,
          case .setRetentionPolicy(let maximum) = plan.mutations[0] else {
        Issue.record("A changed satisfied policy must emit only its payload")
        return
    }
    #expect(maximum == 2)
}

@Test func retirementBoundaryUsesTimeThenIDAndExcludesPinnedRows() {
    let date = Date(timeIntervalSinceReferenceDate: 100)
    let oldest = RetainedItemSummary(id: retentionID(9),
        lastCopiedAt: date.addingTimeInterval(-1), pinOrdinal: nil)
    let smaller = RetainedItemSummary(id: retentionID(1), lastCopiedAt: date, pinOrdinal: nil)
    let larger = RetainedItemSummary(id: retentionID(2), lastCopiedAt: date, pinOrdinal: nil)
    let pinned = RetainedItemSummary(id: retentionID(3),
        lastCopiedAt: date.addingTimeInterval(-2), pinOrdinal: PinOrdinal(rawValue: 0))
    let prefix = RetentionRetirementPrefix(
        through: RetentionEvictionKey(lastCopiedAt: date, itemID: smaller.id),
        excludedItemID: nil, itemCount: 2, canonicalBytes: 2, revisionBytes: 0
    )
    #expect(prefix.contains(oldest))
    #expect(prefix.contains(smaller))
    #expect(!prefix.contains(larger))
    #expect(!prefix.contains(pinned))
    let result = planRetention(
        currentPolicy: RetentionPolicy(maximumUnpinnedItems: 1),
        policy: RetentionPolicy(maximumUnpinnedItems: 1), retirementPrefix: prefix
    )
    guard case .commit(let plan) = result,
          case .retentionPolicySet(let removedCount) = plan.outcome else {
        Issue.record("Unchanged over-limit policy must still retire its prefix")
        return
    }
    #expect(removedCount == 2)
    #expect(plan.mutations.count == 2)
}
