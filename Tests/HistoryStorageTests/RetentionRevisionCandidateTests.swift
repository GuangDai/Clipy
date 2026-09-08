import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// R3 reads its narrow revision-candidate index, while receipts and effects
/// still come from the same real Authority transaction (V2-09 §4/§6).
struct RetentionRevisionCandidateTests {
    @Test(arguments: [0, 1])
    func policyWithoutPruneWorkUsesCoveringCandidatesAndCommitsOnlyConfiguration(revisions: Int) async throws {
        let history = try await makeHistory(count: 65)
        let target = try #require(try await history.browse(.init(kind: .recent, limit: 1)).rows.first?.item.id)
        if revisions > 0 { try await revise(target, version: 1, in: history) }
        let before = try await history.usage()
        let plan = try await history.authority.withTestDatabase { authority in
            let query = try authority.database.prepare("""
                EXPLAIN QUERY PLAN SELECT id FROM history_items
                WHERE id > ? AND (revisionCount > 0 OR revisionBytes > 0)
                    AND (revisionCount > ? OR revisionBytes > ?)
                ORDER BY id LIMIT 32
                """, bindings: [.text(""), .integer(1), .integer(1)])
            defer { query.finalize() }
            var steps: [String] = []
            while try query.step() { steps.append(try query.text(at: 3)) }
            return steps
        }
        #expect(plan.contains { $0.contains("SEARCH history_items USING COVERING INDEX") })
        #expect(!plan.contains { $0.contains("TEMP B-TREE") || $0.hasPrefix("SCAN history_items") })
        let policies = HistoryRetentionPolicies(age: nil, storage: nil, revisions: .init(
            maxRevisionsPerItem: 1, maxRevisionBytesPerItem: 1
        ))
        let receipt = try await history.perform(.setRetentionPolicies(policies))
        guard case .committed(let commit) = receipt,
              case .retentionPoliciesSet(let retired, let pruned) = commit.outcome else {
            Issue.record("A new satisfied R3 policy still requires its configuration commit")
            return
        }
        #expect(retired == 0 && pruned == 0 && !commit.hasDestructiveRetentionEffects)
        let after = try await history.usage()
        #expect(after.itemCount == before.itemCount && after.revisionBytes == before.revisionBytes)
        #expect(after.canonicalBytes == before.canonicalBytes)
        #expect(after.position.rawValue == before.position.rawValue + 1)
        let repeated = try await history.perform(.setRetentionPolicies(policies))
        guard case .unchanged = repeated else {
            Issue.record("Reapplying the satisfied policy must not commit")
            return
        }
        #expect(try await history.usage().position == after.position)
    }

    @Test func candidateKeysetPrunesAcrossThreeBatchesAndKeepsUnrevisedItems() async throws {
        let history = try await makeHistory(count: 97)
        let rows = try await history.browse(.init(kind: .recent, limit: 100)).rows
        let targets = Array(rows.prefix(65))
        for target in targets {
            try await revise(target.item.id, version: 1, in: history)
            try await revise(target.item.id, version: 2, in: history)
        }
        let pinned = try #require(targets.first?.item.id)
        _ = try await history.perform(.placePinned(pinned, at: .last))
        let before = try await history.usage()
        let receipt = try await history.perform(.setRetentionPolicies(.init(
            age: nil, storage: nil, revisions: .init(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
        guard case .committed(let commit) = receipt,
              case .retentionPoliciesSet(let retired, let pruned) = commit.outcome else {
            Issue.record("Expected one complete multi-batch R3 commit")
            return
        }
        #expect(retired == 0 && pruned == 65)
        #expect(commit.position.rawValue == before.position.rawValue + 1)
        let after = try await history.usage()
        #expect(after.itemCount == 97 && after.pinnedItemCount == 1)
        #expect(after.canonicalBytes == before.canonicalBytes && after.revisionBytes == 65)
        for target in targets {
            let details = try await history.details(for: target.item.id)
            #expect(details.revisions.count == 1 && details.item.contentVersion.rawValue == 3)
            #expect(try await history.pastePayload(for: target.item.id).representations.first?.bytes == Data([0x62]))
        }
        let untouched = try #require(rows.last?.item.id)
        #expect(try await history.details(for: untouched).revisions.isEmpty)
    }

    @Test(arguments: [false, true])
    func emptyRevisionIndexDoesNotSkipAgeOrStorageRetirement(age: Bool) async throws {
        let history = try await makeHistory(count: 65)
        let newest = try #require(try await history.browse(.init(kind: .recent, limit: 1)).rows.first?.item.id)
        let receipt = try await history.perform(.setRetentionPolicies(.init(
            age: age ? .init(maxAge: 1) : nil,
            storage: age ? nil : .init(maxTotalBytes: 64),
            revisions: .init(maxRevisionsPerItem: 1, maxRevisionBytesPerItem: nil)
        )))
        guard case .committed(let commit) = receipt,
              case .retentionPoliciesSet(let retired, let pruned) = commit.outcome else {
            Issue.record("R1/R2 must still run when R3 has no candidates")
            return
        }
        #expect(retired == (age ? 65 : 64) && pruned == 0)
        let rows = try await history.browse(.init(kind: .recent, limit: 2)).rows
        #expect(rows.map(\.item.id) == (age ? [] : [newest]))
    }

    @Test func byteOnlyCorruptRevisionScalarStillReachesValidation() async throws {
        let history = try await makeHistory(count: 1)
        let before = try await history.usage()
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET revisionBytes = 9")
            try authority.database.execute("UPDATE history_state SET revisionBytes = 9")
        }
        await #expect(throws: HistoryFailure.persistence(.invariantViolation)) {
            try await history.perform(.setRetentionPolicies(.init(
                age: nil, storage: nil,
                revisions: .init(maxRevisionsPerItem: nil, maxRevisionBytesPerItem: 1)
            )))
        }
        #expect(try await history.usage().position == before.position)
        #expect(try await history.retentionConfiguration().policies.revisions == nil)
    }

    private func makeHistory(count: Int) async throws -> SQLiteHistory {
        let history = try await WSSupport.makeHistory()
        _ = try await history.seedPerformanceFixture(rowCount: count) { index in
            let prefix = "revision-candidate-\(index)-"
            return WSSupport.textCapture(
                prefix + String(repeating: "x", count: 64 - prefix.utf8.count),
                observedAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
        return history
    }

    private func revise(_ id: HistoryItemID, version: UInt64, in history: SQLiteHistory) async throws {
        _ = try await history.perform(.revise(.init(
            itemID: id, expected: .init(rawValue: version),
            intent: .replace(.init(decisions: [.init(
                typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data([version == 1 ? 0x61 : 0x62]))
            )]))
        )))
    }
}
