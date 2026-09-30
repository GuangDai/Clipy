/// Real SQLite observations through HistoryViewState: final-query body
/// search, authoritative refresh, and repeated activation/deactivation.
import Foundation
import HistoryCore
import HistoryStorage
@testable import ClipyApp
import Testing

@Suite(.serialized)
struct HistoryObservationLifecycleTests {
    /// A rapid sequence of edits settles on a phrase inside a large stored
    /// search body. The returned UTF-16 ranges must select that phrase, and
    /// refresh must retire the old page before publishing its replacement.
    @Test(
        .enabled(
            if: FixtureCatalog.available,
            "requires the clipy-fixtures-v1 tree (CLIPY_FIXTURES_DIR)"
        )
    )
    @MainActor
    func searchDebounceStormSettlesOnTheFinalQuery() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }

        let bodyText = try FixtureCatalog.text("text/searchbody-300kb.txt")
        try #require(bodyText.count > 120_100, "The fixture must contain the mid-body phrase")
        let windowStart = bodyText.index(bodyText.startIndex, offsetBy: 120_000)
        let windowEnd = bodyText.index(windowStart, offsetBy: 48)
        let phrase = String(bodyText[windowStart..<windowEnd])

        let base = Date(timeIntervalSinceReferenceDate: 700_203_100)
        let fixtureReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                bodyText,
                observedAt: base,
                source: "com.example.debouncestorm"
            )
        ))
        let fixtureID = try #require(
            ComposedSupport.insertedReference(
                from: fixtureReceipt, "debounce storm fixture seed"
            )
        ).id
        for index in 0..<3 {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "debounce storm filler zzz \(index)",
                    observedAt: base.addingTimeInterval(Double(index + 1)),
                    source: "com.example.debouncestorm"
                )
            ))
            _ = try #require(ComposedSupport.insertedReference(
                from: receipt, "debounce storm filler \(index)"
            ))
        }

        viewState.activate()
        try #require(await ComposedSupport.waitFor(timeout: 3) {
            viewState.hasAuthoritativeFirstPage && viewState.rows.count == 4
        }, "The seeded recent page must arrive before the query changes")

        viewState.searchMode = .exact
        // All edits happen in one MainActor turn. The latest query must win
        // when the debounce resumes against the real stored search body.
        for index in 0..<60 {
            viewState.searchText = String(phrase.prefix(index % 48 + 1))
        }
        viewState.searchText = phrase

        try #require(await ComposedSupport.waitFor(timeout: 5) {
            viewState.hasAuthoritativeFirstPage
                && viewState.rows.map(\.item.id) == [fixtureID]
        }, "The settled page must answer the final query")
        try #require(viewState.failure == nil)

        let row = try #require(viewState.rows.first)
        let search = try #require(row.search)
        let snippet = try #require(search.snippet, "The phrase must match the stored body")
        try #require(!search.matchedRanges.isEmpty)
        let utf16Count = snippet.utf16.count
        for range in search.matchedRanges {
            try #require(range.location >= 0 && range.location <= utf16Count)
            try #require(range.length >= 0 && range.length <= utf16Count - range.location)
            #expect(
                ComposedSupport.substring(snippet, utf16Range: range).lowercased()
                    == phrase.lowercased(),
                "Every UTF-16 range must select the matched phrase"
            )
        }

        let settledIDs = viewState.rows.map(\.item.id)
        viewState.refresh()
        try #require(!viewState.hasAuthoritativeFirstPage)
        #expect(viewState.rows.isEmpty)
        try #require(await ComposedSupport.waitFor(timeout: 5) {
            viewState.hasAuthoritativeFirstPage
                && viewState.rows.map(\.item.id) == settledIDs
        }, "Refresh must publish an authoritative replacement for the same query")
        #expect(viewState.failure == nil)
    }

    /// Each activation can switch query shape and converge against real
    /// storage. After deactivation, a later commit must not repopulate rows.
    /// Storage owner tests separately prove producer cancellation and its
    /// publication fence with deterministic interleavings.
    @Test @MainActor
    func activateDeactivateCyclesRetireDisplayedRows() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history)
        defer { viewState.deactivate() }
        viewState.searchMode = .exact

        let base = Date(timeIntervalSinceReferenceDate: 700_203_300)
        var needleIDs: [HistoryItemID] = []
        for index in 0..<3 {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "hygiene needle \(index)",
                    observedAt: base.addingTimeInterval(Double(index)),
                    source: "com.example.cancellationhygiene"
                )
            ))
            needleIDs.append(try #require(ComposedSupport.insertedReference(
                from: receipt, "hygiene needle seed \(index)"
            )).id)
        }
        for index in 0..<3 {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "hygiene filler \(index)",
                    observedAt: base.addingTimeInterval(100 + Double(index)),
                    source: "com.example.cancellationhygiene"
                )
            ))
            _ = try #require(ComposedSupport.insertedReference(
                from: receipt, "hygiene filler seed \(index)"
            ))
        }

        for cycle in 0..<10 {
            let searching = cycle.isMultiple(of: 2)
            viewState.activate()
            viewState.searchText = searching ? "hygiene needle" : ""
            try #require(await ComposedSupport.waitFor(timeout: 3) {
                viewState.hasAuthoritativeFirstPage && (
                    searching
                        ? Set(viewState.rows.map(\.item.id)) == Set(needleIDs)
                        : viewState.rows.count == 6
                )
            }, "Activation cycle \(cycle) must converge before deactivation")
            try #require(viewState.failure == nil)
            viewState.deactivate()
            try #require(viewState.rows.isEmpty)
            try #require(!viewState.hasAuthoritativeFirstPage)
        }

        let receipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "hygiene late commit",
                observedAt: base.addingTimeInterval(200),
                source: "com.example.cancellationhygiene"
            )
        ))
        _ = try #require(ComposedSupport.insertedReference(from: receipt, "hygiene late commit"))

        // Keep the existing bounded absence check; it observes displayed
        // state, without claiming to count live storage producers or memory.
        let windowEnd = Date().addingTimeInterval(0.5)
        while Date() < windowEnd {
            try #require(viewState.rows.isEmpty)
            try #require(!viewState.hasAuthoritativeFirstPage)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewState.rows.isEmpty)
        #expect(!viewState.hasAuthoritativeFirstPage)
        #expect(viewState.failure == nil)
    }
}
