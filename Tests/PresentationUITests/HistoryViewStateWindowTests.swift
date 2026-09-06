import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

@MainActor
struct HistoryViewStateWindowTests {
    private func fixture(pausedPage: Int? = nil) -> (ScriptedHistory, [HistoryRow]) {
        let rows = (1...16).map { index in
            fixtureRow(
                id: "00000000-0000-0000-0000-" + String(format: "%012d", index),
                title: "row \(index)"
            )
        }
        let script = Dictionary(uniqueKeysWithValues: (1..<8).map { index in
            let page = fixturePage(
                rows: Array(rows[(index * 2)..<(index * 2 + 2)]),
                next: index < 7 ? "page-\(index + 1)" : nil
            )
            return (fixtureCursor("page-\(index)"), index == pausedPage
                ? ScriptedHistory.BrowseOutcome.paused(page) : .page(page))
        })
        return (ScriptedHistory(
            observedFirstPage: fixturePage(rows: Array(rows.prefix(2)), next: "page-1"),
            browseScript: script
        ), rows)
    }

    @Test func olderAndNewerRoundTripsKeepThreePagesAndExactTailCounts() async throws {
        let (history, allRows) = fixture()
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        for page in 1..<8 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
            #expect(state.rows == Array(allRows[(max(0, page - 2) * 2)..<((page + 1) * 2)]))
            #expect(state.rows.count <= 6)
            #expect(state.traversedRowCount == (page + 1) * 2)
        }
        #expect(state.hasPreviousPage)
        #expect(!state.hasNextPage)
        #expect(state.displayedCount == 16)
        #expect(!state.displayedCountIsLowerBound)
        #expect(HistoryPanelView.itemCountText(for: state, locale: Locale(identifier: "en_US")) == "16 items")
        #expect(SearchHeaderView.resultCountText(for: state, locale: Locale(identifier: "en_US")) == "16 results")
        state.typeFilter = .text
        #expect(state.displayedCount == 6)
        #expect(state.displayedCountIsLowerBound)
        #expect(HistoryPanelView.itemCountText(for: state, locale: Locale(identifier: "en_US")) == "6+ items")
        state.typeFilter = .all
        for firstPage in stride(from: 4, through: 0, by: -1) {
            state.loadPreviousPage()
            try #require(await pollUntil { !state.isLoadingPage })
            #expect(state.rows == Array(allRows[(firstPage * 2)..<((firstPage + 3) * 2)]))
            #expect(state.hasNextPage)
            #expect(state.rows.count == 6)
        }
        #expect(!state.hasPreviousPage)
        for page in 3..<8 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
            #expect(state.rows == Array(allRows[((page - 2) * 2)..<((page + 1) * 2)]))
        }
        #expect(state.displayedCount == 16)
        #expect(state.surfacePurge == nil, "DTO eviction is not a History deletion")
        _ = state.acceptCommittedExternalRemoval(allRows[15].item.id)
        #expect(state.displayedCountIsLowerBound,
                "Receipt-purged partial rows cannot become a false exact total before observation")
        state.returnToLatest()
        try #require(await pollUntil { state.rows == Array(allRows.prefix(2)) })
        #expect(!state.hasPreviousPage)
        #expect(!state.hasWindowedPages)
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
    }

    @Test func observedReplacementRetiresTheWindowAndItsNewerBookmarks() async throws {
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
        try #require(await pollUntil { await history.isBrowsePaused(after: fixtureCursor("page-5")) })
        await history.emitObservedPage(fixturePage(rows: [allRows[0]], next: nil))
        try #require(await pollUntil { state.rows == [allRows[0]] })
        #expect(!state.hasPreviousPage)
        #expect(!state.hasNextPage)
        #expect(!state.hasWindowedPages)
        #expect(state.traversedRowCount == 1)
        await history.resumeBrowse(after: fixtureCursor("page-5"))
        try #require(await pollUntil { await history.completedPausedBrowseCursors.contains(fixtureCursor("page-5")) })
        #expect(state.rows == [allRows[0]])
        #expect(!state.hasPreviousPage)
        #expect(!state.isLoadingPage)
    }
}
