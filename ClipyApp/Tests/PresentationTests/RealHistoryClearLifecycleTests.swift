import Foundation
@testable import HistoryCore
@testable import HistoryStorage
@testable import ClipyApp
import Testing

@MainActor
struct RealHistoryClearLifecycleTests {
    @Test(arguments: ["active", "closed", "settings"])
    func clearUnpinnedReceiptOnlyRestartsAnActiveSurface(lifecycle: String) async throws {
        let base = try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
        for (index, text) in ["remove unpinned", "keep pinned"].enumerated() {
            _ = try await base.perform(.capture(ClipboardCapture(
                representations: [CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(text.utf8))],
                origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
                observedAt: Date(timeIntervalSince1970: Double(index + 1))
            )))
        }
        let initial = try await base.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        let pinned = try #require(initial.rows.first { $0.title == "keep pinned" }?.item)
        _ = try await base.perform(.placePinned(pinned.id, at: .first))
        let history = ParkedClearReceiptHistory(base: base)
        let state = HistoryViewState(history: history)
        defer { state.deactivate() }
        if lifecycle != "settings" {
            state.activate()
            try #require(await pollUntil { state.rows.count == 2 })
        }
        let clear = Task { try await state.clearAwaitingReceipt(.unpinned) }
        try #require(await pollUntil { await history.isReceiptParked })
        if lifecycle == "closed" { state.deactivate() }
        let observationsBeforeReceipt = await history.observationCount
        await history.releaseReceipt()
        let receipt = try await clear.value
        guard case .committed(let commit) = receipt, case .cleared(count: 1) = commit.outcome else {
            Issue.record("Expected the real Clear Unpinned commit")
            return
        }
        #expect(state.surfacePurge?.scope == .unpinned)
        let survivors = try await base.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(survivors.rows.map(\.item) == [pinned])
        if lifecycle == "active" {
            try #require(await pollUntil { state.rows.map(\.item) == [pinned] && !state.isLoadingFirstPage })
            #expect(await history.observationCount == observationsBeforeReceipt + 1)
        } else {
            #expect(state.rows.isEmpty)
            #expect(!state.hasAuthoritativeFirstPage)
            #expect(!state.isLoadingFirstPage)
            #expect(await history.observationCount == observationsBeforeReceipt)
            state.activate()
            try #require(await pollUntil { state.rows.map(\.item) == [pinned] })
            #expect(await history.observationCount == observationsBeforeReceipt + 1)
        }
    }
}

/// Only delays delivery after the real writer has committed. All mutation,
/// observation and read behavior remains the production SQLite facade.
private actor ParkedClearReceiptHistory: ClipboardHistory {
    func backup(to directory: URL) async throws -> HistoryBackupReceipt {
        try await base.backup(to: directory)
    }

    let base: any ClipboardHistory
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var observationCount = 0
    var isReceiptParked: Bool { continuation != nil }

    init(base: any ClipboardHistory) { self.base = base }

    func releaseReceipt() {
        continuation?.resume()
        continuation = nil
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        let receipt = try await base.perform(action)
        if case .clear(.unpinned) = action {
            await withCheckedContinuation { continuation = $0 }
        }
        return receipt
    }

    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> {
        observationCount += 1
        return await base.observe(request)
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage { try await base.browse(request) }
    func details(for id: HistoryItemID) async throws -> HistoryDetails { try await base.details(for: id) }
    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        try await base.representation(request)
    }
    func pastePayload(for id: HistoryItemID) async throws -> PastePayload { try await base.pastePayload(for: id) }
    func thumbnail(for item: HistoryItemReference, pixels: PixelSize) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }
    func usage() async throws -> HistoryUsage { try await base.usage() }
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration { try await base.retentionConfiguration() }
}
