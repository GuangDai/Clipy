import AppKit
import Foundation
@testable import HistoryCore
@testable import ClipyApp
import Testing

/// Async UI ordering only; storage bytes/lineage use the real History suite.
@MainActor
struct DragItemProviderTests {
    @Test func dragReadsOneCurrentPayloadAndRetainsItAfterPanelCloses() async throws {
        let original = Self.reference(version: 1)
        let current = Self.reference(version: 2)
        let read = PausedDragRead()
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [Self.row(original)], next: nil),
            pastePayloadRead: { _ in try await read.value() }
        )
        let state = HistoryViewState(history: history)
        state.activate()
        try #require(await pollUntil { state.rows.count == 1 })
        let loading = Task { try await state.dragPayload(for: original) }
        try #require(await pollUntil { await read.isWaiting })
        await read.finish(.success(Self.payload(current)))
        let payload = try #require(try await loading.value)
        state.deactivate()
        let writers = try HistoryListDraggingView.pasteboardItems(for: payload)
        #expect(writers.count == 2)
        #expect(writers[0].data(forType: .string) == Data("current first".utf8))
        #expect(writers[1].data(forType: .string) == Data("current second".utf8))
        #expect(await read.requestCount == 1)
        #expect(state.failure == nil)
        await history.finishObservation()
    }

    @Test func cancellationDiscardsAnAlreadyAdmittedButLateRead() async throws {
        let reference = Self.reference(version: 1)
        let read = PausedDragRead()
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [Self.row(reference)], next: nil),
            pastePayloadRead: { _ in try await read.value() }
        )
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 1 })
        let loading = Task { try await state.dragPayload(for: reference) }
        try #require(await pollUntil { await read.isWaiting })
        loading.cancel()
        await read.finish(.success(Self.payload(reference)))
        await #expect(throws: CancellationError.self) { try await loading.value }
        #expect(await read.requestCount == 1)
        #expect(state.failure == nil)
        await history.finishObservation()
    }

    @Test func readFailureStartsNoPartialPayloadAndDoesNotChangeThePanelBanner() async throws {
        let reference = Self.reference(version: 1)
        let history = ScriptedHistory(
            observedFirstPage: fixturePage(rows: [Self.row(reference)], next: nil),
            pastePayloadRead: { _ in throw HistoryFailure.notFound(reference.id) }
        )
        let state = HistoryViewState(history: history)
        state.activate()
        defer { state.deactivate() }
        try #require(await pollUntil { state.rows.count == 1 })
        await #expect(throws: HistoryFailure.notFound(reference.id)) {
            try await state.dragPayload(for: reference)
        }
        #expect(state.failure == nil)
        await history.finishObservation()
    }

    private static func reference(version: UInt64) -> HistoryItemReference {
        .init(id: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000D401")!),
              contentVersion: .init(rawValue: version))
    }

    private static func row(_ reference: HistoryItemReference) -> HistoryRow {
        .init(item: reference, title: "drag fixture", typeIdentifiers: ["public.utf8-plain-text"],
              lastCopiedAt: Date(), copyCount: 1, lastSource: nil, pinnedPosition: nil, search: nil)
    }

    private static func payload(_ reference: HistoryItemReference) -> PastePayload {
        .init(item: reference, representations: [
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("current first".utf8)),
            .init(typeIdentifier: "public.utf8-plain-text", bytes: Data("current second".utf8), pasteboardItemIndex: 1),
        ], lineageHint: reference.id)
    }
}

private actor PausedDragRead {
    private var continuation: CheckedContinuation<PastePayload, Error>?
    private(set) var requestCount = 0
    var isWaiting: Bool { continuation != nil }

    func value() async throws -> PastePayload {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<PastePayload, HistoryFailure>) {
        let waiting = continuation
        continuation = nil
        switch result {
        case .success(let payload): waiting?.resume(returning: payload)
        case .failure(let failure): waiting?.resume(throwing: failure)
        }
    }
}
