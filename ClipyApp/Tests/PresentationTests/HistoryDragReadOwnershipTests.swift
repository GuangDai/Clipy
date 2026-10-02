import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

/// Pause only delivery of a real SQLite payload. Closing, changing the
/// query or revising its source before AppKit starts a session must retire it.
@MainActor
struct HistoryDragReadOwnershipTests {
    enum Departure: CaseIterable, Sendable { case close, filter, revision }

    @Test(arguments: Departure.allCases)
    func pendingDragCannotOutliveItsDisplayedReference(_ departure: Departure) async throws {
        let base = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let inserted = try await base.perform(.capture(ClipboardCapture(
            representations: [.init(typeIdentifier: "public.utf8-plain-text", bytes: Data("drag source".utf8))],
            origin: .init(sourceApplication: nil, lineageHint: nil), observedAt: Date()
        )))
        guard case .committed(let commit) = inserted, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        let history = DelayedDragPayloadHistory(base: base)
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.first?.item == item })
        let dragging = Task { try await state.dragPayload(for: item) }
        defer {
            dragging.cancel()
            Task { await history.releasePayload() }
        }
        await history.waitUntilPayloadIsHeld()

        switch departure {
        case .close:
            state.deactivate()
        case .filter:
            state.typeFilter = .images
        case .revision:
            _ = try await state.revise(RevisionRequest(
                itemID: item.id, expected: item.contentVersion,
                intent: .replace(.init(decisions: [.init(
                    typeIdentifier: "public.utf8-plain-text", action: .replace(bytes: Data("changed".utf8))
                )]))
            ))
        }
        await history.releasePayload()
        // The caller itself remains uncancelled; state ownership, rather
        // than the drag source's cooperative cancellation, rejects this read.
        #expect(try await dragging.value == nil)
        #expect(state.failure == nil)
    }
}

private actor DelayedDragPayloadHistory: ClipboardHistory {
    let base: SQLiteHistory
    private var hasHeldPayload = false
    private var payloadRelease: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(base: SQLiteHistory) { self.base = base }

    func waitUntilPayloadIsHeld() async {
        if hasHeldPayload { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releasePayload() {
        payloadRelease?.resume()
        payloadRelease = nil
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        let payload = try await base.pastePayload(for: id)
        await withCheckedContinuation { continuation in
            payloadRelease = continuation
            hasHeldPayload = true
            let waiting = waiters
            waiters = []
            for waiter in waiting { waiter.resume() }
        }
        return payload
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt { try await base.perform(action) }
    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage { try await base.browse(request) }
    func observe(_ request: HistoryObservationRequest) async -> AsyncThrowingStream<HistoryPage, Error> {
        await base.observe(request)
    }
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
    func thumbnail(for item: HistoryItemReference, pixels: PixelSize) async throws -> ThumbnailPayload? {
        try await base.thumbnail(for: item, pixels: pixels)
    }
    func usage() async throws -> HistoryUsage { try await base.usage() }
    func backup(to directory: URL) async throws -> HistoryBackupReceipt { try await base.backup(to: directory) }
    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        try await base.retentionConfiguration()
    }
}
