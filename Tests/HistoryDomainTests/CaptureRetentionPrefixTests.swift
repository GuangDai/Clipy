import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

struct CaptureRetentionPrefixTests {
    @Test func globalCountsChooseVictimWithoutCompleteInventory() throws {
        let canonical = try captureCanonical([("public.utf8-plain-text", "incoming", 1)])
        let oldest = [1, 2].map { index in
            RetainedItemSummary(
                id: capturePlannerID(UInt8(index)),
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: Double(index)),
                pinOrdinal: nil
            )
        }
        let result = try planCapture(
            preparedCapture(canonical: canonical, observedAt: 500),
            facts: IngestFacts(
                hintedItem: nil,
                candidates: CompleteDedupCandidates(items: []),
                candidateIDExists: false,
                retention: CaptureRetentionFacts(
                    retainedCount: 1_000, unpinnedCount: 1_000,
                    oldestUnpinnedItems: oldest
                )
            ),
            retention: RetentionPolicy(maximumUnpinnedItems: 1_000),
            hardMaximumRetainedItems: 1_000
        )
        guard case .commit(let plan) = result,
              plan.mutations.count == 2,
              case .retire(let victim, .retention) = plan.mutations[1] else {
            Issue.record("The complete counts require one retirement")
            return
        }
        #expect(victim == oldest[0].id)
    }

    @Test func coalescingPrimaryIsExcludedFromOldestPrefix() throws {
        let canonical = try captureCanonical([("public.utf8-plain-text", "same", 1)])
        let winner = captureItem(id: capturePlannerID(1), canonical: canonical, lastCopiedAt: 1)
        let next = RetainedItemSummary(
            id: capturePlannerID(2), lastCopiedAt: Date(timeIntervalSinceReferenceDate: 2), pinOrdinal: nil
        )
        let result = try planCapture(
            preparedCapture(canonical: canonical, observedAt: 500),
            facts: IngestFacts(
                hintedItem: nil,
                candidates: CompleteDedupCandidates(items: [winner]),
                candidateIDExists: false,
                retention: CaptureRetentionFacts(
                    retainedCount: 1_001, unpinnedCount: 1_001,
                    oldestUnpinnedItems: [captureSummary(winner), next]
                )
            ),
            retention: RetentionPolicy(maximumUnpinnedItems: 1_000),
            hardMaximumRetainedItems: 2_000
        )
        guard case .commit(let plan) = result,
              plan.mutations.count == 2,
              case .coalesced(let id) = plan.outcome,
              case .retire(let victim, .retention) = plan.mutations[1] else {
            Issue.record("Expected coalescing with one different count victim")
            return
        }
        #expect(id == winner.id)
        #expect(victim == next.id)
    }
}
