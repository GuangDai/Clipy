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
}
