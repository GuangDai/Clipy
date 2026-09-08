import Foundation
import Testing
@testable import HistoryStorage

struct FuzzyASCIIRejectionTests {
    @Test func rejectionPreservesPinnedFuseScoresAndRanges() async throws {
        let worker = SearchWorker()
        let queries = [
            "a", "ab", "abc", "abcdef", "ZZZZZZZZ", "aaaabbbbcc", "alpha beta",
            "\r", "\n", "\r\n", "a\r\nb", "é", "e\u{301}", "İ", "Σ", "😀",
            String(repeating: "a", count: 63), String(repeating: "a", count: 64),
        ]
        for query in queries {
            let texts = [
                "", query, query.uppercased(), "x" + query, "ab", "alphabet soup",
                "aaaaabbbbb", "zyxwvutsrqponmlkjihgfedcba", "a\r\nb", "\r", "\n",
                "é", "e\u{301}", "İstanbul", "ΟΣ ος σ", "😀ab", "Kelvin",
                String(repeating: "x", count: 69) + query,
                String(repeating: "x", count: 70) + query,
                String(repeating: "x", count: 71) + query,
                String(repeating: "x", count: 140) + query,
                String(repeating: "\r\n", count: 69) + query,
                String(repeating: "abcd ", count: 1_024),
            ]
            for text in texts {
                let result = try await worker.compareFuzzyRejection(query: query, text: text)
                #expect(result.actualScore == result.expectedScore, "query=\(query.debugDescription), text=\(text.prefix(80).debugDescription)")
                #expect(result.actualRanges == result.expectedRanges)
            }
        }
    }

    @Test func absentPositionsRejectBeforeTheLongBodyWalk() async throws {
        let worker = SearchWorker()
        // Common letters a/b are present, but six absent z positions exceed
        // the five errors allowed for an eight-Character query. A mere
        // alphabet intersection would retain this obvious negative.
        let result = try await worker.compareFuzzyRejection(
            query: "abzzzzzz", text: String(repeating: "alphabet soup ", count: 10_000)
        )
        #expect(result.rejected)
        #expect(result.expectedScore == nil)

        // Distant exact occurrences populate Fuse's preliminary range mask
        // but cannot turn a Bitap miss into a returned score. The shortcut
        // may reject even though the unbounded body contains the term.
        let far = try await worker.compareFuzzyRejection(
            query: "ZZZZZZZZ", text: String(repeating: "a", count: 200) + "ZZZZZZZZ"
        )
        #expect(far.rejected)
        #expect(far.expectedScore == nil)
    }

    @Test func nonASCIIAtTheProbeBoundaryKeepsTheOriginalMatcher() async throws {
        let worker = SearchWorker()
        let query = "é"
        // The last nominal ASCII byte belongs to a non-ASCII Character.
        // A byte prefix alone would incorrectly classify it as plain e.
        let result = try await worker.compareFuzzyRejection(
            query: query, text: String(repeating: "x", count: 70) + "e\u{301}"
        )
        #expect(!result.rejected)
        #expect(result.actualScore == result.expectedScore)
        #expect(result.actualRanges == result.expectedRanges)
    }
}

private struct FuzzyRejectionComparison: Sendable {
    let rejected: Bool
    let expectedScore: Double?
    let actualScore: Double?
    let expectedRanges: [Range<Int>]?
    let actualRanges: [Range<Int>]?
}

private extension SearchWorker {
    func compareFuzzyRejection(query: String, text: String) throws -> FuzzyRejectionComparison {
        let pattern = try #require(fuse.createPattern(from: query))
        let scan = Self.boundedCharacterPrefix(
            of: text, maximumCharacters: limits.maximumFuzzyTitleBodyPrefixCharacters
        )
        // The unmodified matcher remains the independent oracle for this
        // optimization; only the rejection condition is under comparison.
        let expected = fuzzyMatch(pattern: pattern, lowercased: scan.text.lowercased(),
                                  characterCount: scan.characterCount)
        let rejected = FuzzyASCIIRejection(pattern: pattern).rejects(text)
        let actual = rejected ? nil : expected
        return FuzzyRejectionComparison(
            rejected: rejected, expectedScore: expected?.score, actualScore: actual?.score,
            expectedRanges: expected?.characterRanges, actualRanges: actual?.characterRanges
        )
    }
}
