/// Exact search through capture, stored projection, matching and public row
/// materialization. Expected Unicode spelling and UTF-16 offsets are literal
/// fixture facts, independent of SearchWorker's range/excerpt helpers.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct UnicodeSearchPresentationTests {
    @Test func exactSearchDistinguishesNFCAndNFDWithoutRewritingDisplayedTitles() async throws {
        let history = try await openHistory()
        let nfc = "😀 café fin"
        let nfd = "😀 cafe\u{301} fin"
        let nfcItem = try await capture(nfc, in: history, at: 1)
        let nfdItem = try await capture(nfd, in: history, at: 2)

        let composed = try await singleResult("CAFÉ", in: history)
        #expect(composed.item == nfcItem)
        #expect(Data(composed.title.utf8) == Data(nfc.utf8))
        try expectMatch(composed, snippet: nil, location: 3, length: 4, literal: "café")

        let decomposed = try await singleResult("CAFE\u{301}", in: history)
        #expect(decomposed.item == nfdItem)
        #expect(Data(decomposed.title.utf8) == Data(nfd.utf8))
        try expectMatch(decomposed, snippet: nil, location: 3, length: 5, literal: "cafe\u{301}")
    }

    @Test func titleRangesCountSurrogatesAndCombiningMarksBeforeAndInsideTheMatch() async throws {
        let history = try await openHistory()
        let title = "e\u{301} 👩‍💻 😀 target"
        _ = try await capture(title, in: history)

        // e + combining acute is two UTF-16 units; the space adds one.
        // Woman + ZWJ + laptop is five UTF-16 units in one Character.
        let joinedEmoji = try await singleResult("👩‍💻", in: history)
        #expect(Data(joinedEmoji.title.utf8) == Data(title.utf8))
        try expectMatch(joinedEmoji, snippet: nil, location: 3, length: 5, literal: "👩‍💻")

        // The following space, supplementary emoji and space add four units.
        let afterEmoji = try await singleResult("TARGET", in: history)
        try expectMatch(afterEmoji, snippet: nil, location: 12, length: 6, literal: "target")
    }

    @Test func bodyMatchOffsetsReferToTheReturnedMixedUnicodeSnippet() async throws {
        let history = try await openHistory()
        let body = "heading\né e\u{301} 👩‍💻 😀 needle tail"
        _ = try await capture(body, in: history)
        let row = try await singleResult("NEEDLE", in: history)

        #expect(row.title == "heading")
        // heading + newline: 8; é/space: 2; e◌́/space: 3;
        // 👩‍💻/space: 6; 😀/space: 3. The literal begins at unit 22.
        try expectMatch(row, snippet: body, location: 22, length: 6, literal: "needle")
    }

    @Test func windowedBodyMatchKeepsUnicodeOffsetsAfterLeadingEllipsis() async throws {
        let history = try await openHistory()
        let body = "heading\n" + String(repeating: "a", count: 200)
            + "👩‍💻 e\u{301} NEEDLE 😀" + String(repeating: "b", count: 200)
        _ = try await capture(body, in: history)
        let row = try await singleResult("needle", in: history)

        // The 320-Character content window gives the 6-Character match 157
        // Characters on each side: 153 a + four leading Unicode/space
        // Characters, and two trailing Unicode/space Characters + 155 b.
        let expected = "…" + String(repeating: "a", count: 153)
            + "👩‍💻 e\u{301} NEEDLE 😀" + String(repeating: "b", count: 155) + "…"
        #expect(row.title == "heading")
        // 1 ellipsis + 153 a + 5-unit ZWJ emoji + space + 2-unit combining
        // grapheme + space = UTF-16 location 163 in the returned snippet.
        try expectMatch(row, snippet: expected, location: 163, length: 6, literal: "NEEDLE")
    }

    private func openHistory() async throws -> SwiftDataHistory {
        try await SwiftDataHistory.open(configuration: HistoryConfiguration(persistence: .memory))
    }

    private func capture(
        _ text: String, in history: SwiftDataHistory, at seconds: Double = 1
    ) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: seconds)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let item) = commit.outcome else {
            Issue.record("Unicode fixture must insert a distinct retained item")
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func singleResult(_ query: String, in history: SwiftDataHistory) async throws -> HistoryRow {
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: query, mode: .exact), limit: 10
        ))
        try #require(page.rows.count == 1)
        #expect(page.next == nil)
        return try #require(page.rows.first)
    }

    private func expectMatch(
        _ row: HistoryRow, snippet: String?, location: Int, length: Int, literal: String
    ) throws {
        let search = try #require(row.search)
        #expect(search.snippet.map { Data($0.utf8) } == snippet.map { Data($0.utf8) })
        try #require(search.matchedRanges == [UTF16TextRange(location: location, length: length)])
        let displayed = (search.snippet ?? row.title) as NSString
        try #require(location + length <= displayed.length)
        let matched = displayed.substring(with: NSRange(location: location, length: length))
        #expect(Data(matched.utf8) == Data(literal.utf8))
    }
}
