import Foundation
import HistoryCore
import HistoryStorage
@testable import ClipyApp
import Testing

/// A saved reading location is only a UUID. Real History queries decide
/// whether it is still retained and included in the current conditions.
@MainActor
struct HistoryReadingPositionTests {
    @Test func deepReadingPositionRestoresThenPagesBackToAnAbsoluteRange() async throws {
        let (history, items) = try await fixture()
        let state = HistoryViewState(history: history, pageLimit: 3)
        state.activate(restoring: items[4].id)
        defer { state.deactivate() }

        #expect(state.rows.isEmpty)
        #expect(state.isLoadingFirstPage)
        try #require(await pollUntil { state.restoredReadingItemID == items[4].id })
        #expect(state.rows.map(\.item) == [items[4], items[3], items[2]])
        #expect(state.readingItemID == items[4].id)
        #expect(state.hasPreviousPage)
        #expect(state.hasNextPage)
        #expect(state.showsPageNavigation)
        #expect(!state.hasKnownRowOffset)
        #expect(state.displayedCountIsLowerBound)
        #expect(!state.didLoseReadingPosition)

        state.loadPreviousPage()
        try #require(await pollUntil { state.rows.first?.item == items[7] && !state.isLoadingPage })
        #expect(!state.hasKnownRowOffset)
        #expect(state.loadedRowRange?.lowerBound == 1)
        state.loadPreviousPage()
        try #require(await pollUntil { state.rows.first?.item == items[9] && !state.isLoadingPage })
        #expect(state.hasKnownRowOffset)
        #expect(!state.hasPreviousPage)
        #expect(state.loadedRowRange == 1...8)
        #expect(state.rows.count <= state.pageLimit * 3)
        #expect(state.failure == nil)
    }

    @Test func rememberedIDUsesVisibleRowsAndDefaultActivationStillStartsAtLatest() async throws {
        let (history, items) = try await fixture()
        let state = HistoryViewState(history: history, pageLimit: 3)
        state.activate(restoring: items[5].id)
        try #require(await pollUntil { state.restoredReadingItemID == items[5].id })
        state.recordReadingPosition(visibleRowIDs: [items[3].id, items[4].id])
        let remembered = try #require(state.readingItemID)
        #expect(remembered == items[4].id)
        state.deactivate()

        state.activate(restoring: remembered)
        try #require(await pollUntil { state.restoredReadingItemID == remembered })
        #expect(state.rows.first?.item == items[4])
        state.deactivate()

        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.rows.first?.item == items[9])
        #expect(state.restoredReadingItemID == nil)
        #expect(state.hasKnownRowOffset)
        #expect(!state.didLoseReadingPosition)
    }

    @Test func excludedSavedItemReturnsToTheCurrentFilteredFirstPageWithNotice() async throws {
        let (history, items) = try await fixture()
        let state = HistoryViewState(history: history, pageLimit: 3)
        var filters = HistorySearchFilters()
        filters.sourceApplication = "com.example.even"
        filters.sourceMatch = .bundleIdentifier
        // Setting a query property can start observation before activation.
        // Explicit restoration must still be admitted once for this surface.
        state.searchFilters = filters
        state.activate(restoring: items[5].id)
        defer { state.deactivate() }

        try #require(await pollUntil { state.didLoseReadingPosition && state.hasAuthoritativeFirstPage })
        #expect(state.rows.map(\.item) == [items[8], items[6], items[4]])
        #expect(state.searchFilters == filters)
        #expect(state.restoredReadingItemID == nil)
        #expect(state.hasKnownRowOffset)
        #expect(state.failure == nil)
    }

    @Test func removedSavedItemFallsBackWithoutDisplayingItsOldRow() async throws {
        let (history, items) = try await fixture()
        _ = try await history.perform(.remove(items[4].id))
        let state = HistoryViewState(history: history, pageLimit: 3)
        state.activate(restoring: items[4].id)
        defer { state.deactivate() }

        try #require(await pollUntil { state.didLoseReadingPosition && state.hasAuthoritativeFirstPage })
        #expect(state.rows.map(\.item) == [items[9], items[8], items[7]])
        #expect(!state.rows.contains { $0.item.id == items[4].id })
        #expect(state.readingItemID == items[9].id)
        #expect(state.failure == nil)
    }

    @Test func closedRestoreCannotReplaceTheNextActivationAndDuplicateActivationIsIdempotent() async throws {
        let (history, items) = try await fixture()
        let state = HistoryViewState(history: history, pageLimit: 3)
        state.activate(restoring: items[4].id)
        state.deactivate()
        await Task.yield()
        #expect(state.rows.isEmpty)
        #expect(!state.isLoadingFirstPage)

        state.activate(restoring: items[6].id)
        defer { state.deactivate() }
        try #require(await pollUntil { state.restoredReadingItemID == items[6].id })
        state.activate(restoring: items[4].id)
        #expect(!state.isLoadingFirstPage)
        #expect(state.rows.first?.item == items[6])
        state.returnToLatest()
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.first?.item == items[9] })
        #expect(state.restoredReadingItemID == nil)
        #expect(state.hasKnownRowOffset)
    }

    private func fixture() async throws -> (SQLiteHistory, [HistoryItemReference]) {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        var items: [HistoryItemReference] = []
        for index in 0..<10 {
            let receipt = try await history.perform(.capture(ClipboardCapture(
                representations: [CapturedRepresentation(
                    typeIdentifier: "public.utf8-plain-text", bytes: Data("reading item \(index)".utf8)
                )],
                origin: .init(sourceApplication: index.isMultiple(of: 2) ? "com.example.even" : "com.example.odd",
                              lineageHint: nil),
                observedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index))
            )))
            guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
                throw FixtureFailure.expectedInsertion
            }
            items.append(item)
        }
        return (history, items)
    }

    private enum FixtureFailure: Error { case expectedInsertion }
}
