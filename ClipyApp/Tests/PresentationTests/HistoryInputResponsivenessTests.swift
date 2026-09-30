import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

/// Measures publication through the real History facade and the owner's
/// settled-page callback, rather than the test's polling interval. These
/// timings do not claim physical frame presentation or impose a five-frame gate.
@MainActor
struct HistoryInputResponsivenessTests {
    @Test(arguments: [SearchMode.exact, .fuzzy, .regexp])
    func sameTurnEditsRetireRowsImmediatelyAndObserveOnlyTheFinalQuery(mode: SearchMode) async throws {
        let base = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let target = try await capture("needle final", in: base, index: 0)
        for index in 1...60 { _ = try await capture("previous history row \(index)", in: base, index: index) }
        let history = InputObservationHistory(base: base)
        let state = HistoryViewState(history: history, pageLimit: 5)
        state.searchMode = mode
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.hasAuthoritativeFirstPage && state.rows.count == 5 })
        #expect(await history.requests.count == 1)

        var publishedAt: ContinuousClock.Instant?
        var announcedCount: Int?
        state.onSettledSearchResultCount = { count, _ in
            publishedAt = ContinuousClock.now
            announcedCount = count
        }
        let input = ContinuousClock.now
        state.searchText = "intermediate query with no match"
        state.searchText = "needle final"
        let loading = ContinuousClock.now
        #expect(state.rows.isEmpty)
        #expect(state.isLoadingFirstPage)
        #expect(!state.hasAuthoritativeFirstPage)
        try #require(await pollUntil {
            state.hasAuthoritativeFirstPage && state.rows.map(\.item) == [target]
        })
        let authoritative = try #require(publishedAt)
        let requests = await history.requests
        #expect(requests.count == 2)
        #expect(requests.last?.kind == .search(text: "needle final", mode: mode))
        #expect(!state.isLoadingFirstPage)
        #expect(announcedCount == 1)
        #expect(state.failure == nil)
        print(String(format: "CLIPY_HISTORY_INPUT mode=%@ rows=%d input_to_loading_ms=%.3f input_to_authoritative_ms=%.3f",
                     String(describing: mode), state.rows.count,
                     milliseconds(input.duration(to: loading)), milliseconds(input.duration(to: authoritative))))
    }

    @Test func workspaceVisibilityUpdatesKeepTheReadingRowInsideItsThreePageWindow() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        for index in 0..<8 { _ = try await capture("reading row \(index)", in: history, index: index) }
        let state = HistoryViewState(history: history, pageLimit: 2)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 2 })
        for _ in 0..<2 {
            state.loadNextPage()
            try #require(await pollUntil { !state.isLoadingPage })
        }
        let reading = state.rows[3].item.id
        let next = state.rows[4].item.id
        state.recordReadingPosition(for: reading, isVisible: true)
        state.recordReadingPosition(for: next, isVisible: true)
        #expect(state.readingItemID == reading)
        state.recordReadingPosition(for: reading, isVisible: false)
        #expect(state.readingItemID == next)
        state.loadNextPage()
        try #require(await pollUntil { !state.isLoadingPage })
        #expect(state.loadedPageCount == 3)
        #expect(state.rows.count == 6)
        #expect(state.readingItemID == next)

        state.deactivate()
        state.recordReadingPosition(for: next, isVisible: true)
        #expect(state.readingItemID == nil)
        state.activate()
        try #require(await pollUntil { state.hasAuthoritativeFirstPage })
        #expect(state.readingItemID == state.rows.first?.item.id)
    }

    private func capture(_ text: String, in history: SQLiteHistory, index: Int) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
            origin: .init(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_850_000 + Double(index))
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

/// Records admitted observation requests only; every read, mutation and page
/// comes from the production SQLite History, with no scripted result writer.
private actor InputObservationHistory: ClipboardHistory {
    let base: SQLiteHistory
    private(set) var requests: [HistoryObservationRequest] = []

    init(base: SQLiteHistory) { self.base = base }

    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> {
        requests.append(request)
        return await base.observe(request)
    }
    func perform(_ action: HistoryAction) async throws -> HistoryReceipt { try await base.perform(action) }
    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage { try await base.browse(request) }
    func details(for id: HistoryItemID) async throws -> HistoryDetails { try await base.details(for: id) }
    func representationMetadata(for item: HistoryItemReference) async throws -> [HistoryRepresentationMetadata] {
        try await base.representationMetadata(for: item)
    }
    func sourceApplications(_ request: HistorySourceApplicationRequest) async throws -> HistorySourceApplicationPage {
        try await base.sourceApplications(request)
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
    func usage() async throws -> HistoryUsage { try await base.usage() }
    func backup(to directory: URL) async throws -> HistoryBackupReceipt { try await base.backup(to: directory) }
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration { try await base.retentionConfiguration() }
}
