import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

@MainActor
struct HistoryViewStateWindowTests {
    private func fixture(
        rowCount: Int = 16,
        pausedPage: Int? = nil,
        newerOutcome: ScriptedHistory.BrowseOutcome? = nil,
        repeatsObservedFirstPage: Bool = true
    ) -> (ScriptedHistory, [HistoryRow]) {
        let rows = (1...rowCount).map { index in
            fixtureRow(
                id: "00000000-0000-0000-0000-" + String(format: "%012d", index),
                title: "row \(index)"
            )
        }
        let pageCount = (rowCount + 1) / 2
        let pages = (0..<pageCount).map { index in
            HistoryPage(
                position: ChangePosition(rawValue: 1),
                rows: Array(rows[(index * 2)..<min(index * 2 + 2, rowCount)]),
                previous: index > 0 ? fixtureCursor("newer-\(index - 1)") : nil,
                next: index + 1 < pageCount ? fixtureCursor("page-\(index + 1)") : nil
            )
        }
        var script: [HistoryPageCursor: ScriptedHistory.BrowseOutcome] = [:]
        for index in pages.indices {
            script[fixtureCursor("page-\(index)")] = index == pausedPage
                ? .paused(pages[index]) : .page(pages[index])
            script[fixtureCursor("newer-\(index)")] = newerOutcome ?? .page(pages[index])
        }
        return (ScriptedHistory(
            observedFirstPage: pages[0],
            repeatsObservedFirstPage: repeatsObservedFirstPage,
            browseScript: script
        ), rows)
    }

    @Test(arguments: [15, 16, 127], [false, true])
    func olderAndNewerRoundTripsKeepThreePagesAndExactTailCounts(
        rowCount: Int, searching: Bool
    ) async throws {
        let (history, allRows) = fixture(rowCount: rowCount)
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.typeFilter = .text
        if searching {
            state.searchMode = .exact
            state.searchText = "row "
        }
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        let pageCount = (rowCount + 1) / 2
        for page in 1..<pageCount {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
            let end = min((page + 1) * 2, rowCount)
            #expect(state.rows == Array(allRows[(max(0, page - 2) * 2)..<end]))
            #expect(state.rows.count <= 6)
            #expect(state.loadedPageCount == min(page + 1, 3))
            #expect(state.traversedRowCount == end)
            #expect(await history.browseRequests.last?.cursor == fixtureCursor("page-\(page)"))
        }
        #expect(state.hasPreviousPage)
        #expect(!state.hasNextPage)
        #expect(state.displayedCount == rowCount)
        #expect(!state.displayedCountIsLowerBound)
        #expect(HistoryPanelView.itemCountText(for: state, locale: Locale(identifier: "en_US")) == "\(rowCount) items")
        #expect(SearchHeaderView.resultCountText(for: state, locale: Locale(identifier: "en_US")) == "\(rowCount) results")
        for firstPage in stride(from: pageCount - 4, through: 0, by: -1) {
            state.loadPreviousPage()
            try #require(await pollUntil { !state.isLoadingPage })
            #expect(state.rows == Array(allRows[(firstPage * 2)..<((firstPage + 3) * 2)]))
            #expect(state.hasNextPage)
            #expect(state.rows.count == 6)
            #expect(state.loadedPageCount == 3)
            #expect(state.displayedCount == (firstPage + 3) * 2)
            #expect(state.displayedCountIsLowerBound)
            #expect(await history.browseRequests.last?.cursor == fixtureCursor("newer-\(firstPage)"))
        }
        #expect(!state.hasPreviousPage)
        #expect(state.hasWindowedPages, "Returning to page one still trimmed the selected tail")
        for page in 3..<pageCount {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
            #expect(state.rows == Array(allRows[((page - 2) * 2)..<min((page + 1) * 2, rowCount)]))
            #expect(state.loadedPageCount == 3)
        }
        #expect(state.displayedCount == rowCount)
        let expectedKind: HistoryBrowseKind = searching ? .search(text: "row ", mode: .exact) : .recent
        #expect(await history.browseRequests.allSatisfy { $0.kind == expectedKind && $0.limit == 2 && $0.filter == HistoryFilter(type: .text) })
        #expect(state.surfacePurge == nil, "DTO eviction is not a History deletion")
        _ = state.acceptCommittedExternalRemoval(allRows[rowCount - 1].item.id)
        #expect(state.displayedCountIsLowerBound,
                "Receipt-purged partial rows cannot become a false exact total before observation")
        state.returnToLatest()
        try #require(await pollUntil { state.rows == Array(allRows.prefix(2)) })
        #expect(!state.hasPreviousPage)
        #expect(!state.hasWindowedPages)
        #expect(state.loadedPageCount == 1)
    }

    @Test func closingReleasesThePageWindowAndReopensTheSameQueryFromPageOne() async throws {
        let (history, allRows) = fixture()
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.searchMode = .exact
        state.searchText = "row "
        state.typeFilter = .text
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        for _ in 1..<8 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
        }
        #expect(state.hasWindowedPages)
        #expect(state.hasPreviousPage)
        let retainedReference = try #require(state.rows.last?.item)
        let requestCount = await history.browseRequests.count
        var pasted: HistoryItemReference?
        state.onPaste = { pasted = $0 }
        state.deactivate()

        #expect(state.rows.isEmpty)
        #expect(!state.hasPreviousPage)
        #expect(!state.hasNextPage)
        #expect(!state.hasWindowedPages)
        #expect(state.loadedPageCount == 0)
        #expect(!state.hasAuthoritativeFirstPage)
        #expect(!state.isLoadingFirstPage)
        #expect(state.traversedRowCount == 0)
        #expect(state.searchText == "row ")
        #expect(state.searchMode == .exact)
        #expect(state.typeFilter == .text)
        state.loadPreviousPage()
        state.loadNextPage()
        state.requestPasteFromDisplayedRow(retainedReference)
        #expect(pasted == nil)
        #expect(await history.browseRequests.count == requestCount)

        state.activate()
        try #require(await pollUntil { state.rows == Array(allRows.prefix(2)) })
        #expect(!state.hasPreviousPage)
        #expect(!state.hasWindowedPages)
        #expect(state.hasNextPage)
        #expect(await history.observeRequests.last?.kind == .search(text: "row ", mode: .exact))
    }

    @Test func fullWindowStopsPrefetchAndRetargetsOnlyTheVisibleSelection() async throws {
        let (history, allRows) = fixture()
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        let surface = HistoryPanelSurfaceState(viewState: state, previewState: PreviewPaneState())
        surface.beginSession(rows: state.rows)
        surface.detailsPath = [allRows[0].item]
        var pasted: HistoryItemReference?
        state.onPaste = { pasted = $0 }
        for _ in 0..<2 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
        }
        let priorRequestCount = await history.browseRequests.count
        state.prefetchNextPageIfNeeded(appearingRowID: allRows[5].item.id)
        #expect(!state.isLoadingPage)
        #expect(await history.browseRequests.count == priorRequestCount)
        state.loadNextPage()
        try #require(await pollUntil { !state.isLoadingPage })
        #expect(surface.detailsPath == [allRows[0].item], "An evicted row remains a retained History item")
        surface.detailsPath = []
        #expect(surface.selectedReference(in: state.rows) == nil)
        state.requestPasteFromDisplayedRow(allRows[0].item)
        #expect(pasted == nil)
        surface.reconcileSessionSelection(rows: state.rows, selectsVisibleWindow: state.hasWindowedPages)
        #expect(surface.selection == allRows[2].item.id)
        let reference = try #require(surface.selectedReference(in: state.rows))
        state.requestPasteFromDisplayedRow(reference)
        #expect(pasted == allRows[2].item)

        // On the trip back to page one, the selected tail is evicted instead
        // of the head. Details remains open and Return retargets visibly.
        surface.selection = allRows[7].item.id
        surface.detailsPath = [allRows[7].item]
        state.loadPreviousPage()
        try #require(await pollUntil { !state.isLoadingPage })
        #expect(state.rows == Array(allRows.prefix(6)))
        #expect(!state.hasPreviousPage)
        #expect(state.hasWindowedPages)
        #expect(surface.detailsPath == [allRows[7].item])
        surface.detailsPath = []
        surface.reconcileSessionSelection(rows: state.rows, selectsVisibleWindow: state.hasWindowedPages)
        #expect(surface.selection == allRows[0].item.id)
        pasted = nil
        state.requestPasteFromDisplayedRow(allRows[7].item)
        #expect(pasted == nil)
        state.requestPasteFromDisplayedRow(try #require(surface.selectedReference(in: state.rows)))
        #expect(pasted == allRows[0].item)
        #expect(state.surfacePurge == nil)
    }

    @Test func observedReplacementRetiresTheWindowAndItsBoundaryCursors() async throws {
        let (history, allRows) = fixture(pausedPage: 5)
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        for _ in 0..<4 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
        }
        #expect(state.hasPreviousPage)
        state.loadNextPage()
        try #require(await pollUntil { await history.isBrowsePaused(cursor: fixtureCursor("page-5")) })
        await history.emitObservedPage(fixturePage(rows: [allRows[0]], next: nil))
        try #require(await pollUntil { state.rows == [allRows[0]] })
        #expect(!state.hasPreviousPage)
        #expect(!state.hasNextPage)
        #expect(!state.hasWindowedPages)
        #expect(state.loadedPageCount == 1)
        #expect(state.traversedRowCount == 1)
        await history.resumeBrowse(cursor: fixtureCursor("page-5"))
        try #require(await pollUntil { await history.completedPausedBrowseCursors.contains(fixtureCursor("page-5")) })
        #expect(state.rows == [allRows[0]])
        #expect(!state.hasPreviousPage)
        #expect(!state.isLoadingPage)
    }

    @Test func expiredNewerCursorRestartsTheSameSearchAtPageOne() async throws {
        let currentPosition = ChangePosition(rawValue: 2)
        let (history, allRows) = fixture(
            newerOutcome: .failure(.snapshotExpired(current: currentPosition)),
            repeatsObservedFirstPage: false
        )
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.searchMode = .exact
        state.searchText = "row "
        state.typeFilter = .text
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil {
            await history.observeRequests.last?.kind == .search(text: "row ", mode: .exact)
        })
        await history.emitObservedPage(HistoryPage(
            position: ChangePosition(rawValue: 1),
            rows: Array(allRows.prefix(2)),
            next: fixtureCursor("page-1")
        ))
        try #require(await pollUntil { state.rows.count == 2 })
        for _ in 0..<3 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
        }
        let observedCount = await history.observeRequests.count
        state.loadPreviousPage()
        try #require(await pollUntil { await history.observeRequests.count > observedCount })
        #expect(state.rows.isEmpty)
        #expect(state.isLoadingFirstPage)
        // The cursor belongs to position 1. A commit expired it at 2, so
        // the replacement read must not replay the older fixture snapshot.
        await history.emitObservedPage(HistoryPage(
            position: currentPosition,
            rows: Array(allRows.prefix(2)),
            next: fixtureCursor("current-page-1")
        ))
        try #require(await pollUntil { state.rows == Array(allRows.prefix(2)) })
        #expect(await history.browseRequests.last?.cursor == fixtureCursor("newer-0"))
        #expect(await history.observeRequests.last?.kind == .search(text: "row ", mode: .exact))
        #expect(state.typeFilter == .text)
        #expect(await history.observeRequests.last?.filter == HistoryFilter(type: .text))
        #expect(state.loadedPageCount == 1)
        #expect(!state.hasPreviousPage)
        #expect(!state.hasWindowedPages)
        #expect(state.hasNextPage)
    }

    @Test func replacementObservationRetiresAnInFlightNewerPage() async throws {
        let (_, allRows) = fixture()
        let (history, _) = fixture(newerOutcome: .paused(
            fixturePage(rows: Array(allRows.prefix(2)), next: "page-1")
        ))
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        for _ in 0..<3 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
        }
        let cursor = fixtureCursor("newer-0")
        state.loadPreviousPage()
        try #require(await pollUntil { await history.isBrowsePaused(cursor: cursor) })
        await history.emitObservedPage(fixturePage(rows: [allRows[0]], next: nil))
        try #require(await pollUntil { state.rows == [allRows[0]] })
        await history.resumeBrowse(cursor: cursor)
        try #require(await pollUntil { await history.completedPausedBrowseCursors.contains(cursor) })
        await Task.yield()
        #expect(state.rows == [allRows[0]])
        #expect(state.loadedPageCount == 1)
        #expect(!state.hasPreviousPage)
        #expect(!state.hasNextPage)
        #expect(!state.isLoadingPage)
    }

    @Test func receiptOutdatingAnOwnedNewerPageRetiresBothEdgesAndKeepsAPartialCount() async throws {
        let (_, allRows) = fixture()
        let (history, _) = fixture(newerOutcome: .paused(
            fixturePage(rows: Array(allRows.prefix(2)), next: "page-1")
        ))
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        for _ in 0..<3 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
        }
        #expect(state.hasPreviousPage && state.hasNextPage)
        let cursor = fixtureCursor("newer-0")
        state.loadPreviousPage()
        try #require(await pollUntil { await history.isBrowsePaused(cursor: cursor) })
        state.acceptCaptureReceipt(.committed(HistoryCommit(
            position: ChangePosition(rawValue: 2), outcome: .coalesced(allRows[0].item)
        )))
        await history.resumeBrowse(cursor: cursor)
        try #require(await pollUntil { !state.isLoadingPage })
        #expect(state.rows == Array(allRows[2..<8]))
        #expect(state.loadedPageCount == 0)
        #expect(!state.hasPreviousPage)
        #expect(!state.hasNextPage)
        #expect(state.hasWindowedPages, "Latest stays reachable for the partial window")
        #expect(state.displayedCount == 8)
        #expect(state.displayedCountIsLowerBound)
        #expect(HistoryPanelView.itemCountText(for: state, locale: Locale(identifier: "en_US")) == "8+ items")
        let priorRequests = await history.browseRequests.count
        state.loadPreviousPage()
        state.loadNextPage()
        #expect(await history.browseRequests.count == priorRequests)
        await history.emitObservedPage(HistoryPage(
            position: ChangePosition(rawValue: 2), rows: [allRows[0]], next: nil
        ))
        try #require(await pollUntil { state.rows == [allRows[0]] })
        #expect(state.loadedPageCount == 1)
        #expect(!state.hasWindowedPages)
        #expect(!state.displayedCountIsLowerBound)
    }
}
