/// WS17Composed — Search modes through the composed panel surface
/// (docs/06-cross-cutting.md §8 WS17; docs/03b-instruction-set.md §8):
/// the frozen search behavior driven by the REAL `HistoryViewState` —
/// `searchText` + `searchMode` restart observation into the
/// `.search(text:mode:)` query shape (03a §7), and the observed rows carry
/// `SearchPresentation` whose `matchedRanges` are UTF-16 offsets that
/// index correctly into `title` (title match, `snippet == nil`) or into
/// `snippet` (body match). Exact, fuzzy, and regexp shapes are each
/// exercised; the exhaustive admission-failure battery (regexp rejection
/// table, 4,096-byte envelope, 64-Character fuzzy fence) is fixture-locked
/// in `Tests/HistoryStorageTests/WS17*Tests.swift` and not duplicated.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS17ComposedSearchModesTests {

    /// The shared composed fixture (mirroring the storage-side WS17 shape):
    /// a PINNED "Alpha Project Notes" row, an unpinned "beta alpha mix"
    /// row, and a multi-line row whose title misses but whose body
    /// matches. Observation times are monotone so unpinned order is
    /// deterministic.
    @MainActor
    private static func populate(
        _ history: SwiftDataHistory
    ) async throws -> (alpha: HistoryItemID, betaAlpha: HistoryItemID, body: HistoryItemID) {
        let base = Date(timeIntervalSinceReferenceDate: 700_202_300)
        let alphaReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "Alpha Project Notes",
                observedAt: base,
                source: "com.example.ws17composed.alpha"
            )
        ))
        let alpha = try #require(
            ComposedSupport.insertedReference(from: alphaReceipt, "WS17 fixture alpha")
        ).id
        _ = try await history.perform(.placePinned(alpha, at: .last))

        let betaReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "beta alpha mix",
                observedAt: base.addingTimeInterval(100),
                source: "com.example.ws17composed.beta"
            )
        ))
        let betaAlpha = try #require(
            ComposedSupport.insertedReference(from: betaReceipt, "WS17 fixture beta")
        ).id

        let bodyReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "gamma header\nsecond line\nneedle detail here",
                observedAt: base.addingTimeInterval(200),
                source: "com.example.ws17composed.body"
            )
        ))
        let body = try #require(
            ComposedSupport.insertedReference(from: bodyReceipt, "WS17 fixture body")
        ).id

        return (alpha, betaAlpha, body)
    }

    /// WS17 exact shape (03b §8): case-insensitive literal substring, title
    /// matches carry `snippet == nil` with UTF-16 ranges into `title`,
    /// pinned-first ordering, and a BODY match carries a snippet whose
    /// ranges index into the SNIPPET — all observed through the debounced
    /// panel.
    @Test @MainActor
    func exactSearchThroughViewStateSeparatesTitleAndBodyMatches() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let ids = try await Self.populate(history)

        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()
        viewState.searchMode = .exact
        viewState.searchText = "alpha"

        // "alpha" matches the two TITLE rows (case-insensitive: "Alpha" and
        // "alpha"); the third row's body carries no "alpha", so exactly two
        // rows, pinned-first (03b §8).
        let titleMatches = await ComposedSupport.waitFor(timeout: 3) {
            viewState.rows.map(\.item.id) == [ids.alpha, ids.betaAlpha]
        }
        #expect(
            titleMatches,
            "WS17 exact: both title matches, pinned first, no body false-positive"
        )
        for row in viewState.rows {
            #expect(row.search?.snippet == nil, "WS17 exact: a title match has no snippet")
            for range in row.search?.matchedRanges ?? [] {
                #expect(
                    ComposedSupport.substring(row.title, utf16Range: range)
                        .lowercased() == "alpha",
                    "WS17 (03b §8): title ranges index the matched substring"
                )
            }
        }

        // "needle" appears ONLY in the third row's body: a body match
        // carries a snippet, and its ranges index into the SNIPPET.
        viewState.searchText = "needle"
        let bodyMatch = await ComposedSupport.waitFor(timeout: 3) {
            viewState.rows.count == 1 && viewState.rows.first?.item.id == ids.body
        }
        #expect(bodyMatch, "WS17 exact: the body-only match surfaces alone")
        let bodyRow = try #require(viewState.rows.first)
        let snippet = try #require(bodyRow.search?.snippet)
        #expect(snippet.contains("needle"))
        for range in bodyRow.search?.matchedRanges ?? [] {
            #expect(
                ComposedSupport.substring(snippet, utf16Range: range).lowercased() == "needle",
                "WS17 (03b §8): snippet ranges index into the snippet excerpt"
            )
        }
        #expect(viewState.failure == nil)
    }

    /// WS17 fuzzy shape (03b §8; Fuse 1.4.0): a typo'd query still matches
    /// the pinned title row FIRST regardless of score, and the next row is
    /// the beta-alpha title. Asserted with the storage suite's calibration
    /// (scores stay internal). Unlike the storage fixture's gamma body, the
    /// composed corpus's multi-line body row DOES fuzzy-match "alpa"
    /// (score 0.51, inside the frozen 0.7 threshold) — it ranks AFTER
    /// beta-alpha by ascending score (03b §8), so only rows[0]/rows[1] are
    /// pinned here.
    @Test @MainActor
    func fuzzySearchThroughViewStateMatchesTypoQueriesPinnedFirst() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let ids = try await Self.populate(history)

        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()
        viewState.searchText = "alpa" // typo'd "alpha" — the fuzzy shape

        // The pinned alpha row leads the RECENT default order too (05
        // §14.1), so a bare first-row check would be satisfied by the
        // pre-debounce recent page (whose rows carry `search == nil`).
        // Wait for the SEARCH-shaped page: every row of a non-empty-term
        // search page carries its SearchPresentation (03b §8).
        let settled = await ComposedSupport.waitFor(timeout: 3) {
            viewState.rows.first?.item.id == ids.alpha
                && viewState.rows.allSatisfy { $0.search != nil }
        }
        #expect(
            settled,
            "WS17 fuzzy: the typo still matches, pinned-first regardless of score"
        )
        let firstRow = try #require(viewState.rows.first)
        #expect(
            firstRow.search?.snippet == nil,
            "WS17 fuzzy: a title match carries no snippet"
        )
        #expect(
            !(firstRow.search?.matchedRanges.isEmpty ?? true),
            "WS17 fuzzy: a fuzzy title match carries matchedRanges"
        )
        if viewState.rows.count >= 2 {
            #expect(
                viewState.rows[1].item.id == ids.betaAlpha,
                "WS17 fuzzy: the unpinned beta-alpha title follows"
            )
        }
        #expect(viewState.failure == nil)
    }

    /// WS17 regexp shape (03b §8; NSRegularExpression): an anchored
    /// alternation matches exactly the two expected rows; an invalid
    /// pattern surfaces the typed
    /// `.invalidInput(.invalidRegularExpression)` in the panel banner.
    @Test @MainActor
    func regexpSearchThroughViewStateRanksAndSurfacesInvalidPatterns() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let ids = try await Self.populate(history)

        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.activate()
        viewState.searchMode = .regexp
        viewState.searchText = "^(Alpha|beta)"

        let settled = await ComposedSupport.waitFor(timeout: 3) {
            Set(viewState.rows.map(\.item.id)) == Set([ids.alpha, ids.betaAlpha])
        }
        #expect(
            settled,
            "WS17 regexp: the anchored alternation matches the two expected rows"
        )
        #expect(viewState.rows.first?.item.id == ids.alpha, "WS17 regexp: pinned-first holds")

        // An invalid pattern (unclosed group) fails closed before scanning
        // (03b §8) and the composed banner renders the failure vocabulary.
        viewState.searchText = "(unclosed"
        #expect(
            await ComposedSupport.waitFor {
                viewState.failure == .invalidInput(.invalidRegularExpression)
            },
            "WS17 regexp: the invalid pattern surfaces the typed failure"
        )
        let bannerFailure = try #require(viewState.failure)
        let bannerMessage = FailurePresentation.message(for: bannerFailure)
        #expect(
            bannerMessage == FailurePresentation.message(
                for: .invalidInput(.invalidRegularExpression)
            )
        )
        #expect(!bannerMessage.contains(viewState.searchText))
    }
}
