import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SourceApplicationReadTests {
    @Test func vocabularyIncludesOldCopiesAndRemoteItemsAcrossBoundedDistinctPages() async throws {
        let history = try await WSSupport.makeHistory()
        let old = try await copy("old note", source: "app.retired", at: 0, in: history)
        #expect(try await copy("old note", source: "app.current", at: 1, in: history) == old)
        for index in 0..<70 {
            _ = try await copy("new note \(index)", source: "app.shared", at: index + 10, in: history)
        }
        let recent = try await history.browse(.init(kind: .recent, limit: 32))
        #expect(!recent.rows.contains { $0.item.id == old.id })
        for index in 0..<40 {
            _ = try await copy("many-source note", source: String(format: "app.%02d", index), at: 100 + index, in: history)
        }
        _ = try await copy("many-source note", source: nil, at: 141, in: history)
        _ = try await copy("many-source note", source: "", at: 142, in: history)
        let first = try await history.sourceApplications(.init())
        #expect(first.applications.count == 32)
        let next = try #require(first.next)
        let second = try await history.sourceApplications(.init(cursor: next))
        #expect(second.position == first.position)
        #expect(second.applications.count == 11)
        #expect(second.next == nil)
        let expected = (0..<40).map { String(format: "app.%02d", $0) } + ["app.current", "app.retired", "app.shared"]
        #expect(first.applications + second.applications == expected)
        #expect(first.applications.allSatisfy { !$0.isEmpty })
    }

    @Test func removingAnItemWithdrawsOnlySourcesNoLongerRetainedAndExpiresPages() async throws {
        let history = try await WSSupport.makeHistory()
        let first = try await copy("first", source: "app.a", at: 1, in: history)
        _ = try await copy("first", source: "app.shared", at: 2, in: history)
        _ = try await copy("second", source: "app.b", at: 3, in: history)
        _ = try await copy("second", source: "app.shared", at: 4, in: history)
        let page = try await history.sourceApplications(.init(limit: 1))
        let next = try #require(page.next)
        _ = try await history.perform(.remove(first.id))
        let changed = try await history.sourceApplications(.init())
        #expect(changed.applications == ["app.b", "app.shared"])
        await #expect(throws: HistoryFailure.snapshotExpired(current: changed.position)) {
            try await history.sourceApplications(.init(limit: 1, cursor: next))
        }
        _ = try await history.perform(.clear(.all))
        let empty = try await history.sourceApplications(.init())
        #expect(empty.applications.isEmpty && empty.next == nil)
    }

    @Test func anExistingStoreGainsTheOptimizerIndexAndReopenExpiresOldCursors() async throws {
        let url = WSSupport.tempStoreURL("source-vocabulary-index")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        _ = try await copy("one", source: "app.a", at: 1, in: history)
        _ = try await copy("two", source: "app.b", at: 2, in: history)
        let first = try await history.sourceApplications(.init(limit: 1))
        let next = try #require(first.next)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("DROP INDEX copy_sources_application")
        }
        let reopened = try await WSSupport.openHistory(storeURL: url)
        #expect(try await reopened.sourceApplications(.init()).applications == ["app.a", "app.b"])
        try await reopened.authority.withTestDatabase { authority in
            let query = try authority.database.prepare("SELECT name FROM pragma_index_info('copy_sources_application') ORDER BY seqno")
            defer { query.finalize() }
            try #require(try query.step())
            #expect(try query.text(at: 0) == "application")
            try #require(try query.step())
            #expect(try query.text(at: 0) == "itemID")
        }
        await #expect(throws: HistoryFailure.snapshotExpired(current: first.position)) {
            try await reopened.sourceApplications(.init(limit: 1, cursor: next))
        }
    }

    @Test func vocabularyReadsNoTitleBodyOrPayloadAndRetainsLiteralSourceBytes() async throws {
        let history = try await WSSupport.makeHistory()
        let source = "com.前\0后.e\u{301}"
        _ = try await copy("note", source: source, at: 1, in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET titleUTF8=X'FF',searchBodyUTF8=X'FF'")
        }
        let page = try await history.sourceApplications(.init())
        try #require(page.applications.count == 1)
        #expect(Data(page.applications[0].utf8) == Data(source.utf8))
    }

    @Test func canonicallyEquivalentSourceIdentifiersKeepDistinctKeysetBoundaries() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await copy("first", source: "app.e\u{301}", at: 1, in: history)
        _ = try await copy("second", source: "app.é", at: 2, in: history)
        _ = try await copy("third", source: "zzz", at: 3, in: history)
        let first = try await history.sourceApplications(.init(limit: 1))
        let firstNext = try #require(first.next)
        let second = try await history.sourceApplications(.init(limit: 1, cursor: firstNext))
        let secondNext = try #require(second.next)
        #expect(firstNext != secondNext)
        let third = try await history.sourceApplications(.init(limit: 1, cursor: secondNext))
        #expect((first.applications + second.applications + third.applications).map { Data($0.utf8) }
                == [Data("app.e\u{301}".utf8), Data("app.é".utf8), Data("zzz".utf8)])
        #expect(third.next == nil)
    }

    @Test(arguments: ["CAST(X'FF' AS TEXT)", "X'FF'", "CAST(zeroblob(1025) AS TEXT)"])
    func corruptSourceValuesFailClosed(storedSQL: String) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await copy("note", source: "app.valid", at: 1, in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE copy_sources SET application=" + storedSQL)
        }
        await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
            try await history.sourceApplications(.init())
        }
    }

    @Test func invalidLimitsAndCancellationDoNotRetainTheReadSnapshot() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await copy("note", source: "app.valid", at: 1, in: history)
        for limit in [-1, 0, 33] {
            await #expect(throws: HistoryFailure.invalidInput(.invalidPageLimit)) {
                try await history.sourceApplications(.init(limit: limit))
            }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await history.sourceApplications(.init())
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await history.sourceApplications(.init()).applications == ["app.valid"])
    }

    private func copy(_ text: String, source: String?, at time: Int, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: Double(time)), source: source
        )))
        guard case .committed(let commit) = receipt else { throw HistoryFailure.persistence(.invariantViolation) }
        switch commit.outcome {
        case .inserted(let item), .coalesced(let item): return item
        default: throw HistoryFailure.persistence(.invariantViolation)
        }
    }
}
