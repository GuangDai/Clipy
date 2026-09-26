#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct HistoryFilterValidationTests {
    @Test(arguments: [HistoryBrowseKind.recent, .search(text: "", mode: .exact),
                      .search(text: "needle", mode: .exact),
                      .search(text: "needle", mode: .fuzzy),
                      .search(text: "needle", mode: .regexp)])
    func invalidMetadataIsRejectedAtEveryBrowseEntry(kind: HistoryBrowseKind) async throws {
        let history = try await WSSupport.makeHistory()
        for filter in [HistoryFilter(copiedAfter: Date(timeIntervalSinceReferenceDate: .infinity)),
                       HistoryFilter(copiedBefore: Date(timeIntervalSinceReferenceDate: .nan))] {
            await #expect(throws: HistoryFailure.invalidInput(.invalidTimestamp)) {
                try await history.browse(.init(kind: kind, limit: 10, filter: filter))
            }
        }
        let tooLong = String(repeating: "é", count: 513)
        await #expect(throws: HistoryFailure.invalidInput(.invalidSearchTerm)) {
            try await history.browse(.init(kind: kind, limit: 10,
                                           filter: .init(sourceApplication: tooLong)))
        }
        for sourceIDs in [Array(repeating: "com.example", count: 65), [tooLong],
                          Array(repeating: String(repeating: "x", count: 1_024), count: 5)] {
            await #expect(throws: HistoryFailure.invalidInput(.invalidSearchTerm)) {
                try await history.browse(.init(kind: kind, limit: 10,
                                               filter: .init(sourceApplicationIDs: sourceIDs)))
            }
        }
    }

    @Test func metadataSQLAndMatcherAgreeOnLiteralSourcesAndDateBoundaries() throws {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("CREATE TABLE history_items (lastSource TEXT, lastCopiedAt REAL, pinOrdinal INTEGER)")
        let cases: [(source: String?, filter: HistoryFilter, matches: Bool)] = [
            ("com.Example.Editor", .init(sourceApplication: "EXAMPLE"), true),
            ("com.example.Editor", .init(sourceApplication: "%"), false),
            ("com.example.Editor", .init(sourceApplication: "_"), false),
            ("com.example.50%", .init(sourceApplication: "50%"), true),
            ("com.example.my_app", .init(sourceApplication: "my_app"), true),
            ("com.Éditeur", .init(sourceApplication: "éditeur"), false),
            ("com.e\u{301}diteur", .init(sourceApplication: "éditeur"), false),
            (nil, .init(sourceApplication: "example"), false),
            (nil, .init(sourceApplication: ""), true),
            ("com.example.Editor", .init(sourceApplicationIDs: ["com.example.Editor", "other"]), true),
            ("com.example.Editor", .init(sourceApplicationIDs: ["com.example.editor"]), false),
            ("com.example.Editor", .init(sourceApplicationIDs: []), false),
            (nil, .init(sourceApplicationIDs: []), false),
            ("com.example.Editor", .init(sourceApplication: "other",
                                         sourceApplicationIDs: ["com.example.Editor"]), false),
            (nil, .init(copiedAfter: Date(timeIntervalSinceReferenceDate: 100)), true),
            (nil, .init(copiedBefore: Date(timeIntervalSinceReferenceDate: 100)), false),
            (nil, .init(copiedAfter: Date(timeIntervalSinceReferenceDate: 101),
                        copiedBefore: Date(timeIntervalSinceReferenceDate: 99)), false),
        ]
        for testCase in cases {
            try database.execute("DELETE FROM history_items")
            try database.execute(
                "INSERT INTO history_items VALUES (?, 100, NULL)",
                bindings: [testCase.source.map(SQLiteValue.text) ?? .null]
            )
            let predicate = HistoryFilterSQL.predicate(testCase.filter)
            let result = try database.prepare(
                "SELECT count(*) FROM history_items WHERE \(predicate.sql)", bindings: predicate.bindings
            )
            #expect(try result.step())
            #expect((try result.integer(at: 0) == 1) == testCase.matches)
            let row = SearchCorpusRow(
                id: HistoryItemID(rawValue: UUID()), contentVersion: .initial,
                title: "", searchBody: "", debugTitleUTF8Bytes: 0, debugSearchBodyUTF8Bytes: 0,
                typeIdentifiers: [], lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
                copyCount: 1, lastSource: testCase.source, pinOrdinal: nil
            )
            #expect(HistoryFilterSQL.admits(row, filter: testCase.filter) == testCase.matches)
        }
    }

    @Test func cursorShapeKeepsLiteralSourceIdentityAndRoundTripsTheMaximumSourceSize() throws {
        let composed = HistoryFilter(sourceApplication: "com.éditeur")
        let decomposed = HistoryFilter(sourceApplication: "com.e\u{301}diteur")
        #expect(composed != decomposed)
        #expect(!StoredQueryShape.recent(limit: 10, filter: composed).matches(
            .init(kind: .recent, limit: 10, filter: decomposed)
        ))
        let filter = HistoryFilter(
            sourceApplication: String(repeating: "\u{0001}", count: 1_024),
            sourceApplicationIDs: Array(repeating: String(repeating: "\u{0003}", count: 1_024), count: 4),
            copiedAfter: Date(timeIntervalSinceReferenceDate: 100),
            copiedBefore: Date(timeIntervalSinceReferenceDate: 200)
        )
        let shape = StoredQueryShape.search(
            text: String(repeating: "\u{0002}", count: 4_096), mode: .exact, limit: 10, filter: filter
        )
        let resolved = ResolvedPageCursor(
            queryShape: shape, position: ChangePosition(rawValue: 1),
            anchor: .defaultOrder(pinnedOrdinal: nil, lastCopiedAt: Date(timeIntervalSinceReferenceDate: 150),
                                  id: HistoryItemID(rawValue: UUID()))
        )
        let marker = UUID()
        let cursor = try PageCursorCodec.encode(resolved, processMarker: marker)
        #expect(try PageCursorCodec.decode(cursor, processMarker: marker) == resolved)
    }
}
#endif
