#if DEBUG
/// Debug-only route instrumentation proofs for the compiled exact matcher.
///
/// `firstMatchWithDebugRoute` exists so later debugging can see WHICH lane
/// decided a comparison without adding a second full-body scan. These tests
/// pin the route contract against the scanner's internal structure — word
/// prefilter, scalar automaton, prefix-scoped finish mode, adversary switch,
/// and the Foundation fallback — so a future change that silently reroutes a
/// class of inputs fails here instead of only in the Release A/B lane.
/// Result-equality against the Foundation oracle is asserted alongside every
/// route assertion: a route is never proven at the cost of the answer.
import Foundation
import Testing
@testable import HistoryStorage

struct ExactLiteralMatcherDebugRouteTests {

    // MARK: - Fixtures

    private struct DeterministicGenerator {
        private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private static func route(
        term: String,
        in text: String
    ) -> ExactLiteralMatchDebugResult {
        ExactLiteralMatcher(term: term).firstMatchWithDebugRoute(in: text)
    }

    private static func foundationMatch(
        term: String,
        in text: String
    ) -> ExactLiteralMatch? {
        guard let range = text.range(
            of: term,
            options: [.caseInsensitive, .literal]
        ) else {
            return nil
        }
        let utf16Range = NSRange(range, in: text)
        return ExactLiteralMatch(
            characterOffset: text.distance(
                from: text.startIndex,
                to: range.lowerBound
            ),
            characterLength: text.distance(
                from: range.lowerBound,
                to: range.upperBound
            ),
            utf16Offset: utf16Range.location,
            utf16Length: utf16Range.length
        )
    }

    private static func pad(_ count: Int, with byte: Character = "m") -> String {
        String(repeating: byte, count: count)
    }

    // MARK: - Linear route on absent corpora across word boundaries

    /// Absent needles over filler bodies at every 8-byte word alignment stay
    /// on the compiled linear route (word prefilter with no candidates, then
    /// tail automaton), for both one-byte and long needles.
    @Test func absentBodiesAtWordAlignmentsStayLinear() {
        let lengths = [0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 64, 65]
        let needles = ["z", "zz", "zz-no-match", String(repeating: "z", count: 64)]
        for length in lengths {
            let body = Self.pad(length)
            for needle in needles {
                let result = Self.route(term: needle, in: body)
                #expect(
                    result.usedASCIILinearPath,
                    "absent length=\(length) needle=\(needle.count)"
                )
                #expect(result.match == nil)
            }
        }
    }

    // MARK: - Linear route on hits at word alignments

    /// A hit at any word alignment keeps the linear route and returns the
    /// oracle's coordinates exactly.
    @Test func hitsAtWordAlignmentsStayLinearAndExact() {
        for lead in [0, 1, 7, 8, 15, 16, 31, 32, 33, 63, 64] {
            let body = Self.pad(lead) + "needle" + Self.pad(9)
            let result = Self.route(term: "needle", in: body)
            #expect(result.usedASCIILinearPath, "lead=\(lead)")
            #expect(
                result.match == Self.foundationMatch(term: "needle", in: body),
                "lead=\(lead)"
            )
        }
    }

    /// Case-folded hits (needle lowercase, body mixed case) stay linear.
    @Test func mixedCaseHitStaysLinear() {
        for body in [
            "nEeDlE",
            "prefix-nEeDlE-suffix",
            Self.pad(16) + "NeEdLe",
        ] {
            let result = Self.route(term: "needle", in: body)
            #expect(result.usedASCIILinearPath, body)
            #expect(result.match == Self.foundationMatch(term: "needle", in: body))
        }
    }

    /// Non-letter needle heads must probe exactly one byte class: digits,
    /// punctuation, NUL-adjacent bytes, and space-headed needles still route
    /// linearly and match the oracle.
    @Test func nonLetterHeadNeedlesStayLinearAndExact() {
        let cases: [(String, String)] = [
            ("12345", Self.pad(8) + "12345" + Self.pad(8)),
            ("[x]", "y [x] z"),
            ("a b", Self.pad(15) + "a b"),
            ("--", Self.pad(31) + "--" + Self.pad(2)),
        ]
        for (term, body) in cases {
            let result = Self.route(term: term, in: body)
            #expect(result.usedASCIILinearPath, term)
            #expect(result.match == Self.foundationMatch(term: term, in: body))
        }
    }

    // MARK: - Foundation fallback routes

    /// Ineligible needles (non-ASCII or CR anywhere) never enter the compiled
    /// lane; Foundation decides alone.
    @Test func ineligibleTermsRouteToFoundation() {
        for term in ["café", "need\u{212A}le", "ne\r edle", "\rneedle"] {
            let result = Self.route(term: term, in: "some café body with needle")
            #expect(!result.usedASCIILinearPath, term)
            #expect(
                result.match == Self.foundationMatch(
                    term: term,
                    in: "some café body with needle"
                )
            )
        }
    }

    /// A non-ASCII or CR byte BEFORE or INSIDE a would-be ASCII match must
    /// hand the whole comparison to Foundation (a fold-based earlier match
    /// may exist, e.g. U+212A matching `k`).
    @Test func ineligibleByteInsidePrefixRoutesToFoundation() {
        for lead in [0, 3, 7, 8, 15, 16] {
            let kelvinBefore = Self.Self.pad(lead) + "\u{212A}" + "ey-needle"
            #expect(
                !Self.route(term: "key", in: kelvinBefore).usedASCIILinearPath,
                "kelvin lead=\(lead)"
            )
            let crInside = Self.Self.pad(lead) + "nee\rdle"
            #expect(
                !Self.route(term: "needle", in: crInside).usedASCIILinearPath,
                "cr-inside lead=\(lead)"
            )
        }
    }

    /// CR-bearing text where CR precedes the match area routes to Foundation
    /// (Character-coordinate hazard).
    @Test func carriageReturnBeforeMatchRoutesToFoundation() {
        let crFirst = "head\rline needle"
        #expect(!Self.route(term: "needle", in: crFirst).usedASCIILinearPath)
        #expect(
            Self.route(term: "needle", in: crFirst).match
                == Self.foundationMatch(term: "needle", in: crFirst)
        )
    }

    // MARK: - Prefix-scoped finish mode (early return)

    /// An ineligible byte PAST the match's prefix cannot change the result:
    /// the finish mode stops at `s + m`, so a Kelvin sign in a later word
    /// keeps the linear route and the oracle-equal match.
    @Test func nonASCIIPastPrefixKeepsLinearRoute() {
        // Match ends at 6; word [0,8) is checked; finish mode sees
        // index 8 >= matchEndLimit 6 and returns before reaching the Kelvin.
        let far = "needle" + Self.pad(9) + "\u{212A}"
        #expect(Self.route(term: "needle", in: far).usedASCIILinearPath)
        #expect(
            Self.route(term: "needle", in: far).match
                == Self.foundationMatch(term: "needle", in: far)
        )
        // CR equally past the prefix.
        let crFar = "needle" + Self.pad(9) + "\r" + "z"
        #expect(Self.route(term: "needle", in: crFar).usedASCIILinearPath)
        #expect(
            Self.route(term: "needle", in: crFar).match
                == Self.foundationMatch(term: "needle", in: crFar)
        )
    }

    /// The finish mode checks whole words: an ineligible byte in the SAME
    /// word as the match end but AFTER `s + m` conservatively routes to
    /// Foundation (documented overshoot of at most 7 bytes). The result
    /// stays oracle-equal either way.
    @Test func ineligibleByteInOvershootWindowIsConservativelyFoundation() {
        // Match at 14, end 20; word [16,24) is the finish word. A CR at 21
        // is past the prefix but inside that word.
        let body = Self.pad(14) + "needle" + "abc\r" + "z"
        let result = Self.route(term: "needle", in: body)
        #expect(!result.usedASCIILinearPath)
        #expect(result.match == Self.foundationMatch(term: "needle", in: body))
    }

    // MARK: - Adversary shape

    /// Repeated-prefix corpora (the shape that made candidate+memcmp
    /// implementations quadratic) stay on the compiled linear route — the
    /// failed-verification budget switches to the KMP automaton — for both
    /// the absent and the boundary-hit variants.
    @Test func repeatedPrefixAdversaryStaysLinearAndBounded() {
        let term = String(repeating: "a", count: 63) + "b"
        let absentBody = String(repeating: "a", count: 8 * 1_024)
        let absent = Self.route(term: term, in: absentBody)
        #expect(absent.usedASCIILinearPath)
        #expect(absent.match == nil)

        let presentBody = absentBody + "b"
        let present = Self.route(term: term, in: presentBody)
        #expect(present.usedASCIILinearPath)
        #expect(
            present.match == Self.foundationMatch(term: term, in: presentBody)
        )
    }

    /// Dense head-byte corpora (nearly every byte is a candidate) keep the
    /// FIRST match correct while staying linear. "nn" + "nnx" concatenates
    /// to "nnnnx…", whose first `nnx` occurrence starts at offset 1 — the
    /// decoy at 0 must not shadow it.
    @Test func denseHeadByteCorpusFindsFirstMatchLinearly() {
        let body = "nn" + "nnx" + String(repeating: "nna", count: 40)
        let result = Self.route(term: "nnx", in: body)
        #expect(result.usedASCIILinearPath)
        #expect(
            result.match == Self.foundationMatch(term: "nnx", in: body)
        )
        #expect(result.match?.characterOffset == 1)
    }

    // MARK: - Tail-only strings

    /// Strings shorter than one word run entirely in the scalar automaton
    /// and are still classified linear.
    @Test func tailOnlyStringsStayLinearAndExact() {
        for body in ["", "n", "ne", "needl", "needle", "needlex"] {
            let result = Self.route(term: "needle", in: body)
            #expect(result.usedASCIILinearPath, body)
            #expect(
                result.match == Self.foundationMatch(term: "needle", in: body)
            )
        }
    }

    // MARK: - Randomized agreement

    /// A fixed-seed ASCII sweep must be 100% linear-routed and oracle-equal:
    /// any Foundation reroute on pure-ASCII operands is a routing bug.
    @Test func randomizedASCIICorpusIsFullyLinearAndOracleEqual() {
        let alphabet = Array("aAbBnNeEdDlLxXyYzZ0-._ ".utf8)
        var generator = DeterministicGenerator()
        for _ in 0..<600 {
            let textLength = Int(generator.next() % 265)
            let termLength = Int(generator.next() % 17) + 1
            let text = String(decoding: (0..<textLength).map { _ in
                alphabet[Int(generator.next() % UInt64(alphabet.count))]
            }, as: UTF8.self)
            let term = String(decoding: (0..<termLength).map { _ in
                alphabet[Int(generator.next() % UInt64(alphabet.count))]
            }, as: UTF8.self)
            let result = Self.route(term: term, in: text)
            #expect(
                result.usedASCIILinearPath,
                "term=\(term.debugDescription) text=\(text.debugDescription)"
            )
            #expect(
                result.match == Self.foundationMatch(term: term, in: text),
                "term=\(term.debugDescription) text=\(text.debugDescription)"
            )
        }
    }

    // MARK: - Debug result value semantics

    /// The debug wrapper is a plain equatable value: tests and diagnostics
    /// can cache and compare routes without retaining matcher state.
    @Test func debugResultComparesByValue() {
        let linearNil = ExactLiteralMatchDebugResult(
            match: nil,
            usedASCIILinearPath: true
        )
        #expect(
            Self.route(term: "zz", in: "mmmm") == linearNil
        )
        #expect(
            Self.route(term: "zz", in: "mm\u{212A}") != linearNil
        )
    }
}
#endif
