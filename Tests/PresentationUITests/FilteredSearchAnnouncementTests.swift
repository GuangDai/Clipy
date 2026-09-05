import Foundation
import HistoryCore
import Testing
@testable import PresentationUI

@MainActor
struct FilteredSearchAnnouncementTests {
    @Test(arguments: [false, true])
    func settledQueryAnnouncesVisibleCountOnce(pinnedOnly: Bool) async throws {
        let history = ScriptedHistory()
        let state = HistoryViewState(history: history)
        state.typeFilter = .images
        state.showsPinnedOnly = pinnedOnly
        var announcements: [(count: Int, hasNextPage: Bool)] = []
        state.onSettledSearchResultCount = { count, hasNextPage in
            announcements.append((count, hasNextPage))
        }
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { await history.observeRequests.count == 1 })

        state.searchText = "old"
        try #require(await pollUntil { await history.observeRequests.count == 2 })
        state.searchText = "current"
        try #require(await pollUntil { await history.observeRequests.count == 3 })

        let rows = [
            row(1, type: "public.png", pinned: 0),
            row(2, type: "public.png"),
            row(3, type: "public.utf8-plain-text"),
        ]
        // Offer the cancelled query a different count before publishing the
        // current query. Only the current generation may consume its intent.
        await history.emitObservedPage(
            fixturePage(rows: [], next: nil), observationIndex: 1
        )
        await history.emitObservedPage(fixturePage(rows: rows, next: "more"))
        try #require(await pollUntil { state.rows == rows && announcements.count == 1 })
        #expect(announcements[0].count == (pinnedOnly ? 1 : 2))
        #expect(announcements[0].count == state.displayedRows.count)
        #expect(announcements[0].hasNextPage)
        #expect(state.rows.count == 3)

        // A copy-count-only replacement is a real observed state change,
        // but the same query's result count must not be announced again.
        let metadataRows = [
            row(1, type: "public.png", pinned: 0, copyCount: 2),
            rows[1], rows[2],
        ]
        await history.emitObservedPage(fixturePage(rows: metadataRows, next: "more"))
        try #require(await pollUntil { state.rows == metadataRows })
        #expect(announcements.count == 1)

        // Filtering itself doesn't re-arm search announcements. A new query
        // with zero visible results still announces zero, even with raw hits.
        state.typeFilter = .links
        #expect(state.displayedRows.isEmpty)
        #expect(announcements.count == 1)
        state.searchText = "latest"
        try #require(await pollUntil { await history.observeRequests.count == 4 })
        await history.emitObservedPage(
            fixturePage(rows: rows, next: "stale-more"), observationIndex: 2
        )
        await history.emitObservedPage(fixturePage(rows: metadataRows, next: nil))
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && announcements.count == 2 })
        #expect(announcements[1].count == 0)
        #expect(!announcements[1].hasNextPage)
        #expect(state.rows == metadataRows)
        await history.finishObservation()
    }

    private func row(
        _ index: Int, type: String, pinned: Int? = nil, copyCount: UInt64 = 1
    ) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: HistoryItemID(rawValue: UUID(uuidString:
                    "00000000-0000-0000-0000-" + String(format: "%012d", index)
                )!), contentVersion: .initial
            ),
            title: "matching row \(index)", typeIdentifiers: [type],
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100),
            copyCount: copyCount, lastSource: nil, pinnedPosition: pinned, search: nil
        )
    }
}
