import Foundation
@testable import HistoryCore
@testable import HistoryStorage
@testable import ClipyApp
import Testing

/// The real recent/search cursor producers compose with the bounded UI
/// consumer. Full-page and short-tail round trips use no scripted cursors.
@MainActor
struct RealHistoryViewStateWindowTests {
    @Test(arguments: [false, true])
    func filterFindsOlderUnloadedItemsAndCountsBeyondTheResidentWindow(searching: Bool) async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        var links: [HistoryItemReference] = []
        for index in 0..<17 {
            var representations = [CapturedRepresentation(
                typeIdentifier: "public.utf8-plain-text", bytes: Data("filter needle \(index)".utf8)
            )]
            if index < 9 {
                representations.append(CapturedRepresentation(
                    typeIdentifier: "public.url", bytes: Data("https://example.invalid/needle/\(index)".utf8)
                ))
            }
            let receipt = try await history.perform(.capture(ClipboardCapture(
                representations: representations,
                origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
                observedAt: Date(timeIntervalSinceReferenceDate: 700_620_000 + Double(index))
            )))
            guard case .committed(let commit) = receipt,
                  case .inserted(let item) = commit.outcome else {
                Issue.record("Distinct filter fixtures must insert")
                return
            }
            if index < 9 { links.append(item) }
        }
        let state = HistoryViewState(history: history, pageLimit: 2)
        if searching {
            state.searchMode = .exact
            state.searchText = "needle"
        }
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        #expect(state.rows.allSatisfy { !links.contains($0.item) })

        // Every matching link is older than the entire initially resident page.
        state.typeFilter = .links
        #expect(state.rows.isEmpty)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.rows.count == 2)
        #expect(state.rows.allSatisfy { links.contains($0.item) })
        #expect(state.displayedCountIsLowerBound)
        var seen = state.rows.map(\.item)
        for _ in 0..<4 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
            for row in state.rows where !seen.contains(row.item) { seen.append(row.item) }
            #expect(state.rows.count <= 6)
            #expect(state.failure == nil)
        }
        #expect(Set(seen) == Set(links))
        #expect(!state.hasNextPage)
        #expect(state.hasPreviousPage)
        #expect(state.displayedCount == 9)
        #expect(!state.displayedCountIsLowerBound)

        _ = try await history.perform(.placePinned(links[0].id, at: .last))
        state.showsPinnedOnly = true
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [links[0]]
        })
        #expect(state.displayedCount == 1)
        #expect(!state.hasNextPage)
        #expect(!state.displayedCountIsLowerBound)
    }

    @Test(arguments: [false, true])
    func adjacentCursorsRoundTripAcrossBothLanesAndAShortSearchTail(searching: Bool) async throws {
        let history = try await SQLiteHistory.open(
            configuration: HistoryConfiguration(persistence: .temporary)
        )
        var items: [HistoryItemReference] = []
        for index in 0..<16 {
            let title = index == 15 ? "unmatched" : "window needle \(index)"
            let receipt = try await history.perform(.capture(ClipboardCapture(
                representations: [CapturedRepresentation(
                    typeIdentifier: "public.utf8-plain-text", bytes: Data(title.utf8)
                )],
                origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
                observedAt: Date(timeIntervalSinceReferenceDate: 700_610_000 + Double(index))
            )))
            guard case .committed(let commit) = receipt,
                  case .inserted(let item) = commit.outcome else {
                Issue.record("Each distinct window fixture must insert")
                return
            }
            items.append(item)
        }
        _ = try await history.perform(.placePinned(items[2].id, at: .last))
        _ = try await history.perform(.placePinned(items[9].id, at: .last))
        let kind: HistoryBrowseKind = searching
            ? .search(text: "needle", mode: .exact) : .recent
        let expected = try await history.browse(HistoryBrowseRequest(kind: kind, limit: 100))
        #expect(expected.rows.count == (searching ? 15 : 16))
        #expect(expected.rows.filter { $0.pinnedPosition != nil }.count == 2)
        let state = HistoryViewState(history: history, pageLimit: 2)
        if searching {
            state.searchMode = .exact
            state.searchText = "needle"
        }
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows == Array(expected.rows.prefix(2)) })
        for _ in 0..<2 {
            // The second trip begins at the first three-page window.
            let firstOlderPage = state.loadedPageCount
            for endPage in firstOlderPage..<8 {
                state.loadNextPage()
                try #require(await pollUntil { !state.isLoadingPage })
                let end = min((endPage + 1) * 2, expected.rows.count)
                #expect(state.rows == Array(expected.rows[(max(0, endPage - 2) * 2)..<end]))
                #expect(state.loadedPageCount <= 3)
                #expect(state.rows.count <= 6)
                #expect(state.traversedRowCount == end)
                #expect(state.failure == nil)
            }
            #expect(!state.hasNextPage)
            #expect(state.displayedCount == expected.rows.count)
            #expect(!state.displayedCountIsLowerBound)
            for firstPage in stride(from: 4, through: 0, by: -1) {
                state.loadPreviousPage()
                try #require(await pollUntil { !state.isLoadingPage })
                #expect(state.rows == Array(expected.rows[(firstPage * 2)..<((firstPage + 3) * 2)]))
                #expect(state.loadedPageCount == 3)
                #expect(state.traversedRowCount == (firstPage + 3) * 2)
                #expect(state.hasNextPage)
                #expect(state.failure == nil)
            }
            #expect(!state.hasPreviousPage)
            #expect(state.hasWindowedPages)
        }
        #expect(state.surfacePurge == nil, "Navigation never deletes retained items")
        var pasted: HistoryItemReference?
        state.onPaste = { pasted = $0 }
        state.requestPasteFromDisplayedRow(try #require(state.rows.first?.item))
        #expect(pasted == expected.rows.first?.item)
    }
}
