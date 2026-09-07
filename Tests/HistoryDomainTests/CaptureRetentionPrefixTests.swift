import Foundation
import HistoryCore
import Testing
@testable import HistoryDomain

struct CaptureRetentionPrefixTests {
    private func prefix(
        through id: HistoryItemID, count: Int, excluding primary: HistoryItemID?
    ) -> RetentionRetirementPrefix {
        RetentionRetirementPrefix(
            through: RetentionEvictionKey(lastCopiedAt: Date(timeIntervalSinceReferenceDate: 2), itemID: id),
            excludedItemID: primary, itemCount: count, canonicalBytes: count, revisionBytes: 0
        )
    }

    @Test func globalCountsChooseBoundaryWithoutCompleteInventory() throws {
        let canonical = try captureCanonical([("public.utf8-plain-text", "incoming", 1)])
        let capture = preparedCapture(canonical: canonical, observedAt: 500)
        let expected = prefix(through: capturePlannerID(1), count: 1, excluding: capture.candidateID)
        let result = try planCapture(
            capture,
            facts: IngestFacts(confirmedMatch: nil, candidateIDExists: false,
                retention: CaptureRetentionFacts(
                    retainedCount: 1_000, unpinnedCount: 1_000, retirementPrefix: expected)),
            retention: RetentionPolicy(maximumUnpinnedItems: 1_000),
            hardMaximumRetainedItems: 1_000
        )
        guard case .commit(let plan) = result, plan.mutations.count == 2,
              case .retirePrefix(let selected) = plan.mutations[1] else {
            Issue.record("Complete counts require one bounded retirement payload")
            return
        }
        #expect(selected == expected)
    }

    @Test func coalescingPrimaryIsExcludedFromBoundary() throws {
        let canonical = try captureCanonical([("public.utf8-plain-text", "same", 1)])
        let winner = captureItem(id: capturePlannerID(1), canonical: canonical, lastCopiedAt: 1)
        let match = CaptureMatch(id: winner.id, occurrence: winner.occurrence, pinOrdinal: nil)
        let expected = prefix(through: capturePlannerID(2), count: 1, excluding: winner.id)
        let result = try planCapture(
            preparedCapture(canonical: canonical, observedAt: 500),
            facts: IngestFacts(confirmedMatch: match, candidateIDExists: false,
                retention: CaptureRetentionFacts(
                    retainedCount: 1_001, unpinnedCount: 1_001, retirementPrefix: expected)),
            retention: RetentionPolicy(maximumUnpinnedItems: 1_000),
            hardMaximumRetainedItems: 2_000
        )
        guard case .commit(let plan) = result, plan.mutations.count == 2,
              case .coalesced(let id) = plan.outcome,
              case .retirePrefix(let selected) = plan.mutations[1] else {
            Issue.record("Expected coalescing with one different count victim")
            return
        }
        #expect(id == winner.id)
        #expect(selected == expected)
        #expect(!selected.contains(captureSummary(winner)))
    }

    @Test func captureRejectsMissingWrongCountOrWrongExclusionPrefix() throws {
        let canonical = try captureCanonical([("public.utf8-plain-text", "incoming", 1)])
        let capture = preparedCapture(canonical: canonical, observedAt: 500)
        let malformed: [RetentionRetirementPrefix?] = [
            nil,
            prefix(through: capturePlannerID(1), count: 2, excluding: capture.candidateID),
            prefix(through: capturePlannerID(1), count: 1, excluding: nil),
            prefix(through: capture.candidateID, count: 1, excluding: capture.candidateID),
        ]
        for selected in malformed {
            #expect(throws: DomainRejection.corruptLineage) {
                try planCapture(capture,
                    facts: IngestFacts(confirmedMatch: nil, candidateIDExists: false,
                        retention: CaptureRetentionFacts(
                            retainedCount: 10, unpinnedCount: 10, retirementPrefix: selected)),
                    retention: RetentionPolicy(maximumUnpinnedItems: 10),
                    hardMaximumRetainedItems: 10
                )
            }
        }
    }

    @Test func captureRejectsAnUnnecessaryPrefix() throws {
        let canonical = try captureCanonical([("public.utf8-plain-text", "incoming", 1)])
        let capture = preparedCapture(canonical: canonical, observedAt: 500)
        #expect(throws: DomainRejection.corruptLineage) {
            try planCapture(capture,
                facts: IngestFacts(confirmedMatch: nil, candidateIDExists: false,
                    retention: CaptureRetentionFacts(retainedCount: 1, unpinnedCount: 1,
                        retirementPrefix: prefix(through: capturePlannerID(1),
                            count: 1, excluding: capture.candidateID))),
                retention: RetentionPolicy(maximumUnpinnedItems: 10),
                hardMaximumRetainedItems: 10
            )
        }
    }

    @Test func countCalculationRejectsWinnerContradictingAggregates() throws {
        let canonical = try captureCanonical([("public.utf8-plain-text", "same", 1)])
        let winner = captureItem(id: capturePlannerID(1), canonical: canonical, lastCopiedAt: 1)
        let scenarios: [(retained: Int, unpinned: Int, pin: PinOrdinal?)] = [
            (0, 0, nil),
            (0, 0, PinOrdinal(rawValue: 0)),
            (1, 1, PinOrdinal(rawValue: 0)),
        ]
        for scenario in scenarios {
            let match = CaptureMatch(
                id: winner.id, occurrence: winner.occurrence, pinOrdinal: scenario.pin)
            #expect(throws: DomainRejection.corruptLineage) {
                try captureRetirementCount(
                    confirmedMatch: match, retainedCount: scenario.retained,
                    unpinnedCount: scenario.unpinned,
                    retention: RetentionPolicy(maximumUnpinnedItems: 10),
                    hardMaximumRetainedItems: 10
                )
            }
        }
    }

    @Test func countCalculationRejectsOverflowAndPreservesPinnedExemption() throws {
        let canonical = try captureCanonical([("public.utf8-plain-text", "same", 1)])
        let winner = captureItem(id: capturePlannerID(1), canonical: canonical,
            lastCopiedAt: 1, pinOrdinal: PinOrdinal(rawValue: 0))
        let match = CaptureMatch(id: winner.id, occurrence: winner.occurrence, pinOrdinal: winner.pinOrdinal)
        #expect(try captureRetirementCount(confirmedMatch: match,
            retainedCount: 11, unpinnedCount: 10,
            retention: RetentionPolicy(maximumUnpinnedItems: 9),
            hardMaximumRetainedItems: 11) == 1)
        #expect(throws: DomainRejection.capacityExceeded(.retainedItems)) {
            try captureRetirementCount(confirmedMatch: nil,
                retainedCount: Int.max, unpinnedCount: Int.max,
                retention: RetentionPolicy(maximumUnpinnedItems: 1),
                hardMaximumRetainedItems: Int.max)
        }
    }
}
