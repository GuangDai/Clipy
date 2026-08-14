/// Differential and adversarial proofs for the compiled exact-search matcher.
/// The public semantics remain Foundation's case-insensitive literal search;
/// the matcher may accelerate only the all-ASCII subset and must otherwise
/// delegate the whole comparison to Foundation (03b §8; IND-07).
import Foundation
import HistoryCore
import Testing
@testable import HistoryStorage

struct ExactLiteralMatcherTests {

private struct DeterministicGenerator {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
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

private static func asciiString(
    ordinal: Int,
    length: Int,
    alphabet: [UInt8]
) -> String {
    var ordinal = ordinal
    var bytes = Array(repeating: alphabet[0], count: length)
    for index in bytes.indices.reversed() {
        bytes[index] = alphabet[ordinal % alphabet.count]
        ordinal /= alphabet.count
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Small exhaustive ASCII differential: case, punctuation, overlap, empty
/// haystacks, and a NUL code unit all produce exactly Foundation's first
/// range. Empty terms are handled by SearchWorker's recent-equivalent lane and
/// deliberately stay outside this compiled matcher seam.
@Test func exhaustiveASCIIInputsMatchFoundation() {
    let alphabet: [UInt8] = [0x00, 0x41, 0x61, 0x2D]
    for textLength in 0...5 {
        let textCount = Int(pow(Double(alphabet.count), Double(textLength)))
        for textOrdinal in 0..<textCount {
            let text = Self.asciiString(
                ordinal: textOrdinal,
                length: textLength,
                alphabet: alphabet
            )
            for termLength in 1...3 {
                let termCount = Int(pow(
                    Double(alphabet.count),
                    Double(termLength)
                ))
                for termOrdinal in 0..<termCount {
                    let term = Self.asciiString(
                        ordinal: termOrdinal,
                        length: termLength,
                        alphabet: alphabet
                    )
                    #expect(
                        ExactLiteralMatcher(term: term).firstMatch(in: text)
                            == Self.foundationMatch(term: term, in: text),
                        "ASCII differential term=\(term.debugDescription) text=\(text.debugDescription)"
                    )
                }
            }
        }
    }
}

/// A fixed-seed wider differential catches failure-table and folding drift
/// without introducing nondeterminism into the suite.
@Test func randomizedASCIIInputsMatchFoundation() {
    let alphabet = Array("aAbBcCxyzXYZ019-_ \n".utf8)
    var generator = DeterministicGenerator()
    for _ in 0..<2_000 {
        let textLength = Int(generator.next() % 257)
        let termLength = Int(generator.next() % 33) + 1
        let text = String(decoding: (0..<textLength).map { _ in
            alphabet[Int(generator.next() % UInt64(alphabet.count))]
        }, as: UTF8.self)
        let term = String(decoding: (0..<termLength).map { _ in
            alphabet[Int(generator.next() % UInt64(alphabet.count))]
        }, as: UTF8.self)
        #expect(
            ExactLiteralMatcher(term: term).firstMatch(in: text)
                == Self.foundationMatch(term: term, in: text)
        )
    }
}

/// Any non-ASCII code unit in either operand forces whole-string Foundation
/// evaluation. This includes Unicode case-folding expansions, canonical forms,
/// supplementary scalars, combining marks, and an ASCII-looking match before
/// or after the non-ASCII scalar.
@Test func unicodeInputsMatchFoundation() {
    let fixtures: [(text: String, term: String)] = [
        ("Straße", "STRASSE"),
        ("İstanbul", "i"),
        ("Kelvin", "kelvin"),
        ("ΟΣ ος", "σ"),
        ("café cafe\u{301}", "CAFÉ"),
        ("needle 😀 suffix", "NEEDLE"),
        ("😀 prefix needle", "NEEDLE"),
        ("👩‍💻 needle", "👩‍💻"),
    ]
    for fixture in fixtures {
        #expect(
            ExactLiteralMatcher(term: fixture.term).firstMatch(in: fixture.text)
                == Self.foundationMatch(
                    term: fixture.term,
                    in: fixture.text
                )
        )
    }
}

/// CRLF is one Swift `Character` despite occupying two ASCII/UTF-16 code
/// units. The matcher therefore routes any CR-bearing operand through
/// Foundation instead of treating byte offsets as Character offsets.
@Test func carriageReturnInputsMatchFoundation() {
    let fixtures: [(text: String, term: String)] = [
        ("prefix\r\nneedle", "needle"),
        ("prefix\r\nneedle", "\nneedle"),
        ("prefix\r\nneedle", "\r\n"),
        ("needle\r\nsuffix", "NEEDLE"),
    ]
    for fixture in fixtures {
        #expect(
            ExactLiteralMatcher(term: fixture.term).firstMatch(in: fixture.text)
                == Self.foundationMatch(
                    term: fixture.term,
                    in: fixture.text
                )
        )
    }
}

/// Regression for the matcher→excerpt seam: a CRLF before a late body match
/// must use Foundation's Character coordinates, keeping the bounded window and
/// its UTF-16 highlight valid instead of indexing past the grapheme boundary.
@Test func carriageReturnPrefixFeedsValidExcerptCoordinates() throws {
    let body = "head\r\n" + String(repeating: "a", count: 400) + "NEEDLE"
    let match = try #require(
        ExactLiteralMatcher(term: "needle").firstMatch(in: body)
    )

    let excerpt = SearchWorker.bodyExcerpt(
        body: body,
        characterRanges: [
            match.characterOffset ..<
                (match.characterOffset + match.characterLength),
        ],
        snippetLimit: HistoryLimits.standard.maximumBodySearchSnippetCharacters
    )
    #expect(excerpt.ranges.count == 1)
    let range = excerpt.ranges[0]
    let nsRange = NSRange(location: range.location, length: range.length)
    let swiftRange = try #require(Range(nsRange, in: excerpt.snippet))
    #expect(excerpt.snippet[swiftRange] == "NEEDLE")
}

/// The repeated-prefix adversary that makes candidate+memcmp implementations
/// approach O(n*m) remains bounded by the matcher's linear KMP fallback.
@Test func repeatedPrefixAdversaryFindsOrRejectsAtTheBoundary() {
    let term = String(repeating: "a", count: 4_095) + "b"
    let absentBody = String(repeating: "a", count: 256 * 1_024)
    #expect(ExactLiteralMatcher(term: term).firstMatch(in: absentBody) == nil)

    let presentBody = absentBody + "b"
    #expect(
        ExactLiteralMatcher(term: term).firstMatch(in: presentBody)
            == ExactLiteralMatch(
                characterOffset: absentBody.count - 4_095,
                characterLength: term.count,
                utf16Offset: absentBody.utf16.count - 4_095,
                utf16Length: term.utf16.count
            )
    )
}

/// A block-scanning implementation (SIMD/SWAR word prefilter ahead of the
/// scalar KMP verify) must stay exactly Foundation-equivalent across every
/// alignment of needle and haystack around the machine-word boundaries
/// (8 and 16 bytes) that chunked loops process. Fixed adversarial layouts:
/// matches landing on, spanning, and one-off each boundary; decoy first
/// bytes (both cases) that fail verification before a later true match; and
/// the same layouts with an uppercase haystack against a lowercase needle.
@Test func wordBoundaryAndDecoyLayoutsMatchFoundation() {
    let chunkSizes = [7, 8, 9, 15, 16, 17, 31, 32, 33]
    for chunk in chunkSizes {
        for shift in [0, 1, 2, 7] {
            let prefix = String(repeating: "x", count: chunk + shift)
            // Decoy: first byte matches the needle head (wrong case), the
            // tail diverges; the true match starts one byte later.
            let decoyHaystack = prefix + "Nxxdle-zzz-needle-tail"
            #expect(
                ExactLiteralMatcher(term: "needle").firstMatch(in: decoyHaystack)
                    == Self.foundationMatch(term: "needle", in: decoyHaystack),
                "decoy chunk=\(chunk) shift=\(shift)"
            )
            // Boundary-spanning match with case-flipped haystack copy.
            let casedHaystack = prefix + "nEeDlE" + "-suffix"
            #expect(
                ExactLiteralMatcher(term: "needle").firstMatch(in: casedHaystack)
                    == Self.foundationMatch(term: "needle", in: casedHaystack),
                "cased chunk=\(chunk) shift=\(shift)"
            )
            // Absent needle whose first byte is present in many word-aligned
            // positions: every chunk produces candidates that must verify.
            let absentHaystack = prefix + "n" + String(repeating: "nxd", count: chunk + 4)
            #expect(
                ExactLiteralMatcher(term: "needle").firstMatch(in: absentHaystack)
                    == nil,
                "absent chunk=\(chunk) shift=\(shift)"
            )
            #expect(
                Self.foundationMatch(term: "needle", in: absentHaystack) == nil,
                "oracle agrees the absent layout has no match"
            )
        }
    }
}

/// A candidate found by a fast prefilter must never be returned when a later
/// byte disproves all-ASCII/CR eligibility: the whole comparison falls back
/// to Foundation (03b §8 semantics; the mixed-coordinate hazard the CR
/// exclusion exists for). Each layout plants a would-be ASCII match first
/// and the disproving scalar after it, at word-boundary distances.
@Test func nonASCIIBehindAnASCIIRegionStillDelegatesWholeComparison() {
    for lead in [0, 7, 8, 15, 16, 31] {
        let prefix = String(repeating: "y", count: lead)
        let mixed = prefix + "needle" + "\u{212A}" // KELVIN SIGN after the match
        let match = ExactLiteralMatcher(term: "needle").firstMatch(in: mixed)
        #expect(
            match == Self.foundationMatch(term: "needle", in: mixed),
            "mixed-script lead=\(lead)"
        )
        // CR behind the match: CRLF re-clustering can move Character
        // coordinates, so Foundation must decide the whole string.
        let crBody = prefix + "needle" + "\r" + "z"
        #expect(
            ExactLiteralMatcher(term: "needle").firstMatch(in: crBody)
                == Self.foundationMatch(term: "needle", in: crBody),
            "cr-behind lead=\(lead)"
        )
    }
}
}
