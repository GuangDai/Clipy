import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// Actual SQL effects across many rows: one commit, compact invalidation,
/// exact retained bytes, and rollback after the shared HCR append.
struct BulkRetentionTransactionTests {
    @Test(arguments: [ClearScope.all, .unpinned])
    func clearUsesOneScopeMutationAndRollsBackAsOneTransaction(scope: ClearScope) async throws {
        let url = WSSupport.tempStoreURL("bulk-clear")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        _ = try await history.seedPerformanceFixture(rowCount: 130) { Self.seedCapture($0) }
        let first = try #require(try await history.browse(.init(kind: .recent, limit: 1)).rows.first?.item)
        _ = try await history.perform(.placePinned(first.id, at: .last))
        let count = scope == .all ? 130 : 129
        let plan = try await history.authority.withTestDatabase { authority in
            planClear(scope: scope, facts: try MutationFactLoaders.loadClearFacts(scope: scope, in: authority.database))
        }
        guard case .commit(let mutationPlan) = plan else { Issue.record("Expected bulk clear plan"); return }
        #expect(mutationPlan.mutations.count == 1)
        guard case .bulkClear(let actualScope, let affected) = mutationPlan.mutations[0] else {
            Issue.record("Clear expanded a scope into per-item mutations"); return
        }
        #expect(actualScope == scope && affected == count)

        let before = try TransactionStoreSnapshot.read(from: url)
        let journalBefore = try await journalState(history)
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.clear(scope))
        }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        #expect(try await journalState(history) == journalBefore)

        let receipt = try await history.perform(.clear(scope))
        guard case .committed(let commit) = receipt, case .cleared(let removed) = commit.outcome else {
            Issue.record("Expected committed scope clear"); return
        }
        #expect(removed == count)
        #expect(commit.position.rawValue == before.positions[0].rawValue + 1)
        let usage = try await history.usage()
        #expect(usage.itemCount == (scope == .all ? 0 : 1))
        #expect(usage.pinnedItemCount == usage.itemCount)
        #expect(usage.canonicalBytes == (scope == .all ? 0 : 64))
        let journalAfter = try await journalState(history)
        #expect(journalAfter.count == journalBefore.count + 1)
        #expect(journalAfter.lastPayload.count <= 64)
    }

    @Test func countPolicyDeletesOneLargePrefixAndKeepsPins() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await history.seedPerformanceFixture(rowCount: 130) { Self.seedCapture($0) }
        let first = try #require(try await history.browse(.init(kind: .recent, limit: 1)).rows.first?.item)
        _ = try await history.perform(.placePinned(first.id, at: .last))
        let before = try await history.usage()
        let receipt = try await history.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
        guard case .committed(let commit) = receipt,
              case .retentionPolicySet(let removed) = commit.outcome else {
            Issue.record("Expected count-policy prefix retirement"); return
        }
        #expect(removed == 128)
        #expect(commit.hasDestructiveRetentionEffects)
        let after = try await history.usage()
        #expect(after.position.rawValue == before.position.rawValue + 1)
        #expect(after.itemCount == 2 && after.pinnedItemCount == 1)
        #expect(after.canonicalBytes == 128 && after.revisionBytes == 0)
        #expect(try await history.pastePayload(for: first.id).item.id == first.id)
        #expect(try await journalState(history).lastPayload.count <= 128)
    }

    @Test func sweepAcrossRevisionBatchesCountsOnlySurvivingPrunesAndRollsBackAllEffects() async throws {
        let url = WSSupport.tempStoreURL("bulk-r3-sweep")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        _ = try await history.seedPerformanceFixture(rowCount: 40) { Self.seedCapture($0) }
        let rows = try await history.browse(.init(kind: .recent, limit: 100)).rows
        for row in rows {
            for version in 1...2 {
                _ = try await history.perform(.revise(RevisionRequest(
                    itemID: row.item.id, expected: ContentVersion(rawValue: UInt64(version)),
                    intent: .replace(RevisionDraft(decisions: [RevisionDecision(
                        typeIdentifier: "public.utf8-plain-text",
                        action: .replace(bytes: Data(repeating: version == 1 ? 0x61 : 0x62, count: 16))
                    )]))
                )))
            }
        }
        // Inspect the DELETE itself: SQLite must use an indexed lookup for
        // its incoming current-content FK, including for inactive revisions
        // where there is no matching history item. A full scan here repeats
        // once per deleted content during both prune and cascading retirement.
        let foreignKeyLookups = try await history.authority.withTestDatabase { authority in
            let query = try authority.database.prepare(
                "EXPLAIN QUERY PLAN DELETE FROM contents WHERE id = ?",
                bindings: [.text(UUID().uuidString)]
            )
            defer { query.finalize() }
            var details: [String] = []
            while try query.step() {
                let detail = try query.text(at: 3)
                if detail.contains("history_items") { details.append(detail) }
            }
            return details
        }
        #expect(!foreignKeyLookups.isEmpty)
        #expect(foreignKeyLookups.allSatisfy { $0.hasPrefix("SEARCH history_items ") })
        // Every item: 64 canonical + 16 inactive + 16 active bytes. R3
        // projects 80 bytes; R2 keeps 25 items. Victims' 15 prunes are
        // subsumed by retirement, so the receipt must report only 25 prunes.
        let policies = HistoryRetentionPolicies(
            age: nil, storage: StorageRetention(maxTotalBytes: 2_000),
            revisions: RevisionRetention(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )
        let before = try TransactionStoreSnapshot.read(from: url)
        let journalBefore = try await journalState(history)
        let registration = await history.authority.registerInvalidationSubscriber()
        await history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.setRetentionPolicies(policies))
        }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        #expect(try await journalState(history) == journalBefore)
        await history.authority.unregisterInvalidationSubscriber(registration.subscription)
        var failedPublications = 0
        for try await _ in registration.stream { failedPublications += 1 }
        #expect(failedPublications == 0)

        let receipt = try await history.perform(.setRetentionPolicies(policies))
        guard case .committed(let commit) = receipt,
              case .retentionPoliciesSet(let retired, let pruned) = commit.outcome else {
            Issue.record("Expected one composed sweep commit"); return
        }
        #expect(retired == 15 && pruned == 25)
        #expect(commit.hasDestructiveRetentionEffects)
        let after = try await history.usage()
        #expect(after.itemCount == 25 && after.canonicalBytes == 1_600 && after.revisionBytes == 400)
        #expect(after.position.rawValue == before.positions[0].rawValue + 1)
        let survivors = try await history.browse(.init(kind: .recent, limit: 100)).rows
        #expect(Set(survivors.map(\.item.id)) == Set(rows.prefix(25).map(\.item.id)))
        for row in survivors {
            let details = try await history.details(for: row.item.id)
            #expect(details.revisions.count == 1)
            let payload = try await history.pastePayload(for: row.item.id)
            #expect(payload.representations.map(\.bytes) == [Data(repeating: 0x62, count: 16)])
            #expect(details.item.contentVersion.rawValue == 3)
        }
        let journalAfter = try await journalState(history)
        #expect(journalAfter.count == journalBefore.count + 1)
        #expect(journalAfter.lastPayload.count <= 64)
        let repeated = try await history.perform(.setRetentionPolicies(policies))
        guard case .unchanged = repeated else { Issue.record("Satisfied policy must be unchanged"); return }
        #expect(try await journalState(history) == journalAfter)
    }

    private struct JournalState: Equatable, Sendable {
        let count: Int64
        let lastPayload: Data
    }

    private func journalState(_ history: SQLiteHistory) async throws -> JournalState {
        try await history.authority.withTestDatabase { authority in
            let query = try authority.database.prepare("""
                SELECT (SELECT count(*) FROM history_change_records), affectedItemsBlob
                FROM history_change_records ORDER BY sequence DESC LIMIT 1
                """)
            #expect(try query.step())
            return try JournalState(count: query.integer(at: 0), lastPayload: query.blob(at: 1))
        }
    }

    private static func seedCapture(_ index: Int) -> ClipboardCapture {
        let prefix = "bulk-\(index)-"
        return WSSupport.textCapture(
            prefix + String(repeating: "x", count: 64 - prefix.utf8.count),
            observedAt: Date(timeIntervalSinceReferenceDate: 840_000_000 + Double(index))
        )
    }
}
