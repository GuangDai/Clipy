/// A raw Unicode query edit must replace results and their UTF-16 highlights,
/// even when Swift String equality considers the two spellings equivalent.
/// This drives the real storage matcher through the presentation lifecycle.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

@MainActor
struct UnicodeSearchIntentTests {
    @Test(arguments: [SearchMode.exact, .regexp])
    func canonicallyEquivalentQueryEditsRefreshLiteralHighlights(mode: SearchMode) async throws {
        let history = try await SwiftDataHistory.open(
            configuration: HistoryConfiguration(persistence: .memory)
        )
        let composed = "é"
        let decomposed = "e\u{301}"
        let title = composed + " first " + decomposed + " second"
        _ = try await history.perform(.capture(ClipboardCapture(
            representations: [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text", bytes: Data(title.utf8)
            )],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_050_000)
        )))
        let state = HistoryViewState(history: history)
        state.searchMode = mode
        state.searchText = composed
        state.activate()
        defer { state.deactivate() }

        let firstMatch = [UTF16TextRange(location: 0, length: 1)]
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.first?.search?.matchedRanges == firstMatch
        })
        #expect(state.rows.count == 1)
        #expect(state.rows.first?.search?.snippet == nil)

        // The actual control value changes even though composed == decomposed
        // under canonical-equivalence equality. Invalidation must be immediate,
        // before the debounce and the replacement observation finish.
        state.searchText = decomposed
        #expect(Data(state.searchText.utf8) == Data(decomposed.utf8))
        #expect(state.rows.isEmpty)
        #expect(state.isLoadingFirstPage)
        #expect(!state.hasAuthoritativeFirstPage)

        let secondMatch = [UTF16TextRange(location: 8, length: 2)]
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.first?.search?.matchedRanges == secondMatch
        })
        let row = try #require(state.rows.first)
        #expect(Data(row.title.utf8) == Data(title.utf8))
        #expect(row.search?.snippet == nil)
        #expect(state.failure == nil)

        // A byte-identical assignment still leaves the settled observation
        // and its rows intact; the change does not make every setter a query.
        state.searchText = String(decoding: Array(decomposed.utf8), as: UTF8.self)
        #expect(state.rows == [row])
        #expect(state.hasAuthoritativeFirstPage)
        #expect(!state.isLoadingFirstPage)

        state.searchText = composed
        #expect(state.rows.isEmpty)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.first?.search?.matchedRanges == firstMatch
        })
    }
}
