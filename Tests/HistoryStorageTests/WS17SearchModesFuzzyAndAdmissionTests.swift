/// WS17 fuzzy mode, shared search-term admission, and the empty-term recent-equivalent clause.
/// Split out of WS17SearchModesTests.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryDomain
import Testing
@testable import HistoryStorage

extension WS17SearchModesTests {
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
