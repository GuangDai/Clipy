#if DEBUG
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

/// SQL pruning must keep every expression match. Metadata can reduce the
/// candidate batch, but text and Unicode matching still belong to the worker.
struct ExpressionMetadataSQLTests {
    @Test func exactMetadataPredicatesIncludeUnknownSourcesUnderNot() throws {
        let (database, rows) = try fixture()
        let cases: [(HistorySearchExpression.Node, [Int])] = [
            (.and(.copiedDate(from: date(100), until: date(200)), .sourceID("com.example.Editor")), [1]),
            (.not(.sourceID("com.example.Editor")), [0, 3, 4]),
            (.or(.sourceID("com.example.Editor"), .sourceID("com.example.Journal")), [1, 2, 3]),
            (.sourceID("COM.EXAMPLE.EDITOR"), []),
            (.sourceID("com.e\u{301}diteur"), []),
            (.not(.or(.sourceID("com.example.Editor"), .sourceID("com.example.Journal"))), [0, 4]),
            (.not(.copiedDate(from: date(100), until: date(200))), [0, 2]),
            (.and(.pinned, .not(.type(.images))), [3]),
            (.or(.type(.links), .type(.text)), [0, 1, 3]),
            (.not(.type(.images)), [0, 1, 3, 4]),
            (.not(.noMatch), [0, 1, 2, 3, 4]),
            (.not(.all), []),
        ]
        for (node, expected) in cases {
            let selected = try selectedIndices(node, in: database)
            #expect(selected == expected)
            let matcher = PreparedSearchExpression(node)
            #expect(rows.indices.filter { matcher.match(rows[$0]).matches } == expected)
        }
    }

    @Test func inexactBranchesAreNeverNegatedOrUsedToExcludeOrMatches() throws {
        let (database, rows) = try fixture()
        let all = Array(rows.indices)
        let cases: [(HistorySearchExpression.Node, [Int])] = [
            (.and(.text("needle"), .sourceID("com.example.Editor")), [1, 2]),
            (.or(.text("needle"), .sourceID("com.example.Editor")), all),
            (.not(.text("needle")), all),
            (.not(.and(.text("needle"), .sourceID("com.example.Editor"))), all),
            (.not(.or(.text("needle"), .sourceID("com.example.Editor"))), all),
            (.and(.not(.text("needle")), .pinned), [2, 3]),
            (.application("éditeur"), all),
            (.not(.application("éditeur")), all),
            (.or(.application("éditeur"), .sourceID("com.example.Journal")), all),
            (.and(.application("éditeur"), .copiedDate(from: date(100), until: date(200))), [1, 3, 4]),
        ]
        for (node, expectedCandidates) in cases {
            let selected = try selectedIndices(node, in: database)
            #expect(selected == expectedCandidates)
            let matcher = PreparedSearchExpression(node)
            let matches = rows.indices.filter { matcher.match(rows[$0]).matches }
            #expect(Set(matches).isSubset(of: Set(selected)))
        }
    }

    @Test func maximumAdjacentMetadataTermsPrepareWithoutDeepSQLParentheses() throws {
        let (database, rows) = try fixture()
        let text = Array(repeating: "type:all", count: 128).joined(separator: " ")
        let expression = try HistorySearchExpression.parse(text)
        #expect(try selectedIndices(expression.root, in: database) == Array(rows.indices))
    }

    private func selectedIndices(
        _ node: HistorySearchExpression.Node, in database: SQLiteDatabase
    ) throws -> [Int] {
        let predicate = HistoryFilterSQL.expressionPredicate(node)
        let statement = try database.prepare(
            "SELECT id FROM history_items WHERE \(predicate.sql) ORDER BY id", bindings: predicate.bindings
        )
        var result: [Int] = []
        while try statement.step() { result.append(Int(try statement.integer(at: 0))) }
        return result
    }

    private func fixture() throws -> (SQLiteDatabase, [SearchCorpusRow]) {
        let database = try SQLiteDatabase(url: nil)
        try database.execute("""
            CREATE TABLE history_items (
                id INTEGER, lastSource TEXT, lastCopiedAt REAL NOT NULL,
                pinOrdinal INTEGER, currentContentID INTEGER
            )
            """)
        try database.execute("CREATE TABLE representations (contentID INTEGER, typeKey TEXT)")
        let values: [(String?, Double, Int?, [String])] = [
            (nil, 99, nil, ["public.utf8-plain-text"]),
            ("com.example.Editor", 100, nil, ["public.utf8-plain-text", "public.url"]),
            ("com.example.Editor", 200, 0, ["public.url", "public.png"]),
            ("com.example.Journal", 150, 1, ["public.utf8-plain-text"]),
            ("com.Éditeur", 150, nil, ["com.example.opaque"]),
        ]
        var rows: [SearchCorpusRow] = []
        for (index, value) in values.enumerated() {
            let (source, timestamp, pin, types) = value
            try database.execute(
                "INSERT INTO history_items VALUES (?, ?, ?, ?, ?)",
                bindings: [.integer(Int64(index)), source.map(SQLiteValue.text) ?? .null,
                           .real(timestamp), pin.map { .integer(Int64($0)) } ?? .null,
                           .integer(Int64(index))]
            )
            for type in types {
                try database.execute("INSERT INTO representations VALUES (?, ?)",
                                     bindings: [.integer(Int64(index)), .text(type)])
            }
            let title = index.isMultiple(of: 2) ? "needle" : "other"
            rows.append(SearchCorpusRow(
                id: HistoryItemID(rawValue: UUID()), contentVersion: .initial,
                title: title, searchBody: "", debugTitleUTF8Bytes: title.utf8.count, debugSearchBodyUTF8Bytes: 0,
                typeIdentifiers: types, lastCopiedAt: date(timestamp), copyCount: 1,
                lastSource: source, pinOrdinal: pin.map(PinOrdinal.init(rawValue:))
            ))
        }
        return (database, rows)
    }

    private func date(_ timestamp: Double) -> Date { Date(timeIntervalSinceReferenceDate: timestamp) }
}
#endif
