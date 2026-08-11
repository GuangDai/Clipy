/// WS17 — Search modes and matched ranges (docs/06-cross-cutting.md §8 WS17;
/// docs/03b-instruction-set.md §8 — the frozen search behavior). Facade-driven
/// via `history.browse(HistoryBrowseRequest(kind:limit:))`: the three frozen
/// search modes — exact (case-insensitive literal substring, title-then-body),
/// regexp (`NSRegularExpression`, 1,000-Character prefixes, unsafe-pattern
/// rejection), fuzzy (Fuse 1.4.0, pinned-first, score then recency then ID) —
/// plus the empty-term recent-equivalent and the failure producers
/// `.invalidInput(.invalidRegularExpression)` and
/// `.invalidInput(.invalidSearchTerm)`.
///
/// All mode behavior is frozen by 03b §8 and fixture-locked here. The
/// implementation under test is `SearchWorker.page` (docs/05-authority-kernel.md
/// §14.2), wired through the public facade. Every assertion cites 03b §8 +
/// WS17. Deterministic fixed timestamps are monotone per scenario.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

struct WS17SearchModesTests {

// MARK: - Fixture helpers

/// Captures one text item through the public facade and returns the inserted
/// reference; each item's title == searchBody for single-line text
/// (§15 projection determinism).
private static func captureText(
    _ history: SwiftDataHistory,
    text: String,
    observedAt: Date,
    source: String
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(.capture(
        WSSupport.textCapture(text, observedAt: observedAt, source: source)
    ))
    guard case let .committed(commit) = receipt,
          case let .inserted(reference) = commit.outcome else {
        Issue.record("WS17 arrange: expected .committed(.inserted), got \(receipt)")
        fatalError("WS17 arrange: unreachable")
    }
    return reference
}

/// Extracts the substring at `range` from `text` via the UTF-16 view,
/// verifying the UTF-16 offsets index correctly (03b §8).
private static func substring(
    _ text: String,
    utf16Range: UTF16TextRange
) -> String {
    let view = text.utf16
    let start = view.index(view.startIndex, offsetBy: utf16Range.location)
    let end = view.index(start, offsetBy: utf16Range.length)
    // Decode the UTF-16 subsequence back into a String (03b §8: ranges are
    // UTF-16 offsets; the substring must round-trip the UTF-16 view).
    return String(decoding: view[start..<end], as: UTF16.self)
}

// MARK: - Shared fixture set

/// WS17 (docs/06 §8): a known set of rows fixture-pinning the frozen search
/// behavior. Four items:
/// - `alphaID`: pinned, title "Alpha Project Notes" — a title match for
///   "Alpha" in every mode.
/// - `betaAlphaID`: unpinned, title "beta alpha mix" — also a title match
///   for "alpha", case-insensitive.
/// - `gammaID`: unpinned, multi-line body where "gamma" appears only in a
///   later line; the title does NOT match — a body-only match.
/// - `imageID`: image-only (title is the type-based fallback "Image",
///   searchBody empty) — no match for any text search.
///
/// Observation times are monotone so the default unpinned order is
/// deterministic (lastCopiedAt descending). Returns the pinned ID first.
private struct SearchFixture {
    let alphaID: HistoryItemID
    let betaAlphaID: HistoryItemID
    let gammaID: HistoryItemID
    let imageID: HistoryItemID
}

private static func populateFixture(
    _ history: SwiftDataHistory
) async throws -> SearchFixture {
    // Item 1: pinned, title "Alpha Project Notes" — newest by observation time.
    let alphaRef = try await Self.captureText(
        history,
        text: "Alpha Project Notes",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_050_000),
        source: "com.example.ws17.alpha"
    )
    // Pin alpha first (pinOrdinal 0).
    _ = try await history.perform(.placePinned(alphaRef.id, at: .last))

    // Item 2: unpinned, title "beta alpha mix" — second-newest.
    let betaAlphaRef = try await Self.captureText(
        history,
        text: "beta alpha mix",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_049_900),
        source: "com.example.ws17.beta"
    )

    // Item 3: unpinned, multi-line — "gamma" in a later line, title mismatch.
    // The §15 projection title is the first non-empty trimmed line
    // ("delta header"), and searchBody is the full normalized text.
    let gammaRef = try await Self.captureText(
        history,
        text: "delta header\nsecond line\ngamma detail here",
        observedAt: Date(timeIntervalSinceReferenceDate: 700_049_800),
        source: "com.example.ws17.gamma"
    )

    // Item 4: image-only — no textual representation, so the §15 projection
    // produces a type-based fallback title ("Image") and an empty searchBody.
    let imageReceipt = try await history.perform(.capture(
        ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.png",
                bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            )],
            origin: CopyOriginObservation(
                sourceApplication: "com.example.ws17.image",
                lineageHint: nil
            ),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_049_700)
        )
    ))
    guard case let .committed(imageCommit) = imageReceipt,
          case let .inserted(imageRef) = imageCommit.outcome else {
        Issue.record("WS17 arrange: expected .committed(.inserted) for image, got \(imageReceipt)")
        fatalError("WS17 arrange: unreachable")
    }

    return SearchFixture(
        alphaID: alphaRef.id,
        betaAlphaID: betaAlphaRef.id,
        gammaID: gammaRef.id,
        imageID: imageRef.id
    )
}

// MARK: - EXACT mode

/// WS17 + 03b §8 (exact): case-insensitive literal substring. A title-match
/// row has `snippet == nil` and `matchedRanges` that are UTF-16 offsets into
/// `HistoryRow.title`; a body-match row has a `snippet` and ranges relative to
/// that snippet. Title matches rank before body matches (default order
/// preserved). Case-insensitive: "ALPHA" matches "alpha". The image-only item
/// (empty searchBody) never matches.
@Test func exactModeTitleBeforeBodyCaseInsensitiveAndUTF16Ranges() async throws {
    let storeURL = WSSupport.tempStoreURL("ws17-exact")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let fixture = try await Self.populateFixture(history)

    // 03b §8 + WS17: EXACT, case-insensitive ("alpha" → matches "Alpha").
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "alpha", mode: .exact),
        limit: 50
    ))

    // WS17 + 03b §8: title matches only — "gamma" does not appear in any
    // title, and "alpha" appears in both alpha and beta-alpha titles. The
    // default order is preserved: pinned (alpha, pinOrdinal 0) first, then
    // unpinned by lastCopiedAt descending (beta-alpha).
    #expect(
        page.rows.count == 2,
        "WS17/03b §8 (exact): two title matches for 'alpha'"
    )
    let firstRow = try #require(page.rows.first)
    #expect(
        firstRow.item.id == fixture.alphaID,
        "WS17/03b §8 (exact): the pinned title-match row ranks first"
    )

    // 03b §8: a title match has `snippet == nil`.
    let firstSearch = try #require(firstRow.search)
    #expect(
        firstSearch.snippet == nil,
        "WS17/03b §8 (exact): title match has snippet == nil"
    )
    // 03b §8: matchedRanges are UTF-16 offsets into HistoryRow.title.
    // Case-insensitive match of "alpha" against "Alpha" locates the full
    // 5-Character "Alpha" at offset 0 — verified by extracting the substring.
    #expect(
        firstSearch.matchedRanges.count == 1,
        "WS17/03b §8 (exact): one matched range for a literal title match"
    )
    let titleRange = try #require(firstSearch.matchedRanges.first)
    let extractedTitle = Self.substring(firstRow.title, utf16Range: titleRange)
    #expect(
        extractedTitle.lowercased() == "alpha",
        "WS17/03b §8 (exact): the UTF-16 range extracts 'alpha' from the title"
    )

    // WS17 + 03b §8: the second row (unpinned beta-alpha) is also a title match.
    let secondRow = try #require(page.rows.dropFirst().first)
    #expect(
        secondRow.item.id == fixture.betaAlphaID,
        "WS17/03b §8 (exact): the unpinned title-match row is second"
    )
    let secondSearch = try #require(secondRow.search)
    #expect(
        secondSearch.snippet == nil,
        "WS17/03b §8 (exact): second row is a title match (snippet == nil)"
    )

    // WS17 + 03b §8: a BODY-only match ("gamma" in the multi-line searchBody,
    // title does not match) produces a snippet, and ranges index into the
    // SNIPPET.
    let gammaPage = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "gamma", mode: .exact),
        limit: 50
    ))
    #expect(
        gammaPage.rows.count == 1,
        "WS17/03b §8 (exact): one body-only match for 'gamma'"
    )
    let gammaRow = try #require(gammaPage.rows.first)
    #expect(
        gammaRow.item.id == fixture.gammaID,
        "WS17/03b §8 (exact): the body-match row is the gamma item"
    )
    let gammaSearch = try #require(gammaRow.search)
    // 03b §8: a body match supplies a snippet; its ranges are relative to the
    // excerpt. The body is shorter than 320 Characters so the whole body is
    // retained (no ellipses).
    let snippet = try #require(gammaSearch.snippet)
    #expect(
        !snippet.isEmpty,
        "WS17/03b §8 (exact): a body match yields a non-empty snippet"
    )
    // 03b §8: the matched range indexes into the SNIPPET.
    let gammaRange = try #require(gammaSearch.matchedRanges.first)
    let excerptedGamma = Self.substring(snippet, utf16Range: gammaRange)
    #expect(
        excerptedGamma.lowercased() == "gamma",
        "WS17/03b §8 (exact): the snippet range extracts 'gamma' from the snippet"
    )

    // WS17 + 03b §8: case-insensitive — "ALPHA" (uppercase) matches "Alpha".
    let upperPage = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "ALPHA", mode: .exact),
        limit: 50
    ))
    #expect(
        upperPage.rows.count == 2,
        "WS17/03b §8 (exact): case-insensitive 'ALPHA' matches the same two rows"
    )
}

// MARK: - REGEXP mode

/// WS17 + 03b §8 (regexp): a valid pattern matches like exact (title first,
/// default order preserved, `snippet == nil` for title match). An invalid
/// pattern — `(a+)+` (nested quantifier), a quantified alternation such as
/// `(a|a)+b`, or a backreference `(a)\1` — throws
/// `.invalidInput(.invalidRegularExpression)` BEFORE scanning.
@Test func regexpModeValidPatternTitleFirstAndUnsafePatternsRejectedBeforeScan() async throws {
    let storeURL = WSSupport.tempStoreURL("ws17-regexp")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let fixture = try await Self.populateFixture(history)

    // 03b §8 + WS17: a valid regexp pattern "Alpha" matches the title first
    // (case-sensitive by NSRegularExpression default — "Alpha" literal).
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "Alpha", mode: .regexp),
        limit: 50
    ))
    // NSRegularExpression is case-sensitive by default; "Alpha" matches the
    // pinned alpha title, but NOT "beta alpha mix" (lowercase 'a').
    #expect(
        page.rows.count == 1,
        "WS17/03b §8 (regexp): case-sensitive 'Alpha' matches one title"
    )
    let firstRow = try #require(page.rows.first)
    #expect(
        firstRow.item.id == fixture.alphaID,
        "WS17/03b §8 (regexp): the title-match row is the pinned alpha item"
    )
    let firstSearch = try #require(firstRow.search)
    #expect(
        firstSearch.snippet == nil,
        "WS17/03b §8 (regexp): a title match has snippet == nil"
    )
    // 03b §8: UTF-16 ranges relative to HistoryRow.title.
    let titleRange = try #require(firstSearch.matchedRanges.first)
    let extractedTitle = Self.substring(firstRow.title, utf16Range: titleRange)
    #expect(
        extractedTitle == "Alpha",
        "WS17/03b §8 (regexp): the UTF-16 range extracts 'Alpha' from the title"
    )

    // Alternation itself remains admissible; the conservative rejection is
    // specifically for a group that is subsequently quantified.
    let alternationPage = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "(Alpha|beta)", mode: .regexp),
        limit: 50
    ))
    #expect(
        alternationPage.rows.map(\.item.id)
            == [fixture.alphaID, fixture.betaAlphaID]
    )

    // ICU POSIX bracket expressions contain an inner `]` that must not close
    // the surrounding character class in the preflight scanner. The `+`
    // below is a literal class member, so only the safe one-character group
    // is quantified and the pattern remains admissible (03b §8).
    let posixClassPage = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "([[:alpha:]+])+", mode: .regexp),
        limit: 50
    ))
    #expect(!posixClassPage.rows.isEmpty)

    let nestedClassPage = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "([[a-z][A-Z]+])+", mode: .regexp),
        limit: 50
    ))
    #expect(!nestedClassPage.rows.isEmpty)

    // ICU quoting makes every token literal; the preflight scanner must not
    // reinterpret the nested-quantifier spelling inside `\Q…\E`.
    let quotedLiteralPage = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "\\Q(a+)+\\E", mode: .regexp),
        limit: 50
    ))
    #expect(quotedLiteralPage.rows.isEmpty)

    // The input below would make an admitted overlapping-alternation pattern
    // catastrophically backtrack. It is deliberately retained in the real
    // corpus so these assertions prove admission happens before scanning; no
    // detached timeout is used because Foundation regexp work is synchronous
    // and cannot be cancelled safely once started.
    _ = try await Self.captureText(
        history,
        text: String(repeating: "a", count: 4_096),
        observedAt: Date(timeIntervalSinceReferenceDate: 700_050_100),
        source: "com.example.ws17.regexp-redos"
    )

    // 03b §8 + WS17: `(a+)+` — a quantified group whose body contains a
    // quantifier — is rejected BEFORE scanning with
    // `.invalidInput(.invalidRegularExpression)`.
    await #expect(throws: HistoryFailure.invalidInput(.invalidRegularExpression)) {
        try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "(a+)+", mode: .regexp),
            limit: 50
        ))
    }

    // 03b §8 + WS17: a backreference `(a)\1` — any backreference is rejected
    // BEFORE scanning with `.invalidInput(.invalidRegularExpression)`.
    await #expect(throws: HistoryFailure.invalidInput(.invalidRegularExpression)) {
        try await history.browse(HistoryBrowseRequest(
            kind: .search(text: "(a)\\1", mode: .regexp),
            limit: 50
        ))
    }

    // A quantified group containing alternation is conservatively rejected
    // even when its branches contain no inner quantifier. Both patterns have
    // overlapping prefixes and would otherwise scan the long all-`a` row.
    for pattern in [
        "(a|a)+b",
        "(a|ab)+c",
        "([[:alpha:]]+)+",
        "([[a-z][A-Z]]+)+",
        "([\\Q[\\E]+)+",
        "(?x)# [\n(a+)+",
        "(?ix-s:# [\n(a+)+)",
    ] {
        await #expect(throws: HistoryFailure.invalidInput(.invalidRegularExpression)) {
            try await history.browse(HistoryBrowseRequest(
                kind: .search(text: pattern, mode: .regexp),
                limit: 50
            ))
        }
    }
}

// MARK: - FUZZY mode

/// WS17 + 03b §8 (fuzzy): a typo'd term matches the pinned item first
/// (pinned-first regardless of score); unpinned rows are ordered by score
/// then recency then ID. Fuse 1.4.0's bitap uses one 64-bit `Int`, so queries
/// through 64 Characters are admitted and every longer query throws
/// `.invalidInput(.invalidSearchTerm)` before Fuse is called. Scores are
/// internal — the test asserts ORDER, not exact scores.
@Test func fuzzyModePinnedFirstScoreOrderAndBitapWidthBoundary() async throws {
    let storeURL = WSSupport.tempStoreURL("ws17-fuzzy")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let fixture = try await Self.populateFixture(history)

    // 03b §8 + WS17: a typo'd term "alpa" matches the pinned "Alpha Project
    // Notes" item first (pinned-first regardless of score), and also matches
    // the unpinned "beta alpha mix" title.
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "alpa", mode: .fuzzy),
        limit: 50
    ))
    // The pinned alpha item must be first; unpinned matches follow.
    #expect(
        !page.rows.isEmpty,
        "WS17/03b §8 (fuzzy): 'alpa' matches at least the pinned alpha item"
    )
    let firstRow = try #require(page.rows.first)
    #expect(
        firstRow.item.id == fixture.alphaID,
        "WS17/03b §8 (fuzzy): the pinned item is first regardless of score"
    )
    let firstSearch = try #require(firstRow.search)
    #expect(
        firstSearch.snippet == nil,
        "WS17/03b §8 (fuzzy): a title match has snippet == nil"
    )
    // 03b §8: matchedRanges are UTF-16 offsets into HistoryRow.title for a
    // title match.
    #expect(
        !firstSearch.matchedRanges.isEmpty,
        "WS17/03b §8 (fuzzy): a fuzzy title match carries matchedRanges"
    )

    // 03b §8 + WS17: among the unpinned rows, the score-then-recency-then-ID
    // tie-breaker applies. The gamma item's body and the image item's empty
    // body do not match "alpa" well enough to appear, so if a second row
    // exists it is beta-alpha. The test asserts the ORDER without asserting
    // exact Fuse scores (03b §8: "Search scores … remain internal").
    if page.rows.count >= 2 {
        let secondRow = page.rows[1]
        #expect(
            secondRow.item.id == fixture.betaAlphaID,
            "WS17/03b §8 (fuzzy): the unpinned beta-alpha follows the pinned alpha"
        )
    }

    // 03b §8 + WS17: 64 Characters is the largest pattern Fuse 1.4.0's
    // single-Int bitap can represent. These boundary queries must reach the
    // matcher without an admission failure (whether they match is irrelevant).
    for length in [1, 63, 64] {
        _ = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: String(repeating: "q", count: length), mode: .fuzzy),
            limit: 50
        ))
    }

    // 03b §8 + WS17: every pattern beyond the 64-bit ceiling is rejected
    // BEFORE Fuse is called. The sweep pins both historical failure windows:
    // 65...89 silently returned no matches, while 90+ could overflow inside
    // Fuse and trap the process. The no-substring inputs ensure no early row
    // match can mask the engine boundary.
    for length in [65, 89, 90, 100, 200, 256] {
        let overLengthQuery = String(repeating: "q", count: length)
        await #expect(throws: HistoryFailure.invalidInput(.invalidSearchTerm)) {
            try await history.browse(HistoryBrowseRequest(
                kind: .search(text: overLengthQuery, mode: .fuzzy),
                limit: 50
            ))
        }
    }
}

/// WS17 + 03b §8 (fuzzy): U+0130 lowercases to two Unicode scalars but one
/// extended grapheme cluster. Fuse searches its lowercased working copy, so
/// the alignment guard must preserve the original title's Character offsets;
/// the returned public range is UTF-16-relative to the original U+0130 text.
/// This pins the real behavior (aligned match), rather than incorrectly
/// treating the scalar expansion as a Character-count shift.
@Test func fuzzyModeU0130ExpansionKeepsOriginalUTF16Offsets() async throws {
    let storeURL = WSSupport.tempStoreURL("ws17-fuzzy-u0130")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    let title = "\u{0130}stanbul"
    #expect(title.lowercased().unicodeScalars.count == title.unicodeScalars.count + 1)
    #expect(title.lowercased().count == title.count)
    let reference = try await Self.captureText(
        history,
        text: title,
        observedAt: Date(timeIntervalSinceReferenceDate: 700_050_100),
        source: "com.example.ws17.u0130"
    )

    let page = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "\u{0130}", mode: .fuzzy),
        limit: 50
    ))
    let row = try #require(page.rows.first)
    #expect(row.item.id == reference.id)
    let search = try #require(row.search)
    #expect(search.snippet == nil)
    let range = try #require(search.matchedRanges.first)
    #expect(Self.substring(row.title, utf16Range: range) == "\u{0130}")
}

// MARK: - Shared search-term admission

/// Part VI §2's 4,096-byte search-term bound applies at the shared
/// `SearchWorker.page` entry, before regexp/fuzzy Character-specific admission.
/// A deliberately wide extended grapheme cluster makes the byte boundary
/// independent from Character count: both fixtures contain exactly 64
/// Characters, so regexp's 512-Character and fuzzy's 64-Character bounds admit
/// them. Every mode therefore observes the same public byte-limit failure.
@Test func allSearchModesEnforceUTF8ByteBoundBeforeModeSpecificAdmission() async throws {
    let storeURL = WSSupport.tempStoreURL("ws17-search-term-bytes")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)

    // `a` (one UTF-8 byte) plus twenty-one U+20D0 combining marks (three bytes
    // each) is one Character and exactly 64 UTF-8 bytes.
    let boundaryCluster = "a" + String(repeating: "\u{20D0}", count: 21)
    let justOverCluster = "a"
        + String(repeating: "\u{20D0}", count: 20)
        + String(repeating: "\u{0301}", count: 2)
    let boundaryTerm = String(repeating: boundaryCluster, count: 64)
    let overBoundTerm = String(repeating: boundaryCluster, count: 63)
        + justOverCluster

    #expect(boundaryCluster.count == 1)
    #expect(boundaryTerm.count == 64)
    #expect(boundaryTerm.utf8.count == 4_096)
    #expect(overBoundTerm.count == 64)
    #expect(overBoundTerm.utf8.count == 4_097)

    for mode in [SearchMode.exact, .regexp, .fuzzy] {
        // Equality is admitted. The empty corpus makes the result irrelevant;
        // successful return is the observable boundary contract.
        _ = try await history.browse(HistoryBrowseRequest(
            kind: .search(text: boundaryTerm, mode: mode),
            limit: 50
        ))

        await #expect(throws: HistoryFailure.invalidInput(.invalidSearchTerm)) {
            try await history.browse(HistoryBrowseRequest(
                kind: .search(text: overBoundTerm, mode: mode),
                limit: 50
            ))
        }
    }

    // An ASCII regexp over its 512-Character limit but below 4,096 UTF-8 bytes
    // reaches the mode-specific guard after passing the shared byte guard.
    await #expect(throws: HistoryFailure.invalidInput(.invalidRegularExpression)) {
        try await history.browse(HistoryBrowseRequest(
            kind: .search(text: String(repeating: "a", count: 513), mode: .regexp),
            limit: 50
        ))
    }
}

// MARK: - Empty term recent-equivalent

/// WS17 + 03b §8: an empty term `.search(text: "", mode: .exact)` is
/// equivalent to `.recent` and carries no search presentation: the default
/// total order (pinned by pinOrdinal ascending, then unpinned by lastCopiedAt
/// descending), `search == nil` on every row.
@Test func emptyTermReturnsRecentEquivalentWithNilSearchOnEveryRow() async throws {
    let storeURL = WSSupport.tempStoreURL("ws17-empty")
    defer { WSSupport.removeStore(storeURL) }
    let history = try await WSSupport.openHistory(storeURL: storeURL)
    let fixture = try await Self.populateFixture(history)

    // 03b §8 + WS17: an empty term is equivalent to `.recent`.
    let page = try await history.browse(HistoryBrowseRequest(
        kind: .search(text: "", mode: .exact),
        limit: 50
    ))

    // 03b §8: the default total order — pinned rows first (pinOrdinal
    // ascending), then unpinned (lastCopiedAt descending, ID bytes ascending).
    #expect(
        page.rows.count == 4,
        "WS17/03b §8 (empty): all four items returned in default order"
    )
    // The pinned alpha item is first.
    let firstRow = try #require(page.rows.first)
    #expect(
        firstRow.item.id == fixture.alphaID,
        "WS17/03b §8 (empty): the pinned item leads the default order"
    )
    #expect(
        firstRow.pinnedPosition == 0,
        "WS17/03b §8 (empty): the pinned item is at pinnedPosition 0"
    )
    // Then unpinned by lastCopiedAt descending: beta-alpha (700_049_900),
    // gamma (700_049_800), image (700_049_700).
    #expect(page.rows[1].item.id == fixture.betaAlphaID)
    #expect(page.rows[2].item.id == fixture.gammaID)
    #expect(page.rows[3].item.id == fixture.imageID)

    // 03b §8: `search == nil` on every row (no search presentation).
    for row in page.rows {
        #expect(
            row.search == nil,
            "WS17/03b §8 (empty): every row carries search == nil"
        )
    }
}
}
