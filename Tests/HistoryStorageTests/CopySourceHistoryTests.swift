import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct CopySourceHistoryTests {
    @Test func repeatedAndCrossApplicationCopiesKeepOneItemAndIndependentSourceTimes() async throws {
        let url = WSSupport.tempStoreURL("copy-sources")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        let item = try await copy("note", source: "com.example.editor", at: 10, in: history)
        #expect(try await copy("note", source: "com.example.editor", at: 20, in: history) == item)
        _ = try await copy("other", source: "com.example.editor", at: 21, in: history)
        #expect(try await copy("note", source: "com.example.browser", at: 30, in: history) == item)
        // Out-of-order observations count, but cannot regress either source's recency.
        #expect(try await copy("note", source: "com.example.editor", at: 15, in: history) == item)

        let reopened = try await WSSupport.openHistory(storeURL: url)
        let page = try await reopened.browse(.init(kind: .recent, limit: 10))
        #expect(page.rows.count == 2)
        let row = try #require(page.rows.first)
        #expect(row.item == item)
        #expect(row.copyCount == 4)
        #expect(row.sourceCount == 2)
        #expect(row.lastSource == "com.example.browser")
        let details = try await reopened.details(for: item.id)
        let sources = try await reopened.copySources(for: item.id, expectedCopyCount: 4, offset: 0)
        #expect(sources.sources.map(\.application) == ["com.example.browser", "com.example.editor"])
        #expect(sources.sources.map(\.count) == [1, 3])
        #expect(sources.sources.map(\.firstCopiedAt) == [date(30), date(10)])
        #expect(sources.sources.map(\.lastCopiedAt) == [date(30), date(20)])
        #expect(details.revisions.isEmpty)
        #expect(details.item == item)
        for mode in [SearchMode.exact, .fuzzy, .regexp] {
            let search = try await reopened.browse(.init(kind: .search(text: "note", mode: mode), limit: 10))
            #expect(search.rows.first?.sourceCount == 2)
        }
    }

    @Test func unknownSourceIsDistinctFromEmptyAndRemovingTheItemRemovesItsSources() async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await copy("note", source: nil, at: 1, in: history)
        #expect(try await copy("note", source: "", at: 2, in: history) == item)
        #expect(try await copy("note", source: nil, at: 3, in: history) == item)
        let sources = try await history.copySources(for: item.id, expectedCopyCount: 3, offset: 0)
        #expect(sources.sources.map(\.application) == [nil, ""])
        #expect(sources.sources.map(\.count) == [2, 1])
        _ = try await history.perform(.remove(item.id))
        try await history.authority.withTestDatabase { authority in
            let query = try authority.database.prepare("SELECT count(*) FROM copy_sources")
            defer { query.finalize() }
            try #require(try query.step())
            #expect(try query.integer(at: 0) == 0)
        }
    }

    @Test func sourceCountOverflowRollsBackTheWholeCapture() async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await copy("note", source: "com.example.editor", at: 1, in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE copy_sources SET copyCount=?",
                bindings: [.blob(sqliteUInt64(UInt64.max))])
        }
        let before = try await history.browse(.init(kind: .recent, limit: 10))
        await #expect(throws: HistoryFailure.capacityExceeded(.copyCount)) {
            try await copy("note", source: "com.example.editor", at: 2, in: history)
        }
        #expect(try await history.browse(.init(kind: .recent, limit: 10)) == before)
    }

    @Test func sourcePagesAreBoundedAndNewCopiesExpireTheirOrdering() async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await copy("note", source: "app.0", at: 0, in: history)
        for index in 1..<35 {
            #expect(try await copy("note", source: "app.\(index)", at: index, in: history) == item)
        }
        let first = try await history.copySources(for: item.id, expectedCopyCount: 35, offset: 0)
        let second = try await history.copySources(for: item.id, expectedCopyCount: 35, offset: 32)
        #expect(first.sources.count == 32)
        #expect(first.nextOffset == 32)
        #expect(second.sources.count == 3)
        #expect(second.nextOffset == nil)
        #expect((first.sources + second.sources).map(\.application)
                == (0..<35).reversed().map { Optional("app.\($0)") })
        _ = try await copy("note", source: "app.0", at: 40, in: history)
        let latest = try await history.browse(.init(kind: .recent, limit: 1))
        await #expect(throws: HistoryFailure.snapshotExpired(current: latest.position)) {
            try await history.copySources(for: item.id, expectedCopyCount: 35, offset: 32)
        }
        let replacement = try await history.copySources(for: item.id, expectedCopyCount: 36, offset: 0)
        #expect(replacement.sources.first?.application == "app.0")
        #expect(replacement.sources.first?.count == 2)
        await #expect(throws: HistoryFailure.invalidInput(.invalidPageLimit)) {
            try await history.copySources(for: item.id, expectedCopyCount: 36, offset: -1)
        }
    }

    private func date(_ offset: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: 700_200_000 + Double(offset))
    }

    private func copy(_ text: String, source: String?, at offset: Int, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(text, observedAt: date(offset), source: source)))
        guard case .committed(let commit) = receipt else { throw HistoryFailure.persistence(.invariantViolation) }
        switch commit.outcome {
        case .inserted(let item), .coalesced(let item): return item
        default: throw HistoryFailure.persistence(.invariantViolation)
        }
    }
}
