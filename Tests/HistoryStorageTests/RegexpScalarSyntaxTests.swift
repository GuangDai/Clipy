import Foundation
import HistoryCore
import HistoryStorage
import Testing

/// ICU syntax remains visible when a following combining mark joins a
/// metacharacter into one Swift Character (03b §8). Compilation first proves
/// rejection comes from the existing pattern policy, not malformed syntax.
struct RegexpScalarSyntaxTests {
    @Test(arguments: [
        "(a+\u{301})+",       // mark joins the inner +
        "(\u{301}a+)+",       // mark joins the opening (
        "(a|\u{301}b)+",      // mark joins the alternation |
        "((a){2}\u{301})+",   // mark joins the interval's closing }
    ])
    func combiningMarksCannotHideRejectedSyntax(pattern: String) async throws {
        _ = try NSRegularExpression(pattern: pattern)
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        await #expect(throws: HistoryFailure.invalidInput(.invalidRegularExpression)) {
            _ = try await history.browse(HistoryBrowseRequest(
                kind: .search(text: pattern, mode: .regexp), limit: 10
            ))
        }
    }

    @Test(arguments: [
        ("\\Q(a+\u{301})+\\E", "(a+\u{301})+"),
        ("([+\u{301}])+", "+\u{301}"),
        ("(?:a\u{301})+", "a\u{301}a\u{301}"),
    ])
    func quotedAndClassLiteralsRemainSearchable(pattern: String, text: String) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        _ = try await history.perform(.capture(WSSupport.textCapture(
            text, observedAt: Date(timeIntervalSinceReferenceDate: 1)
        )))
        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: pattern, mode: .regexp), limit: 10
        ))
        try #require(page.rows.count == 1)
        let row = try #require(page.rows.first)
        #expect(Data(row.title.utf8) == Data(text.utf8))
        let presentation = try #require(row.search)
        #expect(presentation.snippet == nil)
        #expect(presentation.matchedRanges == [
            UTF16TextRange(location: 0, length: text.utf16.count)
        ])
    }
}
