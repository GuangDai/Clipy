/// ThumbnailStoreTests — the panel thumbnail store acceptance suite
/// (docs/architecture.md; docs/storage.md; docs/
/// roadmap/05-presentationui.md), driven by a scripted `ClipboardHistory`
/// double that answers one fixed encoded 1×1 PNG per exact reference.
///
/// Pinned semantics: `imagePixelSize(for:)` is a pure read that never fetches;
/// `prefetch(_:)` is idempotent per reference and materializes the encoded
/// bytes OFF the MainActor into an eager Sendable raster retained under the
/// EXACT requesting reference (id + Content Version — a revised item never
/// sees stale pixels); `nil` and `.thumbnailUnavailable` are negative-retained
/// while other failures are NOT (transient unavailability may recover); `reset()` clears
/// everything and advances a surface-owned purge generation so late results
/// cannot refill it. Retention is bounded by entry count AND decoded bytes
/// for both retained pixels and unavailable results.
@testable import ContentPreview
import Foundation
@testable import HistoryCore
import Testing
@testable import ClipyApp

#if DEBUG
private actor ThumbnailDisplayDecodeProbe {
    private(set) var count = 0

    func record() { count += 1 }
}

/// Park the first display operation after it owns ContentPreview's native
/// slot. Cancellation is observed without releasing that slot, so the test
/// can prove the surface retires work before native rendering completes.
private actor ThumbnailDisplayCancellationProbe {
    private(set) var starts = 0
    private(set) var wasCancelled = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func parkFirst() async {
        starts += 1
        guard starts == 1, !isReleased else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
    }

    private func recordCancellation() { wasCancelled = true }

    // Poll actor-local state directly. This avoids the Swift 6.2 codegen
    // failure when async predicate closures capture different actor types.
    // Match pollUntil's bounded scheduled attempts, including cancellation.
    func waitUntilFirstRenderStarts() async -> Bool {
        for _ in 0..<2_000 {
            if starts == 1 { return true }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return starts == 1 }
        }
        return starts == 1
    }

    func waitUntilCancellation() async -> Bool {
        for _ in 0..<2_000 {
            if wasCancelled { return true }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { return wasCancelled }
        }
        return wasCancelled
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
#endif

/// Real ImageIO materialization shares one owner-local native slot. Running
/// this suite's independent stores concurrently under the full 962-test lane
/// starved their MainActor completions past a moving timeout (runs
/// 32681513849/32682113026); serialize the owner suite instead of weakening
/// its monotone-condition deadline.
@Suite("ThumbnailStore native/display ownership", .serialized)
@MainActor
struct ThumbnailStoreTests {

    #if DEBUG
    @Test func lastAppearanceRetiresOnlyItsFlightAndLateResultCannotReplaceReappearance() async throws {
        let item = reference("00000000-0000-0000-0000-0000000000E1", version: 1)
        let other = reference("00000000-0000-0000-0000-0000000000E2", version: 1)
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)
        store.setDisplayed(item, true)
        store.setDisplayed(item, true)
        store.setDisplayed(other, true)
        store.prefetch(item)
        store.prefetch(other)
        try #require(await pollUntil { await history.requestCount == 2 })

        store.setDisplayed(item, false)
        #expect(store.inFlightCount == 2, "The replacement row still needs the same flight")
        #expect(await history.cancellationCount == 0)
        store.setDisplayed(item, false)
        #expect(store.inFlightCount == 1)
        try #require(await pollUntil { await history.cancellationCount == 1 })
        #expect(store.purgeGeneration == 0)

        store.setDisplayed(item, true)
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 3 })
        #expect(await history.completeRequest(for: item, with: .success(fixturePNGData)))
        try #require(await pollUntil { store.debugFetchCompletionCount == 1 })
        #expect(store.debugDiscardedFetchCompletionCount == 1)
        #expect(store.imagePixelSize(for: item) == nil)
        #expect(store.inFlightCount == 2, "The old completion must not consume the new same-key flight")

        #expect(await history.completeRequest(for: other, with: .success(fixturePNGData)))
        #expect(await history.completeRequest(for: item, occurrence: 1, with: .success(fixturePNGData)))
        try #require(await pollUntil { store.liveRequestCount == 0 && store.pendingRequestCount == 0 })
        #expect(store.imagePixelSize(for: item) != nil)
        #expect(store.imagePixelSize(for: other) != nil)
        #expect(store.cachedEntryCount == 2)
        #expect(store.debugFetchCompletionCount == 3)
    }
    #endif

    // MARK: - Fixtures

    /// One exact reference with a fixed literal UUID.
    private func reference(
        _ rawValue: String,
        version: UInt64
    ) -> HistoryItemReference {
        HistoryItemReference(
            id: HistoryItemID(rawValue: UUID(uuidString: rawValue)!),
            contentVersion: ContentVersion(rawValue: version)
        )
    }

    // MARK: - Prefetch round-trip (04 §9)

    /// `prefetch` decodes the scripted PNG into an eager raster retained under
    /// the exact reference, and is idempotent: two prefetches start one
    /// fetch. Before any prefetch, `imagePixelSize(for:)` is `nil` — the pure read
    /// never fetches.
    @Test func prefetchRoundTripsDecodedImageAndIsIdempotent() async throws {
        let item = reference(
            "00000000-0000-0000-0000-0000000000A1",
            version: 3
        )
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = ThumbnailStore(history: history)

        #expect(store.imagePixelSize(for: item) == nil)
        #expect(store.cachedDecodedBytes == 0)
        #expect(await history.requestCount(for: item) == 0)

        store.prefetch(item)
        store.prefetch(item)

        #expect(await pollUntil { store.imagePixelSize(for: item) != nil })
        let image = store.imagePixelSize(for: item)
        #expect(image?.width == 1)
        #expect(image?.height == 1)
        #expect(await history.requestCount(for: item) == 1)

        // ContentPreview's fixed BGRA8 artifact uses tight width×4 rows.
        let cost = try #require(image.map { $0.width * $0.height * 4 })
        #expect(store.cachedDecodedBytes == cost)
    }

    // MARK: - Reference-keyed exactness (04 §9)

    /// The cache key is the full reference: a second reference that differs
    /// only in Content Version never sees the first one's image — its own
    /// fetch answers `nil` (no thumbnailable content), which is
    /// negative-cached so the row's fallback icon stops re-asking.
    @Test func cacheIsKeyedByExactReferenceAndNegativeCachesNil() async throws {
        let original = reference(
            "00000000-0000-0000-0000-0000000000B1",
            version: 1
        )
        let revised = reference(
            "00000000-0000-0000-0000-0000000000B1",
            version: 2
        )
        let history = ThumbnailScriptHistory(pngByReference: [original: fixturePNGData])
        let store = ThumbnailStore(history: history)

        store.prefetch(original)
        try #require(await pollUntil { store.imagePixelSize(for: original) != nil })
        let originalByteCost = store.cachedDecodedBytes

        // The revised reference fetches its own answer: nil, no image.
        store.prefetch(revised)
        try #require(await pollUntil { store.liveRequestCount == 0 && store.pendingRequestCount == 0 })
        #expect(await history.requestCount(for: revised) == 1)
        #expect(store.imagePixelSize(for: revised) == nil)
        #expect(store.cachedEntryCount == 2)
        #expect(store.cachedDecodedBytes == originalByteCost)
        // The original's decoded pixels are untouched.
        #expect(store.imagePixelSize(for: original) != nil)

        // Negative caching of nil: a second prefetch of the revised
        // reference does not re-ask (stable negative — the .miss entry
        // blocks the fetch synchronously).
        store.prefetch(revised)
        #expect(store.inFlightCount == 0)
        #expect(await history.requestCount(for: revised) == 1)
    }

    // MARK: - Failure handling (04 §9)

    /// A non-stable typed failure is NOT cached: the reference stays eligible,
    /// so a later prefetch re-fetches (transient unavailability may
    /// recover).
    @Test(arguments: [
        HistoryFailure.temporarilyUnavailable(.dedupIndexRebuild),
        .persistence(.corruptStoredValue),
        .staleContent(expected: .initial, current: ContentVersion(rawValue: 2)),
    ])
    func thrownFetchFailuresAreNotCached(_ failure: HistoryFailure) async {
        let item = reference(
            "00000000-0000-0000-0000-0000000000C1",
            version: 1
        )
        let history = ThumbnailScriptHistory(
            failureByReference: [item: failure]
        )
        let store = ThumbnailStore(history: history)

        store.prefetch(item)
        #expect(await pollUntil { store.liveRequestCount == 0 && store.pendingRequestCount == 0 })
        #expect(await history.requestCount(for: item) == 1)

        store.prefetch(item)
        #expect(await pollUntil { await history.requestCount(for: item) == 2 })
        #expect(store.imagePixelSize(for: item) == nil)
        #expect(!store.isUnavailable(for: item))
    }

    enum MissPurge: Sendable {
        case reset, clearAll, clearUnpinned, remove, revision
    }

    @Test(arguments: [MissPurge.reset, .clearAll, .clearUnpinned, .remove, .revision])
    func existingPurgesReleaseTheUndecodableReference(_ purge: MissPurge) async throws {
        let item = reference("00000000-0000-0000-0000-0000000000C3", version: 1)
        let history = ThumbnailScriptHistory(failureByReference: [item: .thumbnailUnavailable])
        let store = ThumbnailStore(history: history)
        store.prefetch(item)
        try #require(await pollUntil { store.liveRequestCount == 0 && store.pendingRequestCount == 0 })
        try #require(store.cachedEntryCount == 1)
        #expect(store.isUnavailable(for: item))

        switch purge {
        case .reset: store.reset()
        case .clearAll: store.purge(.all)
        case .clearUnpinned: store.purge(.unpinned)
        case .remove: store.purge(.item(item.id))
        case .revision:
            store.purge(.revision(old: item, new: HistoryItemReference(
                id: item.id, contentVersion: ContentVersion(rawValue: 2)
            )))
        }
        #expect(store.cachedEntryCount == 0)
        #expect(!store.isUnavailable(for: item))
        store.prefetch(item)
        #expect(!store.isUnavailable(for: item))
        try #require(await pollUntil { store.liveRequestCount == 0 && store.pendingRequestCount == 0 })
        #expect(await history.requestCount(for: item) == 2)
        #expect(store.isUnavailable(for: item))
    }

    @Test func cancelledFetchRemainsEligibleForAnotherRequest() async throws {
        let item = reference("00000000-0000-0000-0000-0000000000C6", version: 1)
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 1 })
        #expect(await history.completeRequest(for: item, with: .cancelled))
        try #require(await pollUntil { store.liveRequestCount == 0 && store.pendingRequestCount == 0 })
        #expect(store.cachedEntryCount == 0)
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 2 })
        #expect(await history.completeRequest(for: item, occurrence: 1, with: .success(nil)))
        try #require(await pollUntil { store.liveRequestCount == 0 && store.pendingRequestCount == 0 })
    }

    @Test func unavailableResultsAndPurgesStayWithinTheirOwningSurface() async throws {
        let item = reference("00000000-0000-0000-0000-0000000000C7", version: 1)
        let history = ThumbnailScriptHistory(failureByReference: [item: .thumbnailUnavailable])
        let first = ThumbnailStore(history: history)
        let second = ThumbnailStore(history: history)
        first.prefetch(item)
        second.prefetch(item)
        try #require(await pollUntil { first.liveRequestCount == 0 && first.pendingRequestCount == 0 && second.liveRequestCount == 0 && second.pendingRequestCount == 0 })
        #expect(await history.requestCount(for: item) == 2)
        #expect(first.cachedEntryCount == 1)
        #expect(second.cachedEntryCount == 1)

        first.purge(.all)
        #expect(first.cachedEntryCount == 0)
        #expect(second.cachedEntryCount == 1)
        second.prefetch(item)
        #expect(second.inFlightCount == 0)
        #expect(await history.requestCount(for: item) == 2)
        first.prefetch(item)
        try #require(await pollUntil { first.liveRequestCount == 0 && first.pendingRequestCount == 0 })
        #expect(await history.requestCount(for: item) == 3)
    }

    /// `reset()` clears the whole cache — reads miss again and a prefetch
    /// re-fetches — while in-flight bookkeeping cannot strand the entry.
    @Test func resetClearsCachedImagesAndAllowsRefetch() async {
        let item = reference(
            "00000000-0000-0000-0000-0000000000D1",
            version: 1
        )
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = ThumbnailStore(history: history)

        store.prefetch(item)
        #expect(await pollUntil { store.imagePixelSize(for: item) != nil })
        #expect(await history.requestCount(for: item) == 1)

        store.reset()
        #expect(store.imagePixelSize(for: item) == nil)

        store.prefetch(item)
        #expect(await pollUntil { store.imagePixelSize(for: item) != nil })
        #expect(await history.requestCount(for: item) == 2)
    }

    #if DEBUG
    @Test func lateUnavailableResultCannotReplaceAnAlreadyPublishedNewFlight() async throws {
        let item = reference("00000000-0000-0000-0000-0000000000C8", version: 1)
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 1 })
        store.reset()
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 2 })

        #expect(await history.completeRequest(
            for: item, occurrence: 1, with: .success(fixturePNGData)
        ))
        try #require(await pollUntil { store.imagePixelSize(for: item) != nil })
        let producedSize = store.imagePixelSize(for: item)
        let producedBytes = store.cachedDecodedBytes
        #expect(producedBytes > 0)

        // The older request returns a cacheable negative only AFTER the new
        // request published pixels. It must not overwrite those pixels with
        // a miss or alter the new result's byte accounting.
        #expect(await history.completeRequest(for: item, with: .failure(.thumbnailUnavailable)))
        try #require(await pollUntil { store.debugFetchCompletionCount == 2 })
        #expect(store.debugDiscardedFetchCompletionCount == 1)
        #expect(store.imagePixelSize(for: item) == producedSize)
        #expect(store.cachedDecodedBytes == producedBytes)
        #expect(store.cachedEntryCount == 1)
        #expect(store.inFlightCount == 0)
        store.prefetch(item)
        #expect(store.inFlightCount == 0)
        #expect(await history.requestCount == 2)
    }

    @Test func purgedLatePayloadSkipsDisplayDecodingAndNewRequestStillRenders() async throws {
        let item = reference("00000000-0000-0000-0000-0000000000DC", version: 1)
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)
        let probe = ThumbnailDisplayDecodeProbe()

        try await ContentPreviewDebugInstrumentation.$renderDidStart.withValue({
            await probe.record()
        }) {
            store.prefetch(item)
            try #require(await pollUntil { await history.requestCount == 1 })
            store.purge(.item(item.id))
            store.prefetch(item)
            try #require(await pollUntil { await history.requestCount == 2 })

            #expect(await history.completeRequest(for: item, with: .success(fixturePNGData)))
            try #require(await pollUntil { store.debugDiscardedFetchCompletionCount == 1 })
            #expect(await probe.count == 0)
            #expect(store.cachedEntryCount == 0)
            #expect(store.inFlightCount == 1)

            #expect(await history.completeRequest(
                for: item, occurrence: 1, with: .success(fixturePNGData)
            ))
            try #require(await pollUntil { store.imagePixelSize(for: item) != nil })
            #expect(await probe.count == 1)
            #expect(store.inFlightCount == 0)
        }
    }

    @Test(arguments: [MissPurge.reset, .clearAll, .clearUnpinned, .remove, .revision])
    func purgeCancelsActiveDisplayWorkAndAllowsSameReferenceRefetch(_ purge: MissPurge) async throws {
        let item = reference("00000000-0000-0000-0000-0000000000DD", version: 1)
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)
        let probe = ThumbnailDisplayCancellationProbe()

        try await ContentPreviewDebugInstrumentation.$renderDidStart.withValue({
            await probe.parkFirst()
        }) {
            try await exerciseDisplayCancellation(
                purge, item: item, history: history, store: store, probe: probe
            )
        }
    }

    @Test func lastAppearanceCancelsAnAlreadyStartedDisplayRaster() async throws {
        let item = reference("00000000-0000-0000-0000-0000000000E3", version: 1)
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)
        let probe = ThumbnailDisplayCancellationProbe()
        try await ContentPreviewDebugInstrumentation.$renderDidStart.withValue({
            await probe.parkFirst()
        }) {
            try await exerciseLastAppearanceDisplayCancellation(
                item: item, history: history, store: store, probe: probe
            )
        }
    }

    // Keep the scenario outside TaskLocal's generic operation closure, as
    // in exerciseDisplayCancellation's Swift 6.2 codegen workaround.
    private func exerciseLastAppearanceDisplayCancellation(
        item: HistoryItemReference, history: PausableThumbnailHistory,
        store: ThumbnailStore, probe: ThumbnailDisplayCancellationProbe
    ) async throws {
        store.setDisplayed(item, true)
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 1 })
        #expect(await history.completeRequest(for: item, with: .success(fixturePNGData)))
        let started = await probe.waitUntilFirstRenderStarts()
        if !started { await probe.resume() }
        try #require(started)
        store.setDisplayed(item, false)
        #expect(store.inFlightCount == 0)
        let cancelled = await probe.waitUntilCancellation()
        await probe.resume()
        #expect(cancelled)
        try #require(await pollUntil { store.debugDiscardedFetchCompletionCount == 1 })
        #expect(store.cachedEntryCount == 0)
        #expect(store.cachedDecodedBytes == 0)
    }

    @Test func nativeSlotTimeoutDoesNotRetainAnUnavailableResult() async throws {
        let first = reference("00000000-0000-0000-0000-0000000000DE", version: 1)
        let second = reference("00000000-0000-0000-0000-0000000000DF", version: 1)
        let history = ThumbnailScriptHistory(pngByReference: [first: fixturePNGData, second: fixturePNGData])
        let store = ThumbnailStore(history: history)
        let probe = ThumbnailDisplayCancellationProbe()
        try await ContentPreviewDebugInstrumentation.$renderDidStart.withValue({
            await probe.parkFirst()
        }) {
            try await exerciseNativeSlotTimeout(
                first: first, second: second, history: history, store: store, probe: probe
            )
        }
    }

    private func exerciseNativeSlotTimeout(
        first: HistoryItemReference,
        second: HistoryItemReference,
        history: ThumbnailScriptHistory,
        store: ThumbnailStore,
        probe: ThumbnailDisplayCancellationProbe
    ) async throws {
        store.prefetch(first)
        let started = await probe.waitUntilFirstRenderStarts()
        if !started { await probe.resume() }
        try #require(started)

        // The first native slot remains occupied until the second request's
        // real acquisition deadline expires. Its valid PNG must stay retryable.
        store.prefetch(second)
        let timedOut = await pollUntil { store.debugFetchCompletionCount == 1 }
        await probe.resume()
        try #require(timedOut)
        #expect(!store.isUnavailable(for: second))
        #expect(store.imagePixelSize(for: second) == nil)
        try #require(await pollUntil { store.liveRequestCount == 0 && store.pendingRequestCount == 0 })

        store.prefetch(second)
        try #require(await pollUntil { store.imagePixelSize(for: second) != nil })
        #expect(await history.requestCount(for: second) == 2)
        #expect(await probe.starts == 2)
    }

    /// Keep the assertion scenario outside TaskLocal's generic operation
    /// closure; the injected hook still propagates to every prefetch task.
    private func exerciseDisplayCancellation(
        _ purge: MissPurge,
        item: HistoryItemReference,
        history: PausableThumbnailHistory,
        store: ThumbnailStore,
        probe: ThumbnailDisplayCancellationProbe
    ) async throws {
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 1 })
        #expect(await history.completeRequest(for: item, with: .success(fixturePNGData)))
        let started = await probe.waitUntilFirstRenderStarts()
        // Always release the hook even if the assertion fails, so a
        // regression cannot strand a renderer task for the entire suite.
        if !started { await probe.resume() }
        try #require(started)

        switch purge {
        case .reset: store.reset()
        case .clearAll: store.purge(.all)
        case .clearUnpinned: store.purge(.unpinned)
        case .remove: store.purge(.item(item.id))
        case .revision:
            store.purge(.revision(old: item, new: HistoryItemReference(
                id: item.id, contentVersion: ContentVersion(rawValue: 2)
            )))
        }
        #expect(store.inFlightCount == 0)
        let cancelledBeforeCompletion = await probe.waitUntilCancellation()
        await probe.resume()
        #expect(cancelledBeforeCompletion)
        try #require(await pollUntil { store.debugDiscardedFetchCompletionCount == 1 })
        #expect(store.cachedEntryCount == 0)
        #expect(store.cachedDecodedBytes == 0)

        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 2 })
        #expect(await history.completeRequest(
            for: item, occurrence: 1, with: .success(fixturePNGData)
        ))
        try #require(await pollUntil { store.imagePixelSize(for: item) != nil })
        let renderStarts = await probe.starts
        #expect(renderStarts == 2)
        #expect(store.inFlightCount == 0)
    }

    /// Reset is a privacy purge boundary, not merely an entries dictionary
    /// clear (deep review Card 9B). Every old-generation flight is released
    /// from visible bookkeeping immediately; whether it later returns a hit,
    /// throws, or is cancelled, it cannot refill the cache or disturb a new
    /// same-reference flight. The new generation remains independently
    /// eligible and may publish its own result.
    @Test func resetInvalidatesEveryLateOutcomeAndAllowsSameReferenceRefetch() async throws {
        let successfulItem = reference(
            "00000000-0000-0000-0000-0000000000D2",
            version: 1
        )
        let failingItem = reference(
            "00000000-0000-0000-0000-0000000000D3",
            version: 1
        )
        let cancelledItem = reference(
            "00000000-0000-0000-0000-0000000000D4",
            version: 1
        )
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)

        store.prefetch(successfulItem)
        store.prefetch(failingItem)
        store.prefetch(cancelledItem)
        try #require(await pollUntil { await history.requestCount == 3 })
        #expect(store.inFlightCount == 3)

        store.reset()
        #expect(store.cachedEntryCount == 0)
        #expect(store.cachedDecodedBytes == 0)
        #expect(store.inFlightCount == 0)

        // Reset releases the exact key immediately, so a new-generation
        // request can start before the old non-cooperative request returns.
        store.prefetch(successfulItem)
        try #require(await pollUntil { await history.requestCount == 4 })
        #expect(store.inFlightCount == 1)

        #expect(
            await history.completeRequest(
                for: successfulItem,
                with: .success(fixturePNGData)
            )
        )
        #expect(
            await history.completeRequest(
                for: failingItem,
                with: .failure(.thumbnailUnavailable)
            )
        )
        #expect(
            await history.completeRequest(
                for: cancelledItem,
                with: .cancelled
            )
        )

        try #require(await pollUntil { store.debugFetchCompletionCount == 3 })
        #expect(store.debugDiscardedFetchCompletionCount == 3)
        #expect(store.imagePixelSize(for: successfulItem) == nil)
        #expect(store.cachedEntryCount == 0)
        #expect(store.cachedDecodedBytes == 0)
        #expect(store.inFlightCount == 1)

        #expect(
            await history.completeRequest(
                for: successfulItem,
                occurrence: 1,
                with: .success(fixturePNGData)
            )
        )
        #expect(await pollUntil { store.imagePixelSize(for: successfulItem) != nil })
        #expect(store.cachedEntryCount == 1)
        #expect(store.inFlightCount == 0)
    }

    /// Exact revision eviction releases only the old reference's flight. Its
    /// non-cooperative late completion cannot refill or consume a newer
    /// same-reference flight, while an unrelated request still publishes.
    @Test func exactPurgeFencesLateTargetWithoutInvalidatingUnrelatedFlight() async throws {
        let old = reference(
            "00000000-0000-0000-0000-0000000000D5",
            version: 1
        )
        let unrelated = reference(
            "00000000-0000-0000-0000-0000000000D6",
            version: 1
        )
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)

        store.prefetch(old)
        store.prefetch(unrelated)
        try #require(await pollUntil { await history.requestCount == 2 })

        let new = HistoryItemReference(
            id: old.id,
            contentVersion: ContentVersion(rawValue: 2)
        )
        store.purge(.revision(old: old, new: new))
        #expect(store.purgeGeneration == 1)
        #expect(store.inFlightCount == 1)
        store.prefetch(old)
        try #require(await pollUntil { await history.requestCount == 3 })

        #expect(
            await history.completeRequest(
                for: old,
                with: .success(fixturePNGData)
            )
        )
        #expect(
            await history.completeRequest(
                for: unrelated,
                with: .success(fixturePNGData)
            )
        )
        try #require(await pollUntil {
            store.debugFetchCompletionCount == 2
                && store.imagePixelSize(for: unrelated) != nil
        })
        #expect(store.imagePixelSize(for: old) == nil)
        #expect(store.debugDiscardedFetchCompletionCount == 1)
        #expect(store.inFlightCount == 1)

        #expect(
            await history.completeRequest(
                for: old,
                occurrence: 1,
                with: .success(fixturePNGData)
            )
        )
        #expect(await pollUntil { store.imagePixelSize(for: old) != nil })
        #expect(store.inFlightCount == 0)
    }

    /// The external-ingress handoff enters the same panel owner used by local
    /// receipts. An item-scoped remove fences every old-version target flight,
    /// preserves unrelated work, and immediately permits a same-key refetch.
    @Test func externalRemovePurgeFencesTargetFlightThroughPanelOwner() async throws {
        let removed = reference(
            "00000000-0000-0000-0000-0000000000DA",
            version: 1
        )
        let unrelated = reference(
            "00000000-0000-0000-0000-0000000000DB",
            version: 1
        )
        let history = PausableThumbnailHistory()
        let viewState = HistoryViewState(history: history)
        let previewState = PreviewPaneState(autoOpenDelay: .zero)
        let surface = HistoryPanelSurfaceState(
            history: history,
            previewState: previewState
        )
        let store = surface.thumbnails

        store.prefetch(removed)
        store.prefetch(unrelated)
        try #require(await pollUntil { await history.requestCount == 2 })

        let purge = viewState.acceptCommittedExternalRemoval(removed.id, position: .init(rawValue: 1))
        surface.apply(purge)
        #expect(store.purgeGeneration == 1)
        #expect(store.inFlightCount == 1)

        store.prefetch(removed)
        try #require(await pollUntil { await history.requestCount == 3 })
        #expect(
            await history.completeRequest(
                for: removed,
                with: .success(fixturePNGData)
            )
        )
        #expect(
            await history.completeRequest(
                for: unrelated,
                with: .success(fixturePNGData)
            )
        )
        try #require(await pollUntil {
            store.debugFetchCompletionCount == 2
                && store.imagePixelSize(for: unrelated) != nil
        })
        #expect(store.imagePixelSize(for: removed) == nil)
        #expect(store.debugDiscardedFetchCompletionCount == 1)
        #expect(store.inFlightCount == 1)

        #expect(
            await history.completeRequest(
                for: removed,
                occurrence: 1,
                with: .success(fixturePNGData)
            )
        )
        #expect(await pollUntil { store.imagePixelSize(for: removed) != nil })
        #expect(store.inFlightCount == 0)
    }

    #endif

    /// Capacity eviction is not a privacy purge. A completed insert may
    /// evict cold retained entries when the bound is crossed, but an unrelated
    /// visible-row request already in flight must remain eligible to publish.
    @Test func capacityEvictionDoesNotInvalidateUnrelatedFlights() async throws {
        let first = reference(
            "00000000-0000-0000-0000-0000000000E5",
            version: 1
        )
        let second = reference(
            "00000000-0000-0000-0000-0000000000E6",
            version: 1
        )
        let stillVisible = reference(
            "00000000-0000-0000-0000-0000000000E7",
            version: 1
        )
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(
            history: history,
            maximumEntries: 1,
            maximumDecodedBytes: 64 * 1_048_576
        )

        store.prefetch(first)
        store.prefetch(second)
        store.prefetch(stillVisible)
        try #require(await pollUntil { await history.requestCount == 3 })

        #expect(
            await history.completeRequest(
                for: first,
                with: .success(fixturePNGData)
            )
        )
        try #require(await pollUntil { store.imagePixelSize(for: first) != nil })
        #expect(store.inFlightCount == 2)

        #expect(
            await history.completeRequest(
                for: second,
                with: .success(fixturePNGData)
            )
        )
        try #require(await pollUntil { store.imagePixelSize(for: second) != nil })
        #expect(store.cachedEntryCount == 1)
        #expect(store.imagePixelSize(for: first) == nil)
        #expect(store.inFlightCount == 1)

        #expect(
            await history.completeRequest(
                for: stillVisible,
                with: .success(fixturePNGData)
            )
        )
        #expect(await pollUntil { store.imagePixelSize(for: stillVisible) != nil })
        #expect(store.inFlightCount == 0)
        #expect(store.cachedEntryCount == 1)
        #expect(store.purgeGeneration == 0)
    }
}

// MARK: - Pausable thumbnail boundary

/// Deterministic `ClipboardHistory.thumbnail` boundary for purge-generation
/// tests. Each request parks until the test chooses one semantically distinct
/// outcome; reference + occurrence selection permits an old and a new
/// generation of the same exact reference to coexist without depending on
/// unstructured-task scheduling order. Target-internal (not file-private) so
/// the ThumbnailMeasurement suite can drive the same parked boundary.
actor PausableThumbnailHistory: ClipboardHistory {
    func sourceApplications(_ request: HistorySourceApplicationRequest) async throws -> HistorySourceApplicationPage {
        // Thumbnail responses contain no application occurrence fixtures.
        throw HistoryFailure.temporarilyUnavailable(.factProof)
    }

    func backup(to directory: URL) async throws -> HistoryBackupReceipt {
        throw HistoryBackupFailure.writeFailed
    }

    func representation(_ request: HistoryRepresentationRequest) async throws -> HistoryRepresentation {
        Issue.record("Thumbnail flight tests must not read representation bytes")
        throw HistoryFailure.notFound(request.item.id)
    }

    func usage() async throws -> HistoryUsage {
        // This thumbnail-flight script has no retained-byte snapshot.
        throw HistoryFailure.temporarilyUnavailable(.factProof)
    }

    enum Completion: Sendable {
        case success(Data?)
        case failure(HistoryFailure)
        case cancelled
    }

    private struct Request: Sendable {
        let item: HistoryItemReference
        let pixels: PixelSize
    }

    private var requests: [Request] = []
    private var continuations: [Int: CheckedContinuation<ThumbnailPayload?, Error>] = [:]
    private var cancelledRequests: Set<Int> = []

    var requestCount: Int { requests.count }
    var cancellationCount: Int { cancelledRequests.count }

    private func recordCancellation(_ index: Int) { cancelledRequests.insert(index) }

    /// Releases one parked request. `false` makes a missing/already-released
    /// request observable to the test instead of silently hiding a fixture
    /// ordering error.
    func completeRequest(
        for item: HistoryItemReference,
        occurrence: Int = 0,
        with completion: Completion
    ) -> Bool {
        let matchingIndices = requests.indices.filter { requests[$0].item == item }
        guard matchingIndices.indices.contains(occurrence) else {
            return false
        }
        let index = matchingIndices[occurrence]
        guard let continuation = continuations.removeValue(forKey: index) else {
            return false
        }
        let request = requests[index]
        switch completion {
        case .success(let bytes):
            continuation.resume(
                returning: bytes.map {
                    ThumbnailPayload(
                        item: request.item,
                        pixels: request.pixels,
                        format: .png,
                        encodedBytes: $0
                    )
                }
            )
        case .failure(let failure):
            continuation.resume(throwing: failure)
        case .cancelled:
            continuation.resume(throwing: CancellationError())
        }
        return true
    }

    func perform(_ action: HistoryAction) async throws -> HistoryReceipt {
        .unchanged
    }

    func browse(_ request: HistoryBrowseRequest) async throws -> HistoryPage {
        HistoryPage(position: ChangePosition(rawValue: 0), rows: [], next: nil)
    }

    func observe(
        _ request: HistoryObservationRequest
    ) async -> AsyncThrowingStream<HistoryPage, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func copySources(
        for id: HistoryItemID, expectedCopyCount: UInt64, offset: Int
    ) async throws -> HistoryCopySourcePage {
        throw HistoryFailure.notFound(id)
    }

    func representationMetadata(
        for item: HistoryItemReference
    ) async throws -> [HistoryRepresentationMetadata] {
        let metadata = try await details(for: item.id)
        guard metadata.item == item else {
            throw HistoryFailure.staleContent(expected: item.contentVersion, current: metadata.item.contentVersion)
        }
        return metadata.effective
    }

    func details(for id: HistoryItemID) async throws -> HistoryDetails {
        throw HistoryFailure.notFound(id)
    }

    func pastePayload(for id: HistoryItemID) async throws -> PastePayload {
        throw HistoryFailure.notFound(id)
    }

    func thumbnail(
        for item: HistoryItemReference,
        pixels: PixelSize
    ) async throws -> ThumbnailPayload? {
        let index = requests.count
        requests.append(Request(item: item, pixels: pixels))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[index] = continuation
            }
        } onCancel: {
            // Observe cancellation without releasing the non-cooperative
            // fixture. The test still controls its real terminal response.
            Task { await self.recordCancellation(index) }
        }
    }

    func retentionConfiguration() async throws -> HistoryRetentionConfiguration {
        .newStoreDefaults
    }
}
