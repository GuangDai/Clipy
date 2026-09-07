import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// Real UNIQUE-index writes across nontrivial ranges. Expected arrays live
/// only in these bounded fixtures; production receives scalar pin facts.
struct PinnedRangeMutationTests {
    @Test(arguments: [65, 130])
    func movesBothDirectionsAndCompactsUnpinAndRemoval(pinnedCount: Int) async throws {
        let url = WSSupport.tempStoreURL("pin-ranges-\(pinnedCount)")
        defer { WSSupport.removeStore(url) }
        let fixture = try await seed(pinnedCount: pinnedCount, at: url)
        let history = fixture.history
        var expected = fixture.order
        try assertStoredOrder(expected, at: url)

        let tail = expected.removeLast()
        expected.insert(tail, at: 0)
        try await checkCommit(.placePinned(tail, at: .first), expected: expected, history: history, url: url)

        let head = expected.removeFirst()
        expected.append(head)
        try await checkCommit(.placePinned(head, at: .last), expected: expected, history: history, url: url)

        let forward = expected[pinnedCount / 4]
        let laterAnchor = expected[pinnedCount * 3 / 4]
        expected.remove(at: pinnedCount / 4)
        expected.insert(forward, at: try #require(expected.firstIndex(of: laterAnchor)))
        try await checkCommit(.placePinned(forward, at: .before(laterAnchor)), expected: expected, history: history, url: url)

        let backward = expected[pinnedCount * 3 / 4]
        let earlierAnchor = expected[pinnedCount / 4]
        expected.remove(at: pinnedCount * 3 / 4)
        expected.insert(backward, at: try #require(expected.firstIndex(of: earlierAnchor)))
        try await checkCommit(.placePinned(backward, at: .before(earlierAnchor)), expected: expected, history: history, url: url)

        try await checkNoOp(.placePinned(expected[0], at: .before(expected[1])), history: history, url: url)
        try await checkNoOp(.placePinned(expected[expected.count - 1], at: .last), history: history, url: url)
        try await checkNoOp(.unpin(fixture.unpinned), history: history, url: url)

        let insertionAnchor = expected[expected.count / 2]
        expected.insert(fixture.unpinned, at: expected.count / 2)
        try await checkCommit(.placePinned(fixture.unpinned, at: .before(insertionAnchor)), expected: expected, history: history, url: url)

        let unpinned = expected.remove(at: expected.count / 3)
        try await checkCommit(.unpin(unpinned), expected: expected, history: history, url: url)
        let removed = expected.removeFirst()
        try await checkCommit(.remove(removed), expected: expected, history: history, url: url, removed: removed)
        let usage = try await history.usage()
        #expect(usage.pinnedItemCount == pinnedCount - 1)
        #expect(usage.itemCount == pinnedCount)
        await #expect(throws: HistoryFailure.notFound(removed)) { try await history.pastePayload(for: removed) }
    }

    @Test(arguments: [InjectedTransactionFailure.finalPinOrderViolated, .beforeSingletonUpdate])
    func failedRangeMoveRestoresTargetEveryShiftedRowAndCommitMetadata(_ failure: InjectedTransactionFailure) async throws {
        let url = WSSupport.tempStoreURL("pin-range-rollback")
        defer { WSSupport.removeStore(url) }
        let fixture = try await seed(pinnedCount: 65, at: url)
        let history = fixture.history
        let target = try #require(fixture.order.last)
        let before = try TransactionStoreSnapshot.read(from: url)
        let countsBefore = try commitCounts(at: url)
        let publication = await SingleOperationInvalidationPublicationProbe.begin(on: history.authority)
        await history.authority.setTransactionFailureInjection(failure)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await history.perform(.placePinned(target, at: .first))
        }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        #expect(try commitCounts(at: url) == countsBefore)
        try assertStoredOrder(fixture.order, at: url)
        #expect(try await publication.finish(on: history.authority).isEmpty)

        let moved = [target] + Array(fixture.order.dropLast())
        try await checkCommit(.placePinned(target, at: .first), expected: moved, history: history, url: url)
    }

    @Test func failedPinnedRemovalRestoresPinCountAndAllSurvivorOrdinals() async throws {
        let url = WSSupport.tempStoreURL("pin-remove-rollback")
        defer { WSSupport.removeStore(url) }
        let fixture = try await seed(pinnedCount: 65, at: url)
        let before = try TransactionStoreSnapshot.read(from: url)
        let countsBefore = try commitCounts(at: url)
        let target = fixture.order[0]
        await fixture.history.authority.setTransactionFailureInjection(.beforeSingletonUpdate)
        await #expect(throws: HistoryFailure.persistence(.transaction)) {
            try await fixture.history.perform(.remove(target))
        }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        #expect(try commitCounts(at: url) == countsBefore)
        try assertStoredOrder(fixture.order, at: url)
        try await checkCommit(
            .remove(target), expected: Array(fixture.order.dropFirst()),
            history: fixture.history, url: url, removed: target
        )
        #expect(try await fixture.history.usage().pinnedItemCount == 64)
    }

    @Test func invalidAnchorPointReadsDoNotChangeOrderOrCommitMetadata() async throws {
        let url = WSSupport.tempStoreURL("pin-anchor-errors")
        defer { WSSupport.removeStore(url) }
        let fixture = try await seed(pinnedCount: 2, at: url)
        let target = fixture.order[0]
        let absent = HistoryItemID(rawValue: UUID())
        let before = try TransactionStoreSnapshot.read(from: url)
        let countsBefore = try commitCounts(at: url)
        await #expect(throws: HistoryFailure.invalidPinnedPlacement(.targetEqualsAnchor)) {
            try await fixture.history.perform(.placePinned(target, at: .before(target)))
        }
        await #expect(throws: HistoryFailure.invalidPinnedPlacement(.anchorMissingOrUnpinned)) {
            try await fixture.history.perform(.placePinned(target, at: .before(fixture.unpinned)))
        }
        await #expect(throws: HistoryFailure.invalidPinnedPlacement(.anchorMissingOrUnpinned)) {
            try await fixture.history.perform(.placePinned(target, at: .before(absent)))
        }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        #expect(try commitCounts(at: url) == countsBefore)
        try assertStoredOrder(fixture.order, at: url)
    }

    private func seed(pinnedCount: Int, at url: URL) async throws -> (
        history: SQLiteHistory, order: [HistoryItemID], unpinned: HistoryItemID
    ) {
        let history = try await WSSupport.openHistory(storeURL: url)
        _ = try await history.seedPerformanceFixture(rowCount: pinnedCount + 1) { index in
            WSSupport.textCapture(
                "pin range fixture \(index)",
                observedAt: Date(timeIntervalSinceReferenceDate: 850_000_000 + Double(index))
            )
        }
        let page = try await history.browse(.init(kind: .recent, limit: 200))
        let order = page.rows.prefix(pinnedCount).map(\.item.id)
        let unpinned = try #require(page.rows.last?.item.id)
        #expect(order.count == pinnedCount)
        for id in order { _ = try await history.perform(.placePinned(id, at: .last)) }
        return (history, order, unpinned)
    }

    private func checkCommit(
        _ action: HistoryAction, expected: [HistoryItemID], history: SQLiteHistory,
        url: URL, removed: HistoryItemID? = nil
    ) async throws {
        let before = try TransactionStoreSnapshot.read(from: url)
        let countsBefore = try commitCounts(at: url)
        let receipt = try await history.perform(action)
        guard case .committed(let commit) = receipt else {
            Issue.record("Expected one committed pin-range action"); return
        }
        #expect(!commit.hasDestructiveRetentionEffects)
        switch action {
        case .placePinned(let target, _):
            guard case .placedPinned(let actual) = commit.outcome else { Issue.record("Expected pin receipt"); return }
            #expect(actual == target)
        case .unpin(let target):
            guard case .unpinned(let actual) = commit.outcome else { Issue.record("Expected unpin receipt"); return }
            #expect(actual == target)
        case .remove:
            guard case .removed(count: 1) = commit.outcome else { Issue.record("Expected one removal"); return }
        default:
            Issue.record("Unsupported test action")
        }
        let countsAfter = try commitCounts(at: url)
        #expect(countsAfter.position == countsBefore.position + 1)
        #expect(commit.position.rawValue == countsAfter.position)
        #expect(countsAfter.hcr == countsBefore.hcr + 1)
        // These are internal user actions; the external Gateway suites own
        // their single succeeded audit append in the same transaction.
        #expect(countsAfter.audit == countsBefore.audit)
        try assertStoredOrder(expected, at: url)
        let after = try TransactionStoreSnapshot.read(from: url)
        let beforeItems = Dictionary(uniqueKeysWithValues: before.items.map { ($0.id, $0) })
        #expect(after.items.count == before.items.count - (removed == nil ? 0 : 1))
        for item in after.items {
            let old = try #require(beforeItems[item.id])
            #expect(item.contentVersionRaw == old.contentVersionRaw)
            #expect(item.currentContentID == old.currentContentID)
            #expect(item.canonicalContentID == old.canonicalContentID)
            #expect(item.effectiveMatchesCanonical == old.effectiveMatchesCanonical)
            #expect(item.copyCount == old.copyCount)
            #expect(item.firstCopiedAt == old.firstCopiedAt && item.lastCopiedAt == old.lastCopiedAt)
            #expect(item.canonicalBytes == old.canonicalBytes && item.revisionBytes == old.revisionBytes)
        }
        if let removed {
            #expect(after.contents == before.contents.filter { $0[1] != .text(removed.rawValue.uuidString) })
            let survivingContents = Set(after.contents.compactMap { row -> String? in
                if case .text(let id) = row[0] { return id }; return nil
            })
            #expect(after.representations == before.representations.filter { row in
                if case .text(let id) = row[0] { return survivingContents.contains(id) }; return false
            })
        } else {
            #expect(after.contents == before.contents)
            #expect(after.representations == before.representations)
        }
    }

    private func checkNoOp(_ action: HistoryAction, history: SQLiteHistory, url: URL) async throws {
        let before = try TransactionStoreSnapshot.read(from: url)
        let counts = try commitCounts(at: url)
        let receipt = try await history.perform(action)
        guard case .unchanged = receipt else { Issue.record("Expected exact no-change placement"); return }
        #expect(try TransactionStoreSnapshot.read(from: url) == before)
        #expect(try commitCounts(at: url) == counts)
    }

    private func assertStoredOrder(_ expected: [HistoryItemID], at url: URL) throws {
        let database = try SQLiteDatabase(url: url, readOnly: true)
        try database.readTransaction {
            let rows = try database.prepare("SELECT id,pinOrdinal FROM history_items WHERE pinOrdinal IS NOT NULL ORDER BY pinOrdinal")
            var actual: [HistoryItemID] = []
            while try rows.step() {
                #expect(try rows.integer(at: 1) == Int64(actual.count))
                actual.append(HistoryItemID(rawValue: try #require(UUID(uuidString: rows.text(at: 0)))))
            }
            #expect(actual == expected)
            let counts = try database.prepare("""
                SELECT count(*),count(DISTINCT pinOrdinal),min(pinOrdinal),max(pinOrdinal),
                    (SELECT pinnedItemCount FROM history_state WHERE key='retained-history')
                FROM history_items WHERE pinOrdinal IS NOT NULL
                """)
            #expect(try counts.step())
            #expect(try counts.integer(at: 0) == Int64(expected.count))
            #expect(try counts.integer(at: 1) == Int64(expected.count))
            #expect(try counts.integer(at: 4) == Int64(expected.count))
            if expected.isEmpty {
                #expect(try counts.isNull(at: 2) && counts.isNull(at: 3))
            } else {
                #expect(try counts.integer(at: 2) == 0)
                #expect(try counts.integer(at: 3) == Int64(expected.count - 1))
            }
        }
    }

    private struct CommitCounts: Equatable {
        let position: UInt64
        let hcr: Int64
        let audit: Int64
    }

    private func commitCounts(at url: URL) throws -> CommitCounts {
        let database = try SQLiteDatabase(url: url, readOnly: true)
        let query = try database.prepare("""
            SELECT changePosition, (SELECT count(*) FROM history_change_records),
                   (SELECT count(*) FROM operation_records)
            FROM history_state WHERE key='retained-history'
            """)
        #expect(try query.step())
        return try CommitCounts(position: sqliteUInt64(query.blob(at: 0)), hcr: query.integer(at: 1), audit: query.integer(at: 2))
    }
}
