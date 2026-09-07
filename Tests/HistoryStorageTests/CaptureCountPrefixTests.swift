import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct CaptureCountPrefixTests {
    /// The capture facts carry two possible oldest victims at a full count
    /// policy regardless of history size. Equal timestamps deliberately make
    /// the persisted UUID ordering column decide the bounded store fetch.
    @Test(arguments: [8, 32])
    func countCaptureLoadsBoundedOldestPrefixAndRetiresExactTieWinner(retainedCount: Int) async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary, initialMaximumUnpinnedItems: retainedCount
        ))
        var ids: [HistoryItemID] = []
        // Reverse insertion order must not become the store's tie breaker.
        for index in (1...retainedCount).reversed() {
            let id = HistoryItemID(rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-" + String(format: "%012llX", UInt64(index))
            )!)
            ids.append(id)
            let preparation = IngestPreparationActor(makeCandidateID: { id })
            let bundle = try await preparation.prepare(WSSupport.textCapture(
                "count prefix \(index)", observedAt: Date(timeIntervalSinceReferenceDate: 830_000_000)
            ))
            _ = try await history.authority.commitCapture(bundle)
        }
        ids.sort()
        let preparation = IngestPreparationActor()
        let incoming = try await preparation.prepare(WSSupport.textCapture(
            // An older incoming timestamp must not make the primary its own
            // victim; only the pre-capture prefix is eligible (02 §12).
            "new oldest primary", observedAt: Date(timeIntervalSinceReferenceDate: 829_000_000)
        ))
        let facts = try await history.authority.countPrefixFacts(
            incoming, maximumUnpinned: retainedCount
        )
        #expect(facts.retention.retainedCount == retainedCount)
        #expect(facts.retention.unpinnedCount == retainedCount)
        #expect(facts.retention.oldestUnpinnedItems.map(\.id) == Array(ids.prefix(2)))
        #expect(facts.confirmedMatch == nil)
        #expect(!facts.candidateIDExists)

        let receipt = try await history.authority.commitCapture(incoming)
        guard case .committed(let commit) = receipt,
              case .inserted(let inserted) = commit.outcome else {
            Issue.record("Expected insertion with one count-retention victim")
            return
        }
        #expect(commit.hasDestructiveRetentionEffects)
        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 100))
        #expect(page.rows.count == retainedCount)
        #expect(Set(page.rows.map(\.item.id)) == Set(ids.dropFirst()).union([inserted.id]))
        #expect(page.rows.last?.item.id == inserted.id)
    }

    @Test func belowPolicyCaptureNeedsNoRetentionRowsAndCoalescingDoesNotEvict() async throws {
        let history = try await SQLiteHistory.open(configuration: HistoryConfiguration(
            persistence: .temporary, initialMaximumUnpinnedItems: 8
        ))
        let raw = WSSupport.textCapture("same bytes", observedAt: Date(timeIntervalSinceReferenceDate: 830_000_100))
        _ = try await history.perform(.capture(raw))
        let preparation = IngestPreparationActor()
        let incoming = try await preparation.prepare(raw)
        let facts = try await history.authority.countPrefixFacts(incoming, maximumUnpinned: 8)
        #expect(facts.retention.retainedCount == 1)
        #expect(facts.retention.oldestUnpinnedItems.isEmpty)
        #expect(facts.confirmedMatch != nil)
        let receipt = try await history.perform(.capture(raw))
        guard case .committed(let commit) = receipt,
              case .coalesced = commit.outcome else {
            Issue.record("Expected the complete candidate to coalesce")
            return
        }
        #expect(!commit.hasDestructiveRetentionEffects)
        let page = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(page.rows.count == 1)
        #expect(page.rows.first?.copyCount == 2)
    }
}

private extension HistoryAuthority {
    func countPrefixFacts(
        _ prepared: PreparedCaptureBundle,
        maximumUnpinned: Int
    ) throws -> IngestFacts {
        return try IngestFactLoader.loadFacts(
            in: database,
            blobStore: blobStore,
            prepared: prepared.domain,
            retention: RetentionPolicy(maximumUnpinnedItems: maximumUnpinned),
            limits: limits
        )
    }
}
