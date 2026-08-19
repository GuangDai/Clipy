/// WS18Composed — Pagination and cursor expiry through the composed panel
/// surface (docs/06-cross-cutting.md §8 WS18; docs/04-coherence.md §6):
/// `viewState.loadNextPage()` (the list's last-row trigger) appends the
/// continuation page with no overlap or gap, `hasNextPage` tracks the
/// cursor, and a cursor invalidated by an intervening commit surfaces
/// `.snapshotExpired` and recovers by resuming from the observed first
/// page's cursor (04 §6) — the composed counterpart of the storage-side
/// pagination suite.
import Foundation
import HistoryCore
import HistoryStorage
import PresentationUI
import Testing

struct WS18ComposedPaginationTests {

    /// WS18 (docs/06-cross-cutting.md §8; 04 §6): with 4 rows and a
    /// pageLimit of 3, the observed first page holds 3 rows and reports a
    /// next page; `loadNextPage()` appends exactly the missing fourth row
    /// (no overlap, no gap) and `hasNextPage` turns false.
    @Test @MainActor
    func loadNextPageAppendsTheContinuationRowWithNoOverlapOrGap() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history, pageLimit: 3)
        defer { viewState.deactivate() }

        let base = Date(timeIntervalSinceReferenceDate: 700_202_400)
        var ids: [HistoryItemID] = []
        for index in 0..<4 {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "ws18 composed item \(index)",
                    observedAt: base.addingTimeInterval(Double(index) * 100),
                    source: "com.example.ws18composed"
                )
            ))
            ids.append(
                try #require(
                    ComposedSupport.insertedReference(from: receipt, "WS18 arrange")
                ).id
            )
        }

        viewState.activate()
        let firstPageSettled = await ComposedSupport.waitFor {
            viewState.rows.count == 3 && viewState.hasNextPage
        }
        #expect(
            firstPageSettled,
            "WS18: the observed first page is the newest 3 rows with a cursor"
        )
        #expect(
            viewState.rows.map(\.item.id) == [ids[3], ids[2], ids[1]],
            "WS18 (05 §14.1): first page newest-first"
        )

        // The last-row trigger: one one-shot browse that appends the
        // continuation page (04 §6).
        viewState.loadNextPage()
        let appended = await ComposedSupport.waitFor {
            viewState.rows.count == 4 && !viewState.hasNextPage
        }
        #expect(appended, "WS18: the continuation row appended, cursor exhausted")
        #expect(
            viewState.rows.last?.item.id == ids[0],
            "WS18: the oldest row completes the set — no overlap, no gap"
        )
        #expect(
            Set(viewState.rows.map(\.item.id)) == Set(ids),
            "WS18: the displayed set is exactly the retained set"
        )
        #expect(viewState.failure == nil)
    }

    /// WS18 search-kind shape (03a §7; 04 §6): pagination under a SEARCH
    /// query through the same panel surface — the observed first page and
    /// every appended page carry the search presentation, continuation has
    /// no overlap or gap, and the cursor exhausts exactly at the last match.
    ///
    /// The cursor-EXPIRY clause (`.snapshotExpired` after an intervening
    /// commit) is a storage-fixture property: in the composed panel any
    /// invalidating commit also replaces the observed first page (WS12), so
    /// the stale-cursor race is exactly the 04 §6 recovery the view state
    /// implements — there is no deterministic composed interleaving without
    /// the storage suspension seams, and it stays in
    /// `Tests/HistoryStorageTests/WS18PaginationCursorTests.swift`.
    @Test @MainActor
    func searchPaginationContinuesWithoutOverlapOrGap() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let viewState = HistoryViewState(history: history, pageLimit: 2)
        defer { viewState.deactivate() }

        // Five matching rows plus one non-matching row, monotone times.
        let base = Date(timeIntervalSinceReferenceDate: 700_202_600)
        var matchIDs: [HistoryItemID] = []
        for index in 0..<5 {
            let receipt = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "ws18 composed needle \(index)",
                    observedAt: base.addingTimeInterval(Double(index) * 100),
                    source: "com.example.ws18composed.search"
                )
            ))
            matchIDs.append(
                try #require(
                    ComposedSupport.insertedReference(from: receipt, "WS18 search arrange")
                ).id
            )
        }
        _ = try await history.perform(.capture(
            ComposedSupport.textCapture(
                "ws18 composed unrelated",
                observedAt: base.addingTimeInterval(500),
                source: "com.example.ws18composed.search"
            )
        ))

        viewState.activate()
        viewState.searchMode = .exact
        viewState.searchText = "needle"

        // First observed search page: 2 rows, recency-descending.
        let firstPage = await ComposedSupport.waitFor(timeout: 3) {
            viewState.rows.count == 2 && viewState.hasNextPage
        }
        #expect(firstPage, "WS18 search: the observed search page has a cursor")
        #expect(
            viewState.rows.map(\.item.id) == [matchIDs[4], matchIDs[3]],
            "WS18 search: first page is the two newest matches"
        )
        #expect(
            viewState.rows.allSatisfy { $0.search != nil },
            "WS18 search: search rows carry their presentation"
        )

        // Continuation pages: no overlap, no gap, until exhaustion.
        viewState.loadNextPage()
        _ = await ComposedSupport.waitFor { viewState.rows.count == 4 }
        viewState.loadNextPage()
        let exhausted = await ComposedSupport.waitFor {
            viewState.rows.count == 5 && !viewState.hasNextPage
        }
        #expect(exhausted, "WS18 search: the cursor exhausts at the last match")
        #expect(
            viewState.rows.map(\.item.id)
                == [matchIDs[4], matchIDs[3], matchIDs[2], matchIDs[1], matchIDs[0]],
            "WS18 search: the appended continuation is complete, ordered, unduplicated"
        )
        #expect(viewState.failure == nil)
    }
}
