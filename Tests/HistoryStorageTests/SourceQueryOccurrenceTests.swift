import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct SourceQueryOccurrenceTests {
    @Test(arguments: ["X'6170702E626164'", "CAST(X'6170702EFF' AS TEXT)", "'app.' || CAST(zeroblob(1021) AS TEXT)"])
    func ordinarySourceFiltersRejectTheCorruptApplicationThatSQLMatched(storedSQL: String) async throws {
        let history = try await WSSupport.makeHistory()
        _ = try await copy("needle", source: "app.valid", at: 1, in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE copy_sources SET application=" + storedSQL)
        }
        let kinds: [HistoryBrowseKind] = [.recent, .search(text: "needle", mode: .exact),
            .search(text: "needle", mode: .fuzzy), .search(text: "needle", mode: .regexp),
            .search(text: "type:all", mode: .expression)]
        for kind in kinds {
            await #expect(throws: HistoryFailure.persistence(.corruptStoredValue)) {
                try await history.browse(.init(kind: kind, limit: 1, filter: .init(sourceApplication: "app.")))
            }
        }
    }

    @Test func strictSourceFilterConfirmationNeverReadsUnusedBodies() async throws {
        let history = try await WSSupport.makeHistory()
        let item = try await copy("note", source: "app.valid", at: 1, in: history)
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET searchBodyUTF8=X'FF'")
        }
        for kind in [HistoryBrowseKind.recent, .search(text: "", mode: .fuzzy),
                     .search(text: "type:all", mode: .expression)] {
            for filter in [HistoryFilter(sourceApplication: "app."), .init(sourceApplicationIDs: ["app.valid"])] {
                let page = try await history.browse(.init(kind: kind, limit: 1, filter: filter))
                #expect(page.rows.map(\.item) == [item])
            }
        }
    }

    @Test func ordinaryFiltersAndExpressionLeavesMatchAnyPriorSourceWithCorrectNegation() async throws {
        let history = try await WSSupport.makeHistory()
        let shared = try await copy("needle shared", source: "com.Éditeur", at: 1, in: history)
        #expect(try await copy("needle shared", source: "com.e\u{301}diteur", at: 2, in: history) == shared)
        #expect(try await copy("needle shared", source: "com.example.current", at: 3, in: history) == shared)
        let other = try await copy("needle other", source: "com.example.current", at: 4, in: history)
        let unknown = try await copy("needle unknown", source: nil, at: 5, in: history)
        let kinds: [HistoryBrowseKind] = [.recent, .search(text: "needle", mode: .exact),
                                       .search(text: "needle", mode: .fuzzy), .search(text: "needle", mode: .regexp)]
        for kind in kinds {
            for filter in [HistoryFilter(sourceApplicationIDs: ["com.Éditeur"]),
                           .init(sourceApplication: "diteur"),
                           .init(sourceApplicationIDs: ["com.e\u{301}diteur"])] {
                let page = try await history.browse(.init(kind: kind, limit: 10, filter: filter))
                #expect(page.rows.map(\.item) == [shared])
                #expect(page.rows.first?.lastSource == "com.example.current")
            }
        }
        for query in ["app:éditeur", "source:ÉDITEUR", "source-id:com.Éditeur",
                      "source-id:com.e\u{301}diteur",
                      "source-id:com.Éditeur AND source-id:com.example.current"] {
            #expect(try await search(query, in: history).rows.map(\.item) == [shared])
        }
        // source-id remains byte exact despite canonically equivalent values.
        #expect(try await search("source-id:com.E\u{301}diteur", in: history).rows.isEmpty)
        #expect(try await search("NOT source-id:com.Éditeur", in: history).rows.map(\.item) == [unknown, other])
        #expect(try await search("NOT app:éditeur", in: history).rows.map(\.item) == [unknown, other])
        #expect(try await search("NOT (app:éditeur OR source-id:com.example.current)", in: history).rows.map(\.item) == [unknown])
        #expect(try await search("app:éditeur AND NOT source-id:com.example.current", in: history).rows.isEmpty)
        #expect(try await search("NOT (app:éditeur AND source-id:com.example.current)", in: history).rows.map(\.item) == [unknown, other])
    }

    @Test func oldSourcePagesKeepTheirOrderAndReadingPositionWithoutDecodingBodies() async throws {
        let history = try await WSSupport.makeHistory()
        for index in 0..<8 {
            _ = try await copy("entry \(index)", source: "app.old", at: index * 2, in: history)
            _ = try await copy("entry \(index)", source: "app.new", at: index * 2 + 1, in: history)
        }
        try await history.authority.withTestDatabase { authority in
            try authority.database.execute("UPDATE history_items SET searchBodyUTF8=X'FF'")
        }
        for sortOrder in HistorySortOrder.allCases {
            let recent = try await history.browse(.init(kind: .recent, limit: 10, sortOrder: sortOrder))
            for query in ["source-id:app.old", "app:old AND NOT app:missing"] {
                let kind = HistoryBrowseKind.search(text: query, mode: .expression)
                let first = try await history.browse(.init(kind: kind, limit: 3, sortOrder: sortOrder))
                #expect(first.rows == Array(recent.rows.prefix(3)))
                let forward = try #require(first.next)
                let second = try await history.browse(.init(kind: kind, limit: 3, cursor: forward, sortOrder: sortOrder))
                #expect(second.rows == Array(recent.rows.dropFirst(3).prefix(3)))
                let backward = try #require(second.previous)
                let restored = try await history.browse(.init(kind: kind, limit: 3, cursor: backward, sortOrder: sortOrder))
                #expect(restored.rows == first.rows)
                let target = recent.rows[4].item.id
                let located = try await history.browse(.init(kind: kind, limit: 3, sortOrder: sortOrder, startAround: target))
                #expect(located.rows == Array(recent.rows.dropFirst(4).prefix(3)))
            }
        }
    }

    private func search(_ text: String, in history: SQLiteHistory) async throws -> HistoryPage {
        try await history.browse(.init(kind: .search(text: text, mode: .expression), limit: 10))
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
