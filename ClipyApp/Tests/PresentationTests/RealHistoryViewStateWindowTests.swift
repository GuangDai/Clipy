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
    func oneBackgroundWriteReplacesTheWindowAfterTwoReadingPositionChanges(
        lastAnchorIsInSecondSeek: Bool
    ) async throws {
        let base = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        func insert(_ index: Int) async throws -> HistoryCommit {
            let receipt = try await base.perform(.capture(.init(
                representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data("anchor fixture \(index)".utf8))],
                origin: .init(sourceApplication: nil, lineageHint: nil),
                observedAt: Date(timeIntervalSinceReferenceDate: 700_620_000 + Double(index))
            )))
            let inserted: HistoryCommit?
            if case .committed(let commit) = receipt, case .inserted = commit.outcome {
                inserted = commit
            } else {
                inserted = nil
            }
            return try #require(inserted)
        }

        for index in 0..<12 { _ = try await insert(index) }
        let initial = try await base.browse(.init(kind: .recent, limit: 12, sortOrder: .newestFirst))
        let itemIDs = initial.rows.map(\.item.id)
        try #require(itemIDs.count == 12)
        let history = ParkedAnchorBrowseHistory(base: base)
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.activate()
        defer {
            state.deactivate()
            Task { await history.stopParking() }
        }
        try #require(await pollUntil { state.rows.count == 2 })
        for _ in 0..<3 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
        }
        try #require(state.rows.map(\.item.id) == Array(itemIDs[2..<8]))

        let firstAnchor = itemIDs[4]
        let secondAnchor = itemIDs[5]
        let finalAnchor = itemIDs[lastAnchorIsInSecondSeek ? 6 : 7]
        state.recordReadingPosition(visibleRowIDs: [firstAnchor])
        let commit = try await insert(12)
        try #require(await pollUntil { await history.parkedAnchor == firstAnchor })
        state.recordReadingPosition(visibleRowIDs: [secondAnchor])
        await history.resumeBrowse()
        try #require(await pollUntil { await history.parkedAnchor == secondAnchor })
        state.recordReadingPosition(visibleRowIDs: [finalAnchor])
        await history.resumeBrowse()

        try #require(await pollUntil { state.sourceCompletionPosition == commit.position })
        #expect(await history.requestedAnchors == [firstAnchor, secondAnchor])
        if lastAnchorIsInSecondSeek {
            #expect(state.rows.map(\.item.id) == [secondAnchor, finalAnchor])
            #expect(state.readingItemID == finalAnchor)
            #expect(state.hasPreviousPage)
            #expect(!state.didLoseReadingPosition)
        } else {
            let latest = try await base.browse(.init(kind: .recent, limit: 2, sortOrder: .newestFirst))
            #expect(state.rows == latest.rows)
            #expect(!state.hasPreviousPage)
            #expect(state.didLoseReadingPosition)
        }
        state.loadNextPage()
        try #require(await pollUntil { !state.isLoadingPage })
        let nextItems = lastAnchorIsInSecondSeek ? itemIDs[7..<9] : itemIDs[1..<3]
        #expect(state.rows.map(\.item.id).suffix(2) == nextItems)
        #expect(state.failure == nil)
    }

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
        var announcements: [(count: Int, isLowerBound: Bool)] = []
        state.onSettledSearchResultCount = { announcements.append(($0, $1)) }
        if searching {
            state.searchMode = .exact
            state.searchText = "needle"
        }
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        #expect(state.rows.allSatisfy { !links.contains($0.item) })
        let priorAnnouncements = announcements.count

        // Every matching link is older than the entire initially resident page.
        state.typeFilter = .links
        #expect(state.rows.isEmpty)
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.rows.count == 2)
        #expect(state.rows.allSatisfy { links.contains($0.item) })
        #expect(state.displayedCountIsLowerBound)
        #expect(announcements.count == priorAnnouncements + 1)
        #expect(announcements.last?.count == 2)
        #expect(announcements.last?.isLowerBound == true)
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
        if !searching {
            #expect(announcements.count == 2)
            #expect(announcements.last?.count == 1)
            #expect(announcements.last?.isLowerBound == false)
            state.typeFilter = .images
            try #require(await pollUntil { state.hasAuthoritativeFirstPage && announcements.count == 3 })
            #expect(announcements.last?.count == 0)
            #expect(announcements.last?.isLowerBound == false)
            state.clearFilters()
            try #require(await pollUntil { state.hasAuthoritativeFirstPage && announcements.count == 4 })
            #expect(announcements.last?.count == 2)
            #expect(announcements.last?.isLowerBound == true)
        }
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
        state.sortOrder = .automatic
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
                #expect(state.displayedRows == state.rows,
                        "Display preserves History ordering across the pinned/recency boundary")
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
                #expect(state.displayedRows == state.rows,
                        "Backward navigation preserves the same display order")
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

/// Pauses only delivery of SQLite's already-computed anchored pages.
private actor ParkedAnchorBrowseHistory: ClipboardHistory {
    let base: SQLiteHistory
    private var parkedBrowse: CheckedContinuation<Void, Never>?
    private var parksAnchors = true
    private(set) var parkedAnchor: HistoryItemID?
    private(set) var requestedAnchors: [HistoryItemID] = []

    init(base: SQLiteHistory) { self.base = base }

    func resumeBrowse() {
        parkedAnchor = nil
        parkedBrowse?.resume()
        parkedBrowse = nil
    }

    func stopParking() {
        parksAnchors = false
        resumeBrowse()
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        let page = try await base.browse(request)
        if parksAnchors, let anchor = request.startAround {
            requestedAnchors.append(anchor)
            await withCheckedContinuation { continuation in
                parkedAnchor = anchor
                parkedBrowse = continuation
            }
        }
        return page
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt { try await base.perform(action) }
    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> {
        await base.observe(request)
    }
    func sourceApplications(_ request: HistorySourceApplicationRequest) async throws -> HistorySourceApplicationPage {
        try await base.sourceApplications(request)
    }
    func details(for id: HistoryItemID) async throws -> HistoryDetails { try await base.details(for: id) }
    func representationMetadata(for item: HistoryItemReference) async throws -> [HistoryRepresentationMetadata] {
        try await base.representationMetadata(for: item)
    }
    func copySources(for id: HistoryItemID, expectedCopyCount: UInt64, offset: Int) async throws -> HistoryCopySourcePage {
        try await base.copySources(for: id, expectedCopyCount: expectedCopyCount, offset: offset)
    }
    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        try await base.representation(request)
    }
    func pastePayload(for id: HistoryItemID) async throws -> PastePayload { try await base.pastePayload(for: id) }
    func thumbnail(for item: HistoryItemReference, pixels: PixelSize) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }
    func thumbnailCapacityChanges() async -> AsyncStream<Void> { await base.thumbnailCapacityChanges() }
    func usage() async throws -> HistoryUsage { try await base.usage() }
    func backup(to directory: URL) async throws -> HistoryBackupReceipt { try await base.backup(to: directory) }
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration { try await base.retentionConfiguration() }
}
