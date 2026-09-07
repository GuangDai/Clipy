/// The current SQLite schema stores literal projections, content and position
/// through the real public capture path; old model-table stores are rejected.
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SchemaSmokeTests {
    @Test func currentStorePersistsLiteralContentAndPosition() async throws {
        let url = WSSupport.tempStoreURL("sqlite-schema-smoke")
        defer { WSSupport.removeStore(url) }
        let history = try await WSSupport.openHistory(storeURL: url)
        let bytes = Data("\u{FEFF}hello\u{0}".utf8)
        _ = try await history.perform(.capture(.init(representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: bytes)],
            origin: .init(sourceApplication: "com.example.first", lineageHint: nil), observedAt: Date(timeIntervalSinceReferenceDate: 10))))
        let page = try await history.browse(.init(kind: .recent, limit: 1))
        let title = try #require(page.rows.first?.title)
        let reader = try SQLiteDatabase(url: url)
        let statement = try reader.prepare("""
            SELECT i.titleUTF8, i.copyCount, i.contentVersion, r.inlineBytes, s.changePosition
            FROM history_items i JOIN representations r ON r.contentID = i.currentContentID
            CROSS JOIN history_state s WHERE s.key = 'retained-history'
            """)
        defer { statement.finalize() }
        try #require(statement.step())
        #expect(try statement.blob(at: 0) == Data(title.utf8))
        #expect(try sqliteUInt64(statement.blob(at: 1)) == 1)
        #expect(try sqliteUInt64(statement.blob(at: 2)) == 1)
        #expect(try statement.blob(at: 3) == bytes)
        #expect(try sqliteUInt64(statement.blob(at: 4)) == 1)
        #expect(try !statement.step())
        let table = try reader.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'representations'")
        defer { table.finalize() }
        #expect(try table.step())
    }

    @Test func previousModelStoreIsRejectedWithoutDeletingOrRecreatingIt() async throws {
        let url = WSSupport.tempStoreURL("sqlite-reject-previous-store")
        defer { WSSupport.removeStore(url) }
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("CREATE TABLE Z_METADATA (payload BLOB)")
            try database.execute("INSERT INTO Z_METADATA VALUES (?)", bindings: [.blob(Data([0x01, 0x02]))])
        }
        await #expect(throws: HistoryFailure.persistence(.openStore)) {
            try await WSSupport.openHistory(storeURL: url)
        }
        let reader = try SQLiteDatabase(url: url)
        let original = try reader.prepare("SELECT payload FROM Z_METADATA")
        defer { original.finalize() }
        try #require(original.step())
        #expect(try original.blob(at: 0) == Data([0x01, 0x02]))
        let current = try reader.prepare("SELECT count(*) FROM sqlite_master WHERE name = 'history_items'")
        defer { current.finalize() }
        try #require(current.step())
        #expect(try current.integer(at: 0) == 0)
    }
}
