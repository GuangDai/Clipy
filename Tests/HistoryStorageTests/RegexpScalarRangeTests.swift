/// Real capture/projection/regexp reads can return a complete scalar inside
/// a larger grapheme. These public DTO ranges are the input to UI highlighting;
/// no fabricated SearchPresentation or production range helper is involved.
import Foundation
import HistoryCore
import HistoryStorage
import Testing

struct RegexpScalarRangeTests {
    @Test func titleMatchesWithinGraphemesKeepTheirExactUTF16Ranges() async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        let title = "cafe\u{301} 👩‍💻"
        let receipt = try await history.perform(.capture(WSSupport.textCapture(
            title, observedAt: Date(timeIntervalSinceReferenceDate: 700_050_010)
        )))
        guard case .committed(let commit) = receipt,
              case .inserted(let reference) = commit.outcome else {
            Issue.record("The Unicode title fixture must insert one item")
            return
        }

        // c/a/f/e/mark/space occupy units 0...5; woman occupies 6...7,
        // ZWJ is unit 8, and laptop occupies 9...10 in that same grapheme.
        let cases: [(pattern: String, location: Int, length: Int, literal: String)] = [
            ("e", 3, 1, "e"),
            ("\\p{M}", 4, 1, "\u{301}"),
            ("💻", 9, 2, "💻"),
        ]
        for fixture in cases {
            let page = try await history.browse(HistoryBrowseRequest(
                kind: .search(text: fixture.pattern, mode: .regexp), limit: 10
            ))
            try #require(page.rows.count == 1)
            #expect(page.next == nil)
            let row = try #require(page.rows.first)
            #expect(row.item == reference)
            #expect(Data(row.title.utf8) == Data(title.utf8))
            let search = try #require(row.search)
            #expect(search.snippet == nil)
            #expect(search.matchedRanges == [
                UTF16TextRange(location: fixture.location, length: fixture.length),
            ])

            let range = try #require(search.matchedRanges.first)
            let displayed = row.title as NSString
            try #require(range.location + range.length <= displayed.length)
            let matched = displayed.substring(with: NSRange(
                location: range.location, length: range.length
            ))
            #expect(Data(matched.utf8) == Data(fixture.literal.utf8))
        }
    }
}
