/// Direct proof of the frozen body-excerpt algorithm (docs/03b §8).
///
/// The seam is the pure `@testable` SearchWorker helper: these worked
/// examples pin edge redistribution, ellipsis placement, long-match clipping,
/// and UTF-16 translation without constructing a SwiftData store. WS17 keeps
/// the separate public-facade integration proof.
import HistoryCore
import Testing
@testable import HistoryStorage

struct SearchWorkerExcerptTests {
    private let snippetLimit = 322

    @Test func matchNearStartRedistributesAllMissingLeadingContextAfter() {
        let body = "MATCH" + String(repeating: "a", count: 395)

        let excerpt = SearchWorker.bodyExcerpt(
            body: body,
            characterRanges: [0..<5],
            snippetLimit: snippetLimit
        )

        #expect(
            excerpt.snippet
                == "MATCH" + String(repeating: "a", count: 315) + "…"
        )
        #expect(excerpt.ranges == [UTF16TextRange(location: 0, length: 5)])
    }

    @Test func matchNearEndRedistributesAllMissingTrailingContextBefore() {
        let body = String(repeating: "a", count: 395) + "MATCH"

        let excerpt = SearchWorker.bodyExcerpt(
            body: body,
            characterRanges: [395..<400],
            snippetLimit: snippetLimit
        )

        #expect(
            excerpt.snippet
                == "…" + String(repeating: "a", count: 315) + "MATCH"
        )
        #expect(excerpt.ranges == [UTF16TextRange(location: 316, length: 5)])
    }

    @Test func centeredMatchAddsBothEllipsesAndExtraContextAfter() {
        let body = String(repeating: "a", count: 200)
            + "MATCH"
            + String(repeating: "b", count: 200)

        let excerpt = SearchWorker.bodyExcerpt(
            body: body,
            characterRanges: [200..<205],
            snippetLimit: snippetLimit
        )

        #expect(
            excerpt.snippet
                == "…"
                    + String(repeating: "a", count: 157)
                    + "MATCH"
                    + String(repeating: "b", count: 158)
                    + "…"
        )
        #expect(excerpt.ranges == [UTF16TextRange(location: 158, length: 5)])
    }

    @Test func matchLongerThanWindowRetainsAndHighlightsItsFirstWindow() {
        let body = String(repeating: "p", count: 50)
            + String(repeating: "m", count: 400)
            + String(repeating: "s", count: 50)

        let excerpt = SearchWorker.bodyExcerpt(
            body: body,
            characterRanges: [50..<450],
            snippetLimit: snippetLimit
        )

        #expect(
            excerpt.snippet
                == "…" + String(repeating: "m", count: 320) + "…"
        )
        #expect(excerpt.ranges == [UTF16TextRange(location: 1, length: 320)])
    }

    @Test func supplementaryPlaneMatchUsesSnippetRelativeUTF16CodeUnits() {
        let body = String(repeating: "a", count: 200)
            + "😀Z"
            + String(repeating: "b", count: 203)

        let excerpt = SearchWorker.bodyExcerpt(
            body: body,
            characterRanges: [200..<202],
            snippetLimit: snippetLimit
        )

        #expect(
            excerpt.snippet
                == "…"
                    + String(repeating: "a", count: 159)
                    + "😀Z"
                    + String(repeating: "b", count: 159)
                    + "…"
        )
        // One leading ellipsis + 159 ASCII code units precede the match;
        // U+1F600 occupies two UTF-16 code units and "Z" occupies one.
        #expect(excerpt.ranges == [UTF16TextRange(location: 160, length: 3)])
    }

    @Test func scannedPrefixReportsOmittedStoredBodyWithTrailingEllipsis() {
        let scannedPrefix = String(repeating: "a", count: 315) + "MATCH"

        let excerpt = SearchWorker.bodyExcerpt(
            body: scannedPrefix,
            characterRanges: [315..<320],
            snippetLimit: snippetLimit,
            bodySuffixWasOmitted: true
        )

        #expect(excerpt.snippet == scannedPrefix + "…")
        #expect(excerpt.snippet.count == 321)
        #expect(excerpt.ranges == [UTF16TextRange(location: 315, length: 5)])
    }

    @Test func regexpPreflightTracksNestedSetsAndQuotedSetLiterals() {
        #expect(!SearchWorker.containsRejectedPatternShape("([[:alpha:]+])+"))
        #expect(!SearchWorker.containsRejectedPatternShape("([[a-z][A-Z]+])+"))
        #expect(SearchWorker.containsRejectedPatternShape("([[:alpha:]]+)+"))
        #expect(SearchWorker.containsRejectedPatternShape("([[a-z][A-Z]]+)+"))

        // `\Q…\E` is valid inside an ICU set. The quoted `[` must not add a
        // phantom nested-set depth that hides the real inner `+` from the
        // quantified-group check.
        #expect(SearchWorker.containsRejectedPatternShape("([\\Q[\\E]+)+"))
        #expect(!SearchWorker.containsRejectedPatternShape("\\Q(a+)+\\E"))
    }

    @Test func regexpPreflightDirectlyCoversEveryRejectedTokenFamily() {
        #expect(SearchWorker.containsRejectedPatternShape("(a+)+"))
        #expect(SearchWorker.containsRejectedPatternShape("((a){2})+"))
        #expect(SearchWorker.containsRejectedPatternShape("(a|ab)+"))
        #expect(SearchWorker.containsRejectedPatternShape("(a)\\1"))
        #expect(
            SearchWorker.containsRejectedPatternShape("(?<word>a)\\k<word>")
        )

        #expect(!SearchWorker.containsRejectedPatternShape("(?:Alpha)"))
        #expect(!SearchWorker.containsRejectedPatternShape("(Alpha|beta)"))
        #expect(!SearchWorker.containsRejectedPatternShape("(?# (a+)+ )Alpha"))
        #expect(!SearchWorker.containsRejectedPatternShape("\\(a\\+\\)\\+"))
    }

    @Test func regexpPreflightRejectsEveryCommentsModeEnablement() {
        #expect(SearchWorker.containsRejectedPatternShape("(?x)# [\n(a+)+"))
        #expect(SearchWorker.containsRejectedPatternShape("(?imx-s)# [\n(a+)+"))
        #expect(SearchWorker.containsRejectedPatternShape("(?ix-s:# [\n(a+)+)"))
        #expect(!SearchWorker.containsRejectedPatternShape("(?-x)(Alpha)"))
    }

    @Test func utf16TranslationUsesOriginalCharacterBoundaries() {
        let text = "a😀e\u{301}suffix"

        let ranges = SearchWorker.utf16Ranges(
            from: [1..<2, 2..<3],
            in: text
        )

        #expect(ranges == [
            UTF16TextRange(location: 1, length: 2),
            UTF16TextRange(location: 3, length: 2),
        ])
    }
}
