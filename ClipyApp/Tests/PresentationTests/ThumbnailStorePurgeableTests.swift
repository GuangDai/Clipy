import Foundation
@testable import HistoryCore
import Testing
@testable import ClipyApp

@Suite("ThumbnailStore discardable cold pixels", .serialized)
@MainActor
struct ThumbnailStorePurgeableTests {
    private func reference(_ version: UInt64 = 1) -> HistoryItemReference {
        HistoryItemReference(id: HistoryItemID(rawValue: UUID()), contentVersion: ContentVersion(rawValue: version))
    }

    #if DEBUG
    @Test(arguments: [false, true])
    func coldLossRebuildsWhileAnIndependentRasterCopySurvives(removeCacheEntry: Bool) async throws {
        let item = reference()
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = ThumbnailStore(history: history, maximumEntries: 2, maximumDecodedBytes: 8)
        store.setDisplayed(item, true)
        store.prefetch(item)
        try #require(await pollUntil { store.imagePixelSize(for: item) != nil })
        let original = try #require(store.raster(for: item))
        #expect(store.activeDecodedBytes == 4)
        #expect(store.coldDecodedBytes == 0)

        store.setDisplayed(item, false)
        #expect(store.activeDecodedBytes == 0)
        #expect(store.coldDecodedBytes == 4)
        // Read the cold buffer once, then discard it. The returned Data must
        // be independent, and the read's begin/end pair must not pin the cache.
        let copied = try #require(store.raster(for: item))
        if removeCacheEntry { store.removeColdEntryForTesting(item) }
        else { store.discardColdPixelsForTesting(item) }
        #expect(store.imagePixelSize(for: item) == nil)
        #expect(store.cachedDecodedBytes == 0)
        #expect(!store.isUnavailable(for: item), "Discarded pixels are a cache miss, not unsupported content")
        #expect(copied == original)
        #expect(!copied.pixels.isEmpty)

        store.setDisplayed(item, true)
        try #require(await pollUntil { store.imagePixelSize(for: item) != nil })
        #expect(await history.requestCount(for: item) == 2)
        #expect(store.raster(for: item) == original)
        #expect(store.activeDecodedBytes == 4)
        #expect(store.coldDecodedBytes == 0)
        #expect(store.cachedEntryCount == 1)
    }
    @Test func completionAfterSurfaceCloseRetainsOnlyDiscardableColdPixels() async throws {
        let item = reference()
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history, maximumEntries: 2, maximumDecodedBytes: 8)
        store.setDisplayed(item, true)
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 1 })

        // The reused hidden NSPanel may not send a row disappearance yet.
        // Surface closure alone must prevent late completion from pinning Data.
        store.isSurfaceActive = false
        #expect(await history.completeRequest(for: item, with: .success(fixturePNGData)))
        try #require(await pollUntil { store.inFlightCount == 0 })
        #expect(store.imagePixelSize(for: item) != nil)
        #expect(store.activeDecodedBytes == 0)
        #expect(store.coldDecodedBytes == 4)

        store.discardColdPixelsForTesting(item)
        #expect(store.imagePixelSize(for: item) == nil)
        #expect(store.activeDecodedBytes == 0)
        #expect(store.cachedDecodedBytes == 0)
        store.prefetch(item)
        #expect(await history.requestCount == 1, "A closed surface does not restart a discarded fetch")
    }
    #endif

    @Test func visiblePixelsRemainIndependentOfColdEvictionAndMemoryPressure() async throws {
        let visible = reference()
        let cold = reference()
        let history = ThumbnailScriptHistory(pngByReference: [visible: fixturePNGData, cold: fixturePNGData])
        let store = ThumbnailStore(history: history, maximumEntries: 2, maximumDecodedBytes: 8)
        store.setDisplayed(visible, true)
        store.prefetch(visible)
        store.prefetch(cold)
        try #require(await pollUntil { store.inFlightCount == 0 })
        #expect(store.activeDecodedBytes == 4)
        #expect(store.coldDecodedBytes == 4)
        let raster = try #require(store.raster(for: visible))
        #if DEBUG
        store.removeColdEntryForTesting(visible)
        #endif
        #expect(store.raster(for: visible) == raster)
        store.respondToMemoryPressure(.warning)
        #expect(store.raster(for: visible) == raster)
        #expect(store.imagePixelSize(for: cold) == nil)
        #expect(store.cachedDecodedBytes == 4)
        #expect(store.activeDecodedBytes == 4)
        #expect(store.coldDecodedBytes == 0)

        store.isSurfaceActive = false
        #expect(store.activeDecodedBytes == 0)
        #expect(store.coldDecodedBytes == 4)
        store.respondToMemoryPressure(.critical)
        #expect(store.cachedDecodedBytes == 0)
        #expect(store.activeDecodedBytes == 0)
        #expect(store.cachedEntryCount == 0)
    }

    @Test func coldAdmissionCannotDisplaceVisibleBytesToExceedTheHardBudget() async throws {
        let visible = reference()
        let newcomer = reference()
        let history = ThumbnailScriptHistory(pngByReference: [visible: fixturePNGData, newcomer: fixturePNGData])
        let store = ThumbnailStore(history: history, maximumEntries: 2, maximumDecodedBytes: 4)
        store.setDisplayed(visible, true)
        store.prefetch(visible)
        try #require(await pollUntil { store.imagePixelSize(for: visible) != nil })
        store.prefetch(newcomer)
        try #require(await pollUntil { store.inFlightCount == 0 })
        #expect(store.imagePixelSize(for: visible) != nil)
        #expect(store.imagePixelSize(for: newcomer) == nil)
        #expect(store.activeDecodedBytes == 4)
        #expect(store.cachedDecodedBytes == 4)
        #expect(store.cachedEntryCount == 1)
        #expect(store.purgeGeneration == 0)
    }

    @Test func overlappingRowsKeepPixelsUntilTheLastAppearanceEnds() async throws {
        let item = reference()
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = ThumbnailStore(history: history)
        store.setDisplayed(item, true)
        store.prefetch(item)
        try #require(await pollUntil { store.imagePixelSize(for: item) != nil })
        let raster = try #require(store.raster(for: item))

        // Section replacement may mount the pinned row before the old
        // recent row disappears. One appearance still owns these pixels.
        store.setDisplayed(item, true)
        store.setDisplayed(item, false)
        store.respondToMemoryPressure(.warning)
        #expect(store.raster(for: item) == raster)
        #expect(store.activeDecodedBytes == 4)
        store.prefetch(item)
        #expect(store.inFlightCount == 0)
        #expect(await history.requestCount(for: item) == 1)

        store.setDisplayed(item, false)
        #expect(store.activeDecodedBytes == 0)
        store.respondToMemoryPressure(.warning)
        #expect(store.cachedEntryCount == 0)
    }

    @Test func overlappingRowsPreservePendingWorkAcrossMemoryWarning() async throws {
        let item = reference()
        let history = PausableThumbnailHistory()
        let store = ThumbnailStore(history: history)
        store.setDisplayed(item, true)
        store.prefetch(item)
        try #require(await pollUntil { await history.requestCount == 1 })
        store.setDisplayed(item, true)
        store.setDisplayed(item, false)
        store.respondToMemoryPressure(.warning)
        #expect(store.inFlightCount == 1)
        #expect(await history.completeRequest(for: item, with: .success(fixturePNGData)))
        try #require(await pollUntil { store.inFlightCount == 0 })
        #expect(store.activeDecodedBytes == 4)
        #expect(store.imagePixelSize(for: item) == PixelSize(width: 1, height: 1))

        store.setDisplayed(item, false)
        store.respondToMemoryPressure(.warning)
        #expect(store.cachedEntryCount == 0)
    }
}
