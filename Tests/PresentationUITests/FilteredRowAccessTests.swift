import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct FilteredRowAccessTests {
    @Test func interleavedRawRowsKeepStableLanesAndExactReferenceAdmission() async throws {
        let raw = mixedRows()
        let history = ScriptedHistory(observedFirstPage: fixturePage(rows: raw, next: nil))
        let state = HistoryViewState(history: history)
        var pasted: [HistoryItemReference] = []
        state.onPaste = { pasted.append($0) }
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })

        // The raw page deliberately interleaves lanes and does not sort pin
        // ordinals. Display groups pinned first but preserves each lane's
        // raw order; neither membership lookup nor prefetch may assume more.
        let cases: [(HistoryTypeFilter, Bool, [Int])] = [
            (.all, false, [1, 3, 5, 0, 2, 4, 6]),
            (.all, true, [1, 3, 5]),
            (.text, false, [1, 5, 0, 4]),
            (.text, true, [1, 5]),
            (.images, false, [2, 6]),
            (.images, true, []),
            (.links, false, [3]),
            (.links, true, [3]),
        ]
        for (filter, pinnedOnly, indices) in cases {
            state.typeFilter = filter
            state.showsPinnedOnly = pinnedOnly
            let expected = indices.map { raw[$0] }
            #expect(state.displayedRows == expected)
            #expect(state.displayedPinnedRows == expected.filter { $0.pinnedPosition != nil })
            #expect(state.displayedUnpinnedRows == expected.filter { $0.pinnedPosition == nil })
            #expect(state.rows == raw)
            pasted = []

            for row in raw {
                state.requestPasteFromDisplayedRow(row.item)
                let provider = state.dragItemProvider(for: row.item)
                #expect(provider.registeredTypeIdentifiers.isEmpty == !expected.contains(row))
            }
            #expect(Set(pasted) == Set(expected.map(\.item)))
            #expect(pasted.count == expected.count)
            if let visible = expected.first {
                let stale = HistoryItemReference(
                    id: visible.item.id, contentVersion: ContentVersion(rawValue: 2)
                )
                state.requestPasteFromDisplayedRow(stale)
                #expect(pasted.count == expected.count)
                #expect(state.dragItemProvider(for: stale).registeredTypeIdentifiers.isEmpty)
            }
        }
        #expect(await history.observeRequests.count == 1)
        await history.finishObservation()
    }

    @Test(arguments: [false, true])
    func prefetchUsesTheLastVisibleLaneRatherThanTheRawSuffix(pinnedOnly: Bool) async throws {
        let raw = mixedRows()
        let cursor = fixtureCursor("interleaved-next")
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: raw, next: "interleaved-next"),
            browseScript: [cursor: .paused(fixturePage(rows: [], next: nil))]
        )
        let state = HistoryViewState(history: history)
        state.typeFilter = .text
        state.showsPinnedOnly = pinnedOnly
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        let lastVisible = raw[pinnedOnly ? 5 : 4]

        for row in raw where row.item != lastVisible.item {
            state.prefetchNextPageIfNeeded(appearingRowID: row.item.id)
            #expect(!state.isLoadingPage)
        }
        #expect(await history.browseRequests.isEmpty)
        state.prefetchNextPageIfNeeded(appearingRowID: lastVisible.item.id)
        try #require(await pollUntil { await history.isBrowsePaused(after: cursor) })
        state.prefetchNextPageIfNeeded(appearingRowID: lastVisible.item.id)
        await history.resumeBrowse(after: cursor)
        try #require(await pollUntil { !state.hasNextPage && !state.isLoadingPage })
        #expect(await history.browseRequests.count == 1)
        #expect(state.rows == raw)
        state.prefetchNextPageIfNeeded(appearingRowID: lastVisible.item.id)
        #expect(!state.isLoadingPage)
        #expect(await history.browseRequests.count == 1)
        await history.finishObservation()
    }

    private func mixedRows() -> [HistoryRow] {
        [
            row(1, type: "public.utf8-plain-text"),
            row(2, type: "public.utf8-plain-text", pinned: 1),
            row(3, type: "public.png"),
            row(4, type: "public.url", pinned: 0),
            row(5, type: "public.utf8-plain-text"),
            row(6, type: "public.utf8-plain-text", pinned: 2),
            row(7, type: "public.png"),
        ]
    }

    private func row(_ index: Int, type: String, pinned: Int? = nil) -> HistoryRow {
        HistoryRow(
            item: HistoryItemReference(
                id: HistoryItemID(rawValue: UUID(uuidString:
                    "00000000-0000-0000-0000-" + String(format: "%012d", index)
                )!), contentVersion: .initial
            ), title: "row \(index)", typeIdentifiers: [type],
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: 100), copyCount: 1,
            lastSource: nil, pinnedPosition: pinned, search: nil
        )
    }
}
