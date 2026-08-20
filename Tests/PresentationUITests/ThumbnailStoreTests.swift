/// ThumbnailStoreTests — the panel thumbnail store acceptance suite
/// (docs/01-architecture.md §5.7; docs/04-coherence.md §9; docs/
/// roadmap/05-presentationui.md), driven by a scripted `ClipboardHistory`
/// double that answers one fixed encoded 1×1 PNG per exact reference.
///
/// Pinned semantics: `image(for:)` is a pure read that never fetches;
/// `prefetch(_:)` is idempotent per reference and decodes the encoded bytes
/// OFF the MainActor (through the internal `DisplayImageDecoder` actor —
/// audit 2026-08-20 §S-2/§SPEC-IMPL-002) into a `CGImage` retained under the
/// EXACT requesting reference (id + Content Version — a revised item never
/// sees stale pixels); a `nil` payload is negative-retained while a thrown
/// failure is NOT (transient unavailability may recover); `reset()` clears
/// everything. Retention is bounded by entry count AND decoded bytes
/// (audit 2026-08-20 §S-3/§SPEC-IMPL-001 — the admission record lives in
/// ThumbnailStore.swift's header). `likelyThumbnailable` mirrors the frozen
/// v1 ImageIO-decodable UTI set that gates prefetch.
import CoreGraphics
import Foundation
import HistoryCore
import PresentationUI
import Testing

@MainActor
struct ThumbnailStoreTests {

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

    /// `prefetch` decodes the scripted PNG into a `CGImage` retained under
    /// the exact reference, and is idempotent: two prefetches start one
    /// fetch. Before any prefetch, `image(for:)` is `nil` — the pure read
    /// never fetches.
    @Test func prefetchRoundTripsDecodedImageAndIsIdempotent() async throws {
        let item = reference(
            "00000000-0000-0000-0000-0000000000A1",
            version: 3
        )
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = ThumbnailStore(history: history)

        #expect(store.image(for: item) == nil)
        #expect(store.cachedDecodedBytes == 0)
        #expect(await history.requestCount(for: item) == 0)

        store.prefetch(item)
        store.prefetch(item)

        #expect(await pollUntil { store.image(for: item) != nil })
        let image = store.image(for: item)
        #expect(image?.width == 1)
        #expect(image?.height == 1)
        #expect(await history.requestCount(for: item) == 1)

        // The byte half of the admission bound accounts the backing bitmap
        // exactly (bytesPerRow × height, padding included).
        let cost = try #require(image.map { $0.bytesPerRow * $0.height })
        #expect(store.cachedDecodedBytes == cost)
    }

    // MARK: - Reference-keyed exactness (04 §9)

    /// The cache key is the full reference: a second reference that differs
    /// only in Content Version never sees the first one's image — its own
    /// fetch answers `nil` (no thumbnailable content), which is
    /// negative-cached so the row's fallback icon stops re-asking.
    @Test func cacheIsKeyedByExactReferenceAndNegativeCachesNil() async {
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
        #expect(await pollUntil { store.image(for: original) != nil })

        // The revised reference fetches its own answer: nil, no image.
        store.prefetch(revised)
        #expect(await pollUntil { await history.requestCount(for: revised) == 1 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(store.image(for: revised) == nil)
        // The original's decoded pixels are untouched.
        #expect(store.image(for: original) != nil)

        // Negative caching of nil: a second prefetch of the revised
        // reference does not re-ask (stable negative — the .miss entry
        // blocks the fetch synchronously).
        store.prefetch(revised)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await history.requestCount(for: revised) == 1)
    }

    // MARK: - Failure handling (04 §9)

    /// A thrown typed failure is NOT cached: the reference stays eligible,
    /// so a later prefetch re-fetches (transient unavailability may
    /// recover).
    @Test func thrownFetchFailuresAreNotCached() async {
        let item = reference(
            "00000000-0000-0000-0000-0000000000C1",
            version: 1
        )
        let history = ThumbnailScriptHistory(
            failureByReference: [item: .temporarilyUnavailable(.dedupIndexRebuild)]
        )
        let store = ThumbnailStore(history: history)

        store.prefetch(item)
        #expect(await pollUntil { await history.requestCount(for: item) == 1 })
        // Let the failure path finish (it removes the in-flight marker
        // without recording an entry).
        try? await Task.sleep(for: .milliseconds(150))

        store.prefetch(item)
        #expect(await pollUntil { await history.requestCount(for: item) == 2 })
        #expect(store.image(for: item) == nil)
    }

    // MARK: - Reset (04 §9)

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
        #expect(await pollUntil { store.image(for: item) != nil })
        #expect(await history.requestCount(for: item) == 1)

        store.reset()
        #expect(store.image(for: item) == nil)

        store.prefetch(item)
        #expect(await pollUntil { store.image(for: item) != nil })
        #expect(await history.requestCount(for: item) == 2)
    }

    // MARK: - Cache ceiling (04 §9 step 7)

    /// The whole-store entry ceiling is a hard bound: with
    /// `maximumEntries: 3`, four completed fetches leave at most 3 retained
    /// entries. The eviction check runs AFTER insertion
    /// (insert-then-evict); the pre-insertion `>` check it replaced let the
    /// store reach `maximumEntries + 1` (audit 2026-08-20: a 500-entry
    /// store could hold 501).
    @Test func cacheNeverExceedsItsConfiguredMaximum() async {
        let items = [
            reference("00000000-0000-0000-0000-0000000000E1", version: 1),
            reference("00000000-0000-0000-0000-0000000000E2", version: 1),
            reference("00000000-0000-0000-0000-0000000000E3", version: 1),
            reference("00000000-0000-0000-0000-0000000000E4", version: 1),
        ]
        let history = ThumbnailScriptHistory(
            pngByReference: Dictionary(
                uniqueKeysWithValues: items.map { ($0, fixturePNGData) }
            )
        )
        let store = ThumbnailStore(history: history, maximumEntries: 3)

        for item in items {
            store.prefetch(item)
        }

        // Quiescence: every scripted fetch answered and every completion
        // landed (the in-flight set empties only in `store`/failure paths).
        #expect(await pollUntil {
            for item in items where await history.requestCount(for: item) != 1 {
                return false
            }
            return store.inFlightCount == 0
        })
        #expect(store.cachedEntryCount <= 3)
    }

    // MARK: - Decoded-byte bound (audit 2026-08-20 §S-3/§SPEC-IMPL-001)

    /// The decoded-byte ceiling is a hard second bound: with
    /// `maximumDecodedBytes: 1`, one decoded hit already exceeds it, so the
    /// whole store resets to zero entries AND zero retained bytes. (The
    /// reset is the same order-independent whole-store discipline as the
    /// entry ceiling.)
    @Test func byteBudgetResetsTheWholeStore() async {
        let item = reference("00000000-0000-0000-0000-0000000000F1", version: 1)
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = ThumbnailStore(history: history, maximumDecodedBytes: 1)

        store.prefetch(item)
        #expect(await pollUntil { store.inFlightCount == 0 && (await history.requestCount(for: item)) == 1 })
        #expect(store.image(for: item) == nil)
        #expect(store.cachedEntryCount == 0)
        #expect(store.cachedDecodedBytes == 0)
    }

    /// A recorded miss costs zero decoded bytes, so a tight byte budget
    /// still retains it — the negative result keeps the row's fallback icon
    /// from re-asking without spending the byte bound.
    @Test func missesCarryNoDecodedBytes() async {
        let item = reference("00000000-0000-0000-0000-0000000000F2", version: 1)
        let history = ThumbnailScriptHistory()  // unscripted: nil payload → miss
        let store = ThumbnailStore(history: history, maximumDecodedBytes: 1)

        store.prefetch(item)
        #expect(await pollUntil { store.inFlightCount == 0 && (await history.requestCount(for: item)) == 1 })
        #expect(store.cachedEntryCount == 1)
        #expect(store.cachedDecodedBytes == 0)
    }

    // MARK: - Prefetch gate (04 §9)

    /// The cheap UTI heuristic answers true exactly when some type is in
    /// the frozen v1 ImageIO-decodable set — the prefetch filter that keeps
    /// text rows from ever starting thumbnail flights.
    @Test func likelyThumbnailableMatchesTheFrozenImageTypeSet() {
        #expect(ThumbnailStore.likelyThumbnailable(["public.png"]))
        #expect(
            ThumbnailStore.likelyThumbnailable(
                ["public.utf8-plain-text", "public.tiff"]
            )
        )
        #expect(
            ThumbnailStore.likelyThumbnailable(
                ["com.compuserve.gif", "public.jpeg", "public.heic", "public.heif", "com.microsoft.bmp"]
            )
        )
        #expect(!ThumbnailStore.likelyThumbnailable(["public.utf8-plain-text"]))
        #expect(!ThumbnailStore.likelyThumbnailable(["com.adobe.pdf", "public.url"]))
        #expect(!ThumbnailStore.likelyThumbnailable([]))
    }
}
