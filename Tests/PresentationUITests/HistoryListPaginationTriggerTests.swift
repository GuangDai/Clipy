/// Card 8B: row appearance drives the real view-state pagination owner,
/// including when a filter hides the last authoritative row. These tests
/// observe browse requests and appended rows rather than repeat a Boolean
/// predicate with precomputed last-row identities.
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct HistoryListPaginationTriggerTests {
    @Test func allPinnedPagePrefetchesOnlyOnceFromItsLastRow() async throws {
        let first = row(1, pinned: 0)
        let last = row(2, pinned: 1)
        let continuation = row(3)
        let cursor = fixtureCursor("after-pinned")
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [first, last], next: "after-pinned"),
            browseScript: [cursor: .paused(fixturePage(rows: [continuation], next: nil))]
        )
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })

        state.prefetchNextPageIfNeeded(appearingRowID: first.item.id)
        #expect(!state.isLoadingPage)
        state.prefetchNextPageIfNeeded(appearingRowID: last.item.id)
        try #require(await pollUntil { await history.isBrowsePaused(after: cursor) })
        state.prefetchNextPageIfNeeded(appearingRowID: last.item.id)
        await history.resumeBrowse(after: cursor)
        try #require(await pollUntil { !state.isLoadingPage })

        #expect(await history.browseRequests.count == 1)
        #expect(state.rows == [first, last, continuation])
        #expect(!state.hasNextPage)
        state.prefetchNextPageIfNeeded(appearingRowID: continuation.item.id)
        #expect(!state.isLoadingPage)
        #expect(await history.browseRequests.count == 1)
    }

    @Test(arguments: [false, true])
    func hiddenLastRowDoesNotStrandPagination(pinnedOnly: Bool) async throws {
        let visible = row(4, pinned: 0)
        let hidden = row(5, type: "public.png")
        let continuation = row(6)
        let cursor = fixtureCursor("after-filtered")
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [visible, hidden], next: "after-filtered"),
            browseScript: [cursor: .page(fixturePage(rows: [continuation], next: nil))]
        )
        let state = HistoryViewState(history: history)
        state.typeFilter = pinnedOnly ? .all : .text
        state.showsPinnedOnly = pinnedOnly
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.displayedPinnedRows == [visible])
        #expect(state.displayedUnpinnedRows.isEmpty)

        state.prefetchNextPageIfNeeded(appearingRowID: hidden.item.id)
        #expect(!state.isLoadingPage)
        state.prefetchNextPageIfNeeded(appearingRowID: visible.item.id)
        try #require(await pollUntil { state.rows.count == 3 && !state.isLoadingPage })
        #expect(await history.browseRequests.count == 1)
        #expect(!state.hasNextPage)
    }

    @Test func emptyFilteredPageCanContinueUntilAMatchingRowArrives() async throws {
        let hidden = row(7, type: "public.png")
        let alsoHidden = row(8, type: "public.url")
        let visible = row(9)
        let firstCursor = fixtureCursor("hidden-page")
        let secondCursor = fixtureCursor("matching-page")
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [hidden], next: "hidden-page"),
            browseScript: [
                firstCursor: .page(fixturePage(rows: [alsoHidden], next: "matching-page")),
                secondCursor: .page(fixturePage(rows: [visible], next: nil)),
            ]
        )
        let state = HistoryViewState(history: history)
        state.typeFilter = .text
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.displayedUnpinnedRows.isEmpty)
        #expect(state.hasNextPage)

        // Same entry point as the visible Load More control. A page with
        // no matching rows preserves the cursor for another explicit load.
        state.loadNextPage()
        try #require(await pollUntil { state.rows.count == 2 && !state.isLoadingPage })
        #expect(state.displayedUnpinnedRows.isEmpty)
        #expect(state.hasNextPage)
        state.loadNextPage()
        try #require(await pollUntil { state.rows.count == 3 && !state.isLoadingPage })
        #expect(state.displayedUnpinnedRows == [visible])
        #expect(!state.hasNextPage)
        #expect(await history.observeRequests.count == 1)
        #expect(await history.browseRequests.count == 2)
    }

    private func row(
        _ index: Int,
        type: String = "public.utf8-plain-text",
        pinned: Int? = nil
    ) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: HistoryItemID(rawValue: UUID()),
                contentVersion: ContentVersion(rawValue: 1)
            ),
            title: "pagination \(index)",
            typeIdentifiers: [type],
            lastCopiedAt: Date(timeIntervalSince1970: 1_787_000_000),
            copyCount: 1,
            lastSource: nil,
            pinnedPosition: pinned,
            search: nil
        )
    }
}
