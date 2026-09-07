/// Read-after-commit and stable SQLite read-transaction visibility (04 §3).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct FreshContextVisibilityProofTests {
    @Test @MainActor
    func independentReadTransactionStaysStableThenSeesTheNextCommit() async throws {
        let url = WSSupport.tempStoreURL("sqlite-reader-visibility")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        _ = try await history.perform(.capture(WSSupport.textCapture("visible value", observedAt: Date(timeIntervalSinceReferenceDate: 10))))
        let reader = try SQLiteDatabase(url: url)
        try reader.execute("BEGIN DEFERRED")
        let before = try Self.read(reader)
        #expect(before.position == 1 && before.copyCount == 1)
        _ = try await history.perform(.capture(WSSupport.textCapture("visible value", observedAt: Date(timeIntervalSinceReferenceDate: 20))))
        #expect(try Self.read(reader) == before)
        try reader.execute("COMMIT")
        let after = try reader.readTransaction { try Self.read(reader) }
        #expect(after.position == 2 && after.copyCount == 2)
        #expect(after.title == Data("visible value".utf8))
        #expect(after.lastCopiedAt == 20)
        let freshReader = try SQLiteDatabase(url: url)
        #expect(try freshReader.readTransaction { try Self.read(freshReader) } == after)
    }

    @Test func authorityReadsSeeCommittedPositionAndRowsImmediately() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        for (index, text) in ["first", "second"].enumerated() {
            let receipt = try await history.perform(.capture(WSSupport.textCapture(text, observedAt: Date(timeIntervalSinceReferenceDate: Double(index)))))
            guard case let .committed(commit) = receipt else { Issue.record("expected a committed capture"); return }
            let position = try await history.authority.currentPosition()
            #expect(position == commit.position)
            let page = try await history.browse(.init(kind: .recent, limit: 10))
            #expect(page.position == commit.position)
            #expect(page.rows.count == index + 1)
            #expect(page.rows.first?.title == text)
        }
    }

    private struct Read: Equatable {
        let position: UInt64
        let copyCount: UInt64
        let title: Data
        let lastCopiedAt: Double
    }
    private static func read(_ database: SQLiteDatabase) throws -> Read {
        let statement = try database.prepare("""
            SELECT s.changePosition, i.copyCount, i.titleUTF8, i.lastCopiedAt
            FROM history_state s CROSS JOIN history_items i WHERE s.key = 'retained-history'
            """)
        defer { statement.finalize() }
        try #require(try statement.step())
        return try Read(position: sqliteUInt64(statement.blob(at: 0)), copyCount: sqliteUInt64(statement.blob(at: 1)),
                        title: statement.blob(at: 2), lastCopiedAt: statement.real(at: 3))
    }
}
