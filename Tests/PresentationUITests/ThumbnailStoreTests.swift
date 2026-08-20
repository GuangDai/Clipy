/// ThumbnailStoreTests — the panel thumbnail store acceptance suite
/// (docs/01-architecture.md §5.7; docs/04-coherence.md §9; docs/
/// roadmap/05-presentationui.md), driven by a scripted `ClipboardHistory`
/// double that answers one fixed encoded 1×1 PNG per exact reference.
///
/// Pinned semantics: `image(for:)` is a pure read that never fetches;
/// `prefetch(_:)` is idempotent per reference and decodes the encoded bytes
/// on the MainActor into a `CGImage` cached under the EXACT requesting
/// reference (id + Content Version — a revised item never sees stale
/// pixels); a `nil` payload is negative-cached while a thrown failure is
/// NOT (transient unavailability may recover); `reset()` clears everything.
/// `likelyThumbnailable` mirrors the frozen v1 ImageIO-decodable UTI set
/// that gates prefetch.
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

    /// `prefetch` decodes the scripted PNG into a `CGImage` cached under the
    /// exact reference, and is idempotent: two prefetches start one fetch.
    /// Before any prefetch, `image(for:)` is `nil` — the pure read never
    /// fetches.
    @Test func prefetchRoundTripsDecodedImageAndIsIdempotent() async {
        let item = reference(
            "00000000-0000-0000-0000-0000000000A1",
            version: 3
        )
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = ThumbnailStore(history: history)

        #expect(store.image(for: item) == nil)
        #expect(await history.requestCount(for: item) == 0)

        store.prefetch(item)
        store.prefetch(item)

        #expect(await pollUntil { store.image(for: item) != nil })
        let image = store.image(for: item)
        #expect(image?.width == 1)
        #expect(image?.height == 1)
        #expect(await history.requestCount(for: item) == 1)
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

    /// The whole-cache ceiling is a hard bound: with `maximumEntries: 3`,
    /// four completed fetches leave at most 3 cached entries. The eviction
    /// check runs AFTER insertion (insert-then-evict); the pre-insertion
    /// `>` check it replaced let the cache reach `maximumEntries + 1`
    /// (audit 2026-08-20: a 500-entry cache could hold 501).
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
