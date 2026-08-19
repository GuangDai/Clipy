/// MatchHighlightingTests — search-match highlighting acceptance
/// (docs/03b-instruction-set.md §8; docs/roadmap/05-presentationui.md).
///
/// Matched ranges are UTF-16 offsets into the annotated string (the row title
/// when `search.snippet == nil`, else the snippet excerpt). These tests pin
/// the conversion itself: characters survive round-trip, exactly the matched
/// segments carry the strong-emphasis intent, and ranges that do not fall
/// entirely inside the string — beyond either end, splitting a surrogate
/// pair, zero-length, or overlapping after sorting — are dropped, never
/// clamped into wrong pixels.
import Foundation
import HistoryCore
import PresentationUI
import Testing

struct MatchHighlightingTests {

    // MARK: - Run-inspection helper

    /// The non-empty run segments carrying (or lacking) the strong-emphasis
    /// intent, in run order. Run counts are deliberately not asserted —
    /// `AttributedString` may coalesce adjacent equal-attribute runs — only
    /// which characters ended up emphasized.
    private func segments(
        of attributed: AttributedString,
        emphasized: Bool
    ) -> [String] {
        attributed.runs.reduce(into: [String]()) { partial, run in
            let isEmphasized =
                run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            guard isEmphasized == emphasized else { return }
            let segment = String(attributed.characters[run.range])
            if !segment.isEmpty {
                partial.append(segment)
            }
        }
    }

    // MARK: - Plain pass-through

    /// No ranges → the plain string, attribute-free (docs/
    /// 03b-instruction-set.md §8: nothing matched, nothing marked).
    @Test func noRangesYieldThePlainString() {
        let result = MatchHighlighting.highlighted(
            "Hello, Clipy",
            ranges: []
        )
        #expect(result == AttributedString("Hello, Clipy"))
    }

    // MARK: - Multi-range conversion

    /// Two disjoint ranges: exactly the two substrings are emphasized, the
    /// gaps stay plain, and the characters round-trip untouched.
    @Test func disjointRangesEmphasizeExactlyTheMatchedSubstrings() {
        let text = "alpha beta gamma"
        let result = MatchHighlighting.highlighted(
            text,
            ranges: [
                UTF16TextRange(location: 0, length: 5),   // "alpha"
                UTF16TextRange(location: 11, length: 5),  // "gamma"
            ]
        )

        #expect(String(result.characters) == text)
        #expect(segments(of: result, emphasized: true) == ["alpha", "gamma"])
        #expect(segments(of: result, emphasized: false) == [" beta "])
    }

    /// One range spanning the whole string: everything emphasized, nothing
    /// plain behind it.
    @Test func fullTextRangeEmphasizesEverything() {
        let text = "clipboard"
        let result = MatchHighlighting.highlighted(
            text,
            ranges: [UTF16TextRange(location: 0, length: text.utf16.count)]
        )

        #expect(String(result.characters) == text)
        #expect(segments(of: result, emphasized: true) == ["clipboard"])
        #expect(segments(of: result, emphasized: false).isEmpty)
    }

    // MARK: - Supplementary-plane characters

    /// A range covering an emoji's full surrogate pair (2 UTF-16 units)
    /// highlights the emoji itself — offset math must count code units, not
    /// Characters (docs/03b-instruction-set.md §8).
    @Test func supplementaryPlaneRangeCountsUTF16CodeUnits() {
        let text = "🎉 party"
        let result = MatchHighlighting.highlighted(
            text,
            ranges: [
                UTF16TextRange(location: 0, length: 2),   // "🎉"
                UTF16TextRange(location: 3, length: 5),   // "party"
            ]
        )

        #expect(String(result.characters) == text)
        #expect(segments(of: result, emphasized: true) == ["🎉", "party"])
        #expect(segments(of: result, emphasized: false) == [" "])
    }

    /// A range that splits a surrogate pair (starts at the low surrogate) is
    /// not a valid index range and is dropped — the result stays plain
    /// rather than clamping into half a Character.
    @Test func rangeSplittingASurrogatePairIsDropped() {
        let text = "🎉x"
        let result = MatchHighlighting.highlighted(
            text,
            ranges: [UTF16TextRange(location: 1, length: 1)]
        )

        #expect(result == AttributedString(text))
    }

    // MARK: - Combining marks

    /// A range over "e" + U+0301 covers both UTF-16 units of one Character;
    /// the emphasized segment is the composed-looking grapheme, not the bare
    /// base letter.
    @Test func combiningMarkRangeCoversTheWholeGrapheme() {
        let text = "cafe\u{0301} latte"
        let result = MatchHighlighting.highlighted(
            text,
            ranges: [UTF16TextRange(location: 3, length: 2)]   // "e" + U+0301
        )

        #expect(String(result.characters) == text)
        #expect(segments(of: result, emphasized: true) == ["e\u{0301}"])
        #expect(segments(of: result, emphasized: false) == ["caf", " latte"])
    }

    // MARK: - Defensive dropping

    /// Out-of-bounds (past either end), zero-length, and overlapping ranges
    /// are all ignored; the one valid range still highlights.
    @Test func outOfBoundsZeroLengthAndOverlappingRangesAreIgnored() {
        let text = "clipboard"
        let result = MatchHighlighting.highlighted(
            text,
            ranges: [
                UTF16TextRange(location: 50, length: 2),  // starts past the end
                UTF16TextRange(location: 3, length: 100),  // runs past the end
                UTF16TextRange(location: 2, length: 0),    // zero length
                UTF16TextRange(location: 0, length: 5),    // "clipb" — valid
                UTF16TextRange(location: 1, length: 3),    // "lip" — overlaps
            ]
        )

        #expect(String(result.characters) == text)
        #expect(segments(of: result, emphasized: true) == ["clipb"])
        #expect(segments(of: result, emphasized: false) == ["oard"])
    }
}
