/// Focused fixtures for the remaining docs/03b-instruction-set.md §8 search
/// mode clauses: regexp body presentation, fuzzy unpinned total ordering, and
/// non-ASCII UTF-16 range translation through the public history facade.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct SearchModeGapTests {

private struct FuzzyUnicodeFixture: Sendable {
    let name: String
    let text: String
    let term: String
    let expectedRange: UTF16TextRange
    let expectsBodySnippet: Bool
}

private static func captureText(
    _ history: SwiftDataHistory,
    text: String,
    observedAt: Date,
    source: String
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(
            text,
            observedAt: observedAt,
            source: source
        )
    ))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome else {
        Issue.record("Search mode arrange: expected inserted capture, got \(receipt)")
        throw HistoryFailure.persistence(.invariantViolation)
    }
    return reference
}

private static func substring(
    _ text: String,
    at range: UTF16TextRange
) throws -> String {
    let nsRange = NSRange(location: range.location, length: range.length)
    let swiftRange = try #require(Range(nsRange, in: text))
    return String(text[swiftRange])
}

/// 03b §8 regexp body lane: a title miss followed by a body-only match
/// returns a snippet and ranges relative to that snippet. The supplementary
/// character before the match makes the asserted UTF-16 location nontrivial.
@Test func regexpBodyOnlyMatchUsesSnippetRelativeUTF16Range() async throws {
    let storeURL = WSSupport.tempStoreURL("regexp-body-mode")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let reference = try await Self.captureText(
        history,
        text: "regexp heading\n😀 BODY42 suffix",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_084_000),
        source: "com.example.search-gap.regexp-body"
    )

    let page = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "BODY[0-9]+", mode: .regexp),
        limit: 10
    ))

    #expect(page.rows.count == 1, "regexp body fixture must produce one hit")
    let row = try #require(page.rows.first)
    #expect(row.item.id == reference.id)
    let search = try #require(row.search)
    let snippet = try #require(
        search.snippet,
        "a regexp body-only match must return a snippet"
    )
    let match = try #require(search.matchedRanges.first)
    #expect(
        match == UTF16TextRange(location: 18, length: 6),
        "regexp range is UTF-16-relative to the returned whole-body snippet"
    )
    #expect(try Self.substring(snippet, at: match) == "BODY42")
}

/// The regexp scanner admits only its first 1,000 body Characters, but the
/// excerpt's ellipsis describes the complete stored body. A match ending at
/// the scan boundary therefore keeps a trailing ellipsis for the omitted
/// suffix instead of implying that the body ended there.
@Test func regexpMatchAtScanBoundaryReportsOmittedBodySuffix() async throws {
    let storeURL = WSSupport.tempStoreURL("regexp-prefix-ellipsis")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let heading = "regexp boundary heading"
    let term = "TAIL"
    let admittedPrefix = heading + "\n"
    let paddingCount = HistoryLimits.standard.maximumRegexpTitleBodyPrefixCharacters
        - admittedPrefix.count
        - term.count
    let text = admittedPrefix
        + String(repeating: "a", count: paddingCount)
        + term
        + "stored suffix"
    _ = try await Self.captureText(
        history,
        text: text,
        observedAt: Date(timeIntervalSinceReferenceDate: 700_084_100),
        source: "com.example.search-gap.regexp-ellipsis"
    )

    let page = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: term, mode: .regexp),
        limit: 10
    ))
    let row = try #require(page.rows.first)
    let search = try #require(row.search)
    let snippet = try #require(search.snippet)
    let match = try #require(search.matchedRanges.first)

    #expect(snippet.last == "…")
    #expect(try Self.substring(snippet, at: match) == term)
}

/// 03b §8/04 §7: unpinned fuzzy hits sort by ascending Fuse score, then
/// recency descending, then History Item ID bytes ascending. The newest row
/// deliberately has the worse score so score dominance is unconditional.
@Test func fuzzyUnpinnedOrderingUsesScoreThenRecencyThenID() async throws {
    let storeURL = WSSupport.tempStoreURL("fuzzy-unpinned-total-order")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let exactOld = try await Self.captureText(
        history,
        text: "alpha",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_085_000),
        source: "com.example.search-gap.fuzzy.exact"
    )
    let tiedDate = Date(timeIntervalSinceReferenceDate: 700_086_000)
    let tiedLeft = try await Self.captureText(
        history,
        text: "alpha left",
        observedAt: tiedDate,
        source: "com.example.search-gap.fuzzy.left"
    )
    let tiedRight = try await Self.captureText(
        history,
        text: "alpha right",
        observedAt: tiedDate,
        source: "com.example.search-gap.fuzzy.right"
    )
    let typoNewest = try await Self.captureText(
        history,
        text: "alphx",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_087_000),
        source: "com.example.search-gap.fuzzy.typo"
    )

    let page = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "alpha", mode: .fuzzy),
        limit: 10
    ))
    let tiedIDs = [tiedLeft.id, tiedRight.id].sorted()
    let expected = tiedIDs + [exactOld.id, typoNewest.id]

    #expect(
        page.rows.map(\.item.id) == expected,
        "score sorts before recency; equal score/date rows finish by ID bytes"
    )
    #expect(
        page.rows.count == 4,
        "the multi-hit ordering assertion must never become conditional"
    )
    #expect(page.rows.allSatisfy { $0.pinnedPosition == nil })
}

/// 03b §8/04 §7: fuzzy ranges are UTF-16 offsets into the original title or
/// returned body snippet. These fixtures cover a supplementary-plane emoji,
/// a flag EGC (four UTF-16 units) on the body lane, and a decomposed combining
/// EGC (two UTF-16 units).
@Test func fuzzyNonASCIICharactersProduceOriginalStringUTF16Ranges() async throws {
    let fixtures = [
        FuzzyUnicodeFixture(
            name: "supplementary-title",
            text: "x😀needle",
            term: "😀",
            expectedRange: UTF16TextRange(location: 1, length: 2),
            expectsBodySnippet: false
        ),
        FuzzyUnicodeFixture(
            name: "flag-body",
            text: "flag heading\nx🇺🇳needle",
            term: "🇺🇳",
            expectedRange: UTF16TextRange(location: 14, length: 4),
            expectsBodySnippet: true
        ),
        FuzzyUnicodeFixture(
            name: "combining-title",
            text: "xe\u{301}cho",
            term: "e\u{301}",
            expectedRange: UTF16TextRange(location: 1, length: 2),
            expectsBodySnippet: false
        ),
    ]

    for (index, fixture) in fixtures.enumerated() {
        let storeURL = WSSupport.tempStoreURL("fuzzy-unicode-\(fixture.name)")
        defer { WSSupport.removeStore(storeURL) }
        let history = try await WSSupport.openHistory(storeURL: storeURL)
        let reference = try await Self.captureText(
            history,
            text: fixture.text,
            observedAt: Date(
                timeIntervalSinceReferenceDate: 700_088_000 + Double(index)
            ),
            source: "com.example.search-gap.fuzzy-unicode.\(fixture.name)"
        )

        let page = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: fixture.term, mode: .fuzzy),
            limit: 10
        ))
        let row = try #require(
            page.rows.first,
            "\(fixture.name) must fuzzy-match its exact Unicode Character"
        )
        #expect(page.rows.count == 1)
        #expect(row.item.id == reference.id)
        let search = try #require(row.search)
        let match = try #require(search.matchedRanges.first)
        #expect(
            match == fixture.expectedRange,
            "\(fixture.name) must preserve original UTF-16 widths"
        )

        if fixture.expectsBodySnippet {
            let snippet = try #require(search.snippet)
            #expect(try Self.substring(snippet, at: match) == fixture.term)
        } else {
            #expect(search.snippet == nil)
            #expect(try Self.substring(row.title, at: match) == fixture.term)
        }
    }
}
}
