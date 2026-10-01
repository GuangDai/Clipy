@testable import ContentPreview
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import ClipyApp

#if DEBUG
@Suite("Committed clear rebuilds surviving displayed thumbnails", .serialized)
@MainActor
struct RealHistoryThumbnailPurgeTests {
    @Test func clearUnpinnedRebuildsPinnedPixelsWithoutAnotherRowAppearance() async throws {
        let history = try await SQLiteHistory.open(configuration: .init(persistence: .temporary))
        let pinned = try await capture("displayed pinned", in: history)
        let coldPinned = try await capture("offscreen pinned", in: history)
        let removed = try await capture("removed during display decode", in: history)
        _ = try await history.perform(.placePinned(pinned.id, at: .first))
        _ = try await history.perform(.placePinned(coldPinned.id, at: .last))

        let state = HistoryViewState(history: history)
        let surface = HistoryPanelSurfaceState(history: history, previewState: PreviewPaneState())
        let store = surface.thumbnails
        store.setDisplayed(pinned, true)
        store.prefetch(pinned)
        store.prefetch(coldPinned)
        try #require(await pollUntil { store.inFlightCount == 0 })
        let original = try #require(store.raster(for: pinned))
        try #require(store.imagePixelSize(for: coldPinned) != nil)

        let gate = RetiredThumbnailRenderGate()
        try await ContentPreviewDebugInstrumentation.$renderDidStart.withValue({ await gate.parkFirst() }) {
            try await clearWhileRemovedPixelsAreRendering(
                removed, pinned: pinned, coldPinned: coldPinned, original: original,
                history: history, state: state, surface: surface, gate: gate
            )
        }
    }

    // Keep the scenario outside the TaskLocal operation's generic closure,
    // matching the renderer lifecycle tests' Swift 6.2 codegen workaround.
    private func clearWhileRemovedPixelsAreRendering(
        _ removed: HistoryItemReference, pinned: HistoryItemReference,
        coldPinned: HistoryItemReference, original: PreviewRaster,
        history: SQLiteHistory, state: HistoryViewState,
        surface: HistoryPanelSurfaceState, gate: RetiredThumbnailRenderGate
    ) async throws {
        let store = surface.thumbnails
        store.setDisplayed(removed, true)
        store.prefetch(removed)
        let started = await pollUntil { await gate.isParked }
        if !started {
            await gate.resume()
            store.reset()
            try #require(started)
            return
        }

        do {
            let receipt = try await state.clearAwaitingReceipt(.unpinned)
            guard case .committed(let commit) = receipt, case .cleared(count: 1) = commit.outcome else {
                Issue.record("Expected the real clear to remove exactly the unpinned image")
                await gate.resume()
                store.reset()
                return
            }
            let purge = try #require(state.surfacePurge)
            surface.apply(purge)
            #expect(store.imagePixelSize(for: pinned) == nil)
            #expect(store.imagePixelSize(for: removed) == nil)
            #expect(store.imagePixelSize(for: coldPinned) == nil)
            // No new appearance, task or explicit prefetch for the unchanged
            // pinned reference occurs after the receipt-confirmed reset.
            await gate.resume()
            try #require(await pollUntil {
                store.inFlightCount == 0 && store.debugDiscardedFetchCompletionCount > 0
            })
            #expect(store.raster(for: pinned) == original)
            #expect(store.imagePixelSize(for: removed) == nil)
            #expect(!store.isUnavailable(for: removed))
            #expect(store.imagePixelSize(for: coldPinned) == nil)
            #expect(store.cachedEntryCount == 1)
            #expect(store.cachedDecodedBytes == original.pixels.count)
            #expect(try await history.details(for: pinned.id).item == pinned)
            let remaining = try await history.browse(.init(
                kind: .recent, limit: 10, filter: .init(pinnedOnly: true)
            ))
            #expect(Set(remaining.rows.map(\.item)) == Set([pinned, coldPinned]))
            await #expect(throws: HistoryFailure.notFound(removed.id)) {
                try await history.details(for: removed.id)
            }
        } catch {
            await gate.resume()
            store.reset()
            throw error
        }
    }

    private func capture(_ label: String, in history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "public.png", bytes: fixturePNGData),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(label.utf8)),
            ],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_094_000)
        )))
        guard case .committed(let commit) = receipt, case .inserted(let item) = commit.outcome else {
            throw HistoryFailure.persistence(.invariantViolation)
        }
        return item
    }
}

private actor RetiredThumbnailRenderGate {
    private var entered = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isParked = false

    func parkFirst() async {
        guard !entered else { return }
        entered = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isParked = true
        }
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
        isParked = false
    }
}
#endif
