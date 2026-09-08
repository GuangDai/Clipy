#if DEBUG
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

/// The fast path preserves ICU's UTF-16 literal match, including partial
/// graphemes. It must not borrow exact search's case-insensitive semantics.
struct RegexpLiteralFastPathTests {
    @Test(arguments: [
        ("prefix alpha tail", "alpha"),
        ("prefix ALPHA tail", "alpha"),
        ("prefix e\u{301} tail", "é"),
        ("prefix é tail", "e\u{301}"),
        ("prefix e\u{301} tail", "\u{301}"),
        ("🌿🌿文档搜索", "文档"),
        ("A\0B\0C", "\0B"),
        ("a\r\nb", "\n"),
        ("aaaaaaa", "ZZZZZZZZ"),
        ("abbbc", "ab+c"),
        ("abbbc", "^ab+c$"),
    ])
    func matchesFoundationWithoutChangingRanges(_ text: String, _ pattern: String) async throws {
        let regex = try NSRegularExpression(pattern: pattern)
        let expected = regex.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        let worker = SearchWorker()
        let page = try await worker.page(
            HistoryBrowseRequest(kind: .search(text: pattern, mode: .regexp), limit: 1),
            in: corpus(text), continuationAnchor: nil, processMarker: UUID()
        )
        if let expected {
            let row = try #require(page.rows.first)
            #expect(row.search?.matchedRanges == [UTF16TextRange(
                location: expected.range.location, length: expected.range.length
            )])
            #expect(row.search?.snippet == nil)
        } else {
            #expect(page.rows.isEmpty)
        }
    }

    @Test func literalFastPathStillRejectsAnExpiredRequest() async throws {
        let worker = SearchWorker()
        await worker.setRegexpEngineDeadline(.zero)
        await #expect(throws: HistoryFailure.temporarilyUnavailable(.searchEngineDeadline)) {
            try await worker.page(
                HistoryBrowseRequest(kind: .search(text: "alpha", mode: .regexp), limit: 1),
                in: corpus("alpha"), continuationAnchor: nil, processMarker: UUID()
            )
        }
    }

    private func corpus(_ title: String) -> SearchCorpusSnapshot {
        SearchCorpusSnapshot(position: ChangePosition(rawValue: 1), rows: [SearchCorpusRow(
            id: HistoryItemID(rawValue: UUID()), contentVersion: .initial,
            title: title, searchBody: "", debugTitleUTF8Bytes: title.utf8.count,
            debugSearchBodyUTF8Bytes: 0, typeIdentifiers: ["public.utf8-plain-text"],
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 1), copyCount: 1,
            lastSource: nil, pinOrdinal: nil
        )], debugTrace: SearchDebugTrace(id: UUID(), startedAt: ContinuousClock().now))
    }
}
#endif
