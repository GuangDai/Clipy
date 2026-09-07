import Foundation
import HistoryCore
import HistoryStorage
import Testing

/// Foundation searches UTF-16, while excerpt windows count Characters
/// (03b §8). A scalar inside a combining/ZWJ Character must retain its exact
/// highlight through capture, persisted projection and page materialization.
struct SearchBodyScalarHighlightTests {
    @Test(arguments: [SearchMode.exact, .regexp])
    func wholeBodyKeepsTheMatchedScalarRange(mode: SearchMode) async throws {
        for (cluster, query, offset, length) in Self.fixtures {
            let body = "heading\n" + cluster + " tail"
            let presentation = try await search(body, query: query, mode: mode)
            #expect(presentation.snippet.map { Data($0.utf8) } == Data(body.utf8))
            #expect(presentation.matchedRanges == [
                UTF16TextRange(location: 8 + offset, length: length)
            ])
            try expectHighlightedBytes(presentation, equal: query)
        }
    }

    @Test(arguments: [SearchMode.exact, .regexp])
    func windowedBodyPreservesTheScalarAfterLeadingEllipsis(mode: SearchMode) async throws {
        for (cluster, query, offset, length) in Self.fixtures {
            let body = "heading\n" + String(repeating: "a", count: 180)
                + cluster + String(repeating: "b", count: 180)
            let presentation = try await search(body, query: query, mode: mode)
            // One matched Character leaves 319 context Characters: 159
            // before and 160 after, with both omitted edges indicated.
            let expected = "…" + String(repeating: "a", count: 159)
                + cluster + String(repeating: "b", count: 160) + "…"
            #expect(presentation.snippet.map { Data($0.utf8) } == Data(expected.utf8))
            #expect(presentation.matchedRanges == [
                UTF16TextRange(location: 160 + offset, length: length)
            ])
            try expectHighlightedBytes(presentation, equal: query)
        }
    }

    private static let fixtures: [(String, String, Int, Int)] = [
        ("e\u{301}", "\u{301}", 1, 1),
        ("👩‍💻", "💻", 3, 2)
    ]

    @Test func zeroLengthBodyMatchStillReturnsContextWithoutAHighlight() async throws {
        let body = "heading\n" + String(repeating: "a", count: 180)
            + "é" + String(repeating: "b", count: 180)
        let presentation = try await search(body, query: "(?<=é)", mode: .regexp)
        let expected = "…" + String(repeating: "a", count: 159)
            + "é" + String(repeating: "b", count: 160) + "…"
        #expect(presentation.snippet == expected)
        #expect(presentation.matchedRanges.isEmpty)
    }

    private func search(
        _ body: String, query: String, mode: SearchMode
    ) async throws -> SearchPresentation {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        _ = try await history.perform(.capture(WSSupport.textCapture(
            body, observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: query, mode: mode), limit: 10
        ))
        try #require(page.rows.count == 1)
        let row = try #require(page.rows.first)
        #expect(row.title == "heading")
        #expect(page.next == nil)
        return try #require(row.search)
    }

    private func expectHighlightedBytes(
        _ presentation: SearchPresentation, equal expected: String
    ) throws {
        let snippet = try #require(presentation.snippet)
        let range = try #require(presentation.matchedRanges.first)
        let highlighted = (snippet as NSString).substring(with: NSRange(
            location: range.location, length: range.length
        ))
        #expect(Data(highlighted.utf8) == Data(expected.utf8))
    }
}
