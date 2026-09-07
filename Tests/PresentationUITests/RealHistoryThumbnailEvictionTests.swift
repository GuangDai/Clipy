/// Actual History captures drive the per-surface cold-entry policy. Existing
/// measurement records distinguish retained reuse from another native decode.
import AppKit
import Foundation
import HistoryCore
import HistoryStorage
import Testing
@testable import PresentationUI

@MainActor
struct RealHistoryThumbnailEvictionTests {
    enum BindingLimit: Equatable, Sendable { case entries, bytes, both }

    @Test(arguments: [BindingLimit.entries, .bytes, .both])
    func repeatedRequestKeepsTheHotRasterWhenEitherBoundIsCrossed(_ limit: BindingLimit) async throws {
        let history = try await memoryHistory()
        let a = try await capture("hot A", png: fixturePNGData, into: history)
        let b = try await capture("cold B", png: fixturePNGData, into: history)
        let c = try await capture("new C", png: fixturePNGData, into: history)
        let directory = try measurementDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("thumbnail.jsonl")
        let store = ThumbnailStore(
            history: history,
            maximumEntries: limit == .bytes ? 10 : 2,
            maximumDecodedBytes: limit == .entries ? 64 : 8,
            measurement: ThumbnailMeasurement(fileURL: file)
        )
        try await complete(a, in: store)
        #expect(store.cachedDecodedBytes == 4, "The fixture is one BGRA8 pixel")
        try await complete(b, in: store)
        store.prefetch(a)
        try await complete(c, in: store)

        #expect(store.cachedEntryCount == 2)
        #expect(store.cachedDecodedBytes == 8)
        #expect(store.imagePixelSize(for: a) == PixelSize(width: 1, height: 1))
        #expect(store.imagePixelSize(for: b) == nil)
        #expect(store.imagePixelSize(for: c) == PixelSize(width: 1, height: 1))
        #expect(store.purgeGeneration == 0)
        store.prefetch(a)
        try await complete(b, in: store)
        #expect(store.imagePixelSize(for: a) != nil)
        #expect(store.imagePixelSize(for: c) == nil)
        #expect(store.cachedEntryCount == 2)
        #expect(store.cachedDecodedBytes == 8)
        let records = try records(at: file)
        #expect(count(.started, for: a, in: records) == 1)
        #expect(count(.rejectedRetained, for: a, in: records) == 2)
        #expect(count(.started, for: b, in: records) == 2)
        #expect(count(.started, for: c, in: records) == 1)
        let completions = records.filter { $0.event == .completed }
        #expect(completions.count == 4)
        #expect(completions.allSatisfy { $0.outcome == .hit })
    }

    @Test func renderReadsDoNotRefreshRecencyOrStartWork() async throws {
        let history = try await memoryHistory()
        let a = try await capture("read A", png: fixturePNGData, into: history)
        let b = try await capture("read B", png: fixturePNGData, into: history)
        let c = try await capture("read C", png: fixturePNGData, into: history)
        let store = ThumbnailStore(history: history, maximumEntries: 2, maximumDecodedBytes: 64)
        try await complete(a, in: store)
        try await complete(b, in: store)
        #expect(store.raster(for: a) != nil)
        #expect(store.imagePixelSize(for: a) != nil)
        #expect(!store.isUnavailable(for: a))
        #expect(store.inFlightCount == 0)
        try await complete(c, in: store)
        // The body-facing reads did not promote A. Only a prefetch request
        // would do so, as the A/B/A/C test above distinguishes directly.
        #expect(store.imagePixelSize(for: a) == nil)
        #expect(store.imagePixelSize(for: b) != nil)
        #expect(store.imagePixelSize(for: c) != nil)
    }

    @Test func hotNegativeResultSharesTheEntryBoundAndRetriesAfterColdEviction() async throws {
        let history = try await memoryHistory()
        let a = try await capture("unavailable A", png: Data([0x89, 0x50, 0x4E, 0x47]), into: history)
        let b = try await capture("image B", png: fixturePNGData, into: history)
        let c = try await capture("image C", png: fixturePNGData, into: history)
        let directory = try measurementDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("thumbnail.jsonl")
        let store = ThumbnailStore(
            history: history, maximumEntries: 2, maximumDecodedBytes: 64,
            measurement: ThumbnailMeasurement(fileURL: file)
        )
        try await complete(a, in: store)
        #expect(store.isUnavailable(for: a))
        try await complete(b, in: store)
        store.prefetch(a)
        try await complete(c, in: store)
        #expect(store.isUnavailable(for: a))
        #expect(store.imagePixelSize(for: b) == nil)
        #expect(store.imagePixelSize(for: c) != nil)
        #expect(store.cachedEntryCount == 2)
        #expect(store.cachedDecodedBytes == 4)

        // Reintroducing B now evicts older A; the next A request really
        // crosses History again and produces a new unavailable completion.
        try await complete(b, in: store)
        #expect(!store.isUnavailable(for: a))
        #expect(store.cachedDecodedBytes == 8)
        try await complete(a, in: store)
        #expect(store.isUnavailable(for: a))
        #expect(store.imagePixelSize(for: b) != nil)
        #expect(store.imagePixelSize(for: c) == nil)
        #expect(store.cachedEntryCount == 2)
        #expect(store.cachedDecodedBytes == 4)
        #expect(store.purgeGeneration == 0)
        let records = try records(at: file)
        #expect(count(.started, for: a, in: records) == 2)
        #expect(count(.rejectedRetained, for: a, in: records) == 1)
        #expect(records.filter {
            $0.refID == a.id.rawValue.uuidString && $0.event == .completed
        }.map(\.outcome) == [.miss, .miss])
    }

    @Test func bytePressureEvictsEnoughColdEntriesButKeepsTheHotRaster() async throws {
        let history = try await memoryHistory()
        let a = try await capture("byte A", png: fixturePNGData, into: history)
        let b = try await capture("byte B", png: fixturePNGData, into: history)
        let c = try await capture("byte C", png: fixturePNGData, into: history)
        let d = try await capture("two pixels", png: twoPixelPNG(), into: history)
        let store = ThumbnailStore(history: history, maximumEntries: 10, maximumDecodedBytes: 12)
        for item in [a, b, c] { try await complete(item, in: store) }
        #expect(store.cachedDecodedBytes == 12)
        store.prefetch(a)
        try await complete(d, in: store)
        #expect(store.cachedEntryCount == 2)
        #expect(store.cachedDecodedBytes == 12)
        #expect(store.imagePixelSize(for: a) == PixelSize(width: 1, height: 1))
        #expect(store.imagePixelSize(for: b) == nil)
        #expect(store.imagePixelSize(for: c) == nil)
        #expect(store.imagePixelSize(for: d) == PixelSize(width: 2, height: 1))
    }

    @Test func individuallyOversizedRasterDoesNotEvictAnExistingHotEntry() async throws {
        let history = try await memoryHistory()
        let hot = try await capture("small hot", png: fixturePNGData, into: history)
        let oversized = try await capture("oversized", png: twoPixelPNG(), into: history)
        let directory = try measurementDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("thumbnail.jsonl")
        let store = ThumbnailStore(
            history: history, maximumEntries: 10, maximumDecodedBytes: 4,
            measurement: ThumbnailMeasurement(fileURL: file)
        )
        try await complete(hot, in: store)
        try await complete(oversized, in: store)
        #expect(store.imagePixelSize(for: hot) == PixelSize(width: 1, height: 1))
        #expect(store.imagePixelSize(for: oversized) == nil)
        #expect(!store.isUnavailable(for: oversized))
        #expect(store.cachedEntryCount == 1)
        #expect(store.cachedDecodedBytes == 4)
        store.prefetch(hot)
        try await complete(oversized, in: store)
        #expect(store.imagePixelSize(for: hot) != nil)
        #expect(store.cachedDecodedBytes == 4)
        let records = try records(at: file)
        #expect(count(.started, for: hot, in: records) == 1)
        #expect(count(.started, for: oversized, in: records) == 2)
        let produced = records.filter {
            $0.refID == oversized.id.rawValue.uuidString && $0.event == .completed
        }
        #expect(produced.count == 2)
        #expect(produced.allSatisfy { $0.outcome == .hit && $0.rasterWidth == 2 && $0.rasterHeight == 1 })
    }

    @Test func cancelledViewTaskDoesNotStartAThumbnailRequest() async throws {
        let history = try await memoryHistory()
        let item = try await capture("cancelled request", png: fixturePNGData, into: history)
        let directory = try measurementDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("thumbnail.jsonl")
        let store = ThumbnailStore(
            history: history, maximumEntries: 2, maximumDecodedBytes: 64,
            measurement: ThumbnailMeasurement(fileURL: file)
        )
        // No suspension before cancellation: the child is already cancelled
        // when its inherited MainActor body reaches the synchronous prefetch.
        let retiredViewTask = Task { store.prefetch(item) }
        retiredViewTask.cancel()
        await retiredViewTask.value
        #expect(store.inFlightCount == 0)
        #expect(store.cachedEntryCount == 0)
        #expect(!store.isUnavailable(for: item))
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "A cancelled request must not emit even a started event")

        try await complete(item, in: store)
        #expect(store.imagePixelSize(for: item) == PixelSize(width: 1, height: 1))
        let records = try records(at: file)
        #expect(count(.started, for: item, in: records) == 1)
        #expect(count(.completed, for: item, in: records) == 1)
        #expect(count(.rejectedRetained, for: item, in: records) == 0)
        #expect(count(.rejectedInFlight, for: item, in: records) == 0)
    }

    @Test func cancelledViewTaskDoesNotPromoteAColdRetainedRaster() async throws {
        let history = try await memoryHistory()
        let a = try await capture("cancelled cold A", png: fixturePNGData, into: history)
        let b = try await capture("current B", png: fixturePNGData, into: history)
        let c = try await capture("current C", png: fixturePNGData, into: history)
        let store = ThumbnailStore(history: history, maximumEntries: 2, maximumDecodedBytes: 64)
        try await complete(a, in: store)
        try await complete(b, in: store)
        let retiredViewTask = Task { store.prefetch(a) }
        retiredViewTask.cancel()
        await retiredViewTask.value
        try await complete(c, in: store)
        #expect(store.imagePixelSize(for: a) == nil)
        #expect(store.imagePixelSize(for: b) == PixelSize(width: 1, height: 1))
        #expect(store.imagePixelSize(for: c) == PixelSize(width: 1, height: 1))
        #expect(store.cachedEntryCount == 2)
        #expect(store.cachedDecodedBytes == 8)
        #expect(store.purgeGeneration == 0)
    }

    @Test func memoryWarningDropsOnlyColdThumbnailsAndCriticalWaitsForNormal() async throws {
        let history = try await memoryHistory()
        let hot = try await capture("visible", png: fixturePNGData, into: history)
        let cold = try await capture("offscreen", png: fixturePNGData, into: history)
        let store = ThumbnailStore(history: history)
        try await complete(hot, in: store)
        try await complete(cold, in: store)
        store.setDisplayed(hot, true)
        let before = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        let retention = try await history.retentionConfiguration()

        store.respondToMemoryPressure(.warning)
        #expect(store.imagePixelSize(for: hot) != nil)
        #expect(store.imagePixelSize(for: cold) == nil)
        #expect(store.cachedEntryCount == 1)
        #expect(store.cachedDecodedBytes == 4)
        #expect(!store.isPrefetchSuspended)

        store.respondToMemoryPressure(.critical)
        #expect(store.cachedEntryCount == 0)
        #expect(store.cachedDecodedBytes == 0)
        store.prefetch(hot)
        #expect(store.inFlightCount == 0)
        store.respondToMemoryPressure(.warning)
        store.prefetch(hot)
        #expect(store.isPrefetchSuspended)
        #expect(store.inFlightCount == 0)

        store.respondToMemoryPressure(.normal)
        try await complete(hot, in: store)
        #expect(store.imagePixelSize(for: hot) != nil)
        let after = try await history.browse(HistoryBrowseRequest(kind: .recent, limit: 10))
        #expect(after.rows == before.rows)
        #expect(try await history.retentionConfiguration() == retention)
        #expect(try await history.pastePayload(for: hot.id).item == hot)
    }

    @Test func criticalPressureRetiresOutstandingThumbnailWorkBeforeItCanPublish() async throws {
        let history = try await memoryHistory()
        let item = try await capture("pending", png: fixturePNGData, into: history)
        let store = ThumbnailStore(history: history)
        store.prefetch(item)
        #expect(store.inFlightCount == 1)
        store.respondToMemoryPressure(.critical)
        #expect(store.inFlightCount == 0)
        try #require(await pollUntil { store.debugFetchCompletionCount == 1 })
        #expect(store.debugDiscardedFetchCompletionCount == 1)
        #expect(store.cachedEntryCount == 0)
        #expect(store.cachedDecodedBytes == 0)
        store.respondToMemoryPressure(.normal)
        try await complete(item, in: store)
        #expect(store.imagePixelSize(for: item) != nil)
    }

    @Test func hiddenSurfaceIsColdAndNormalDoesNotRestartItsPrefetch() async throws {
        let history = try await memoryHistory()
        let item = try await capture("hidden", png: fixturePNGData, into: history)
        let store = ThumbnailStore(history: history)
        store.setDisplayed(item, true)
        try await complete(item, in: store)
        // NSPanel ordering out can retain its SwiftUI rows. Session closure,
        // not only row disappearance, must make all those entries cold.
        store.isSurfaceActive = false
        store.respondToMemoryPressure(.warning)
        #expect(store.cachedEntryCount == 0)
        store.respondToMemoryPressure(.critical)
        store.respondToMemoryPressure(.normal)
        store.prefetch(item)
        #expect(store.inFlightCount == 0)
        store.isSurfaceActive = true
        try await complete(item, in: store)
        #expect(store.imagePixelSize(for: item) != nil)
    }

    @Test func repeatedWarningPublishesANewSurfaceGenerationAndTrimsNewColdEntries() async throws {
        let history = try await memoryHistory()
        let item = try await capture("cold after warning", png: fixturePNGData, into: history)
        let surface = HistoryPanelSurfaceState(history: history, previewState: PreviewPaneState())
        let detailsThumbnails = ThumbnailStore(history: history, pixels: PixelSize(width: 128, height: 128))
        surface.respondToMemoryPressure(.warning)
        let firstGeneration = surface.memoryPressureGeneration
        detailsThumbnails.respondToMemoryPressure(surface.memoryPressure)
        try await complete(item, in: surface.thumbnails)
        try await complete(item, in: detailsThumbnails)

        surface.respondToMemoryPressure(.warning)
        #expect(surface.memoryPressure == .warning)
        #expect(surface.memoryPressureGeneration == firstGeneration + 1,
                "Child environment consumers must receive the second warning too")
        // Details uses the generation change to apply the latest level; row
        // prefetch tasks still observe only suspension, so warning cannot
        // automatically rebuild the cold entries it just released.
        detailsThumbnails.respondToMemoryPressure(surface.memoryPressure)
        #expect(surface.thumbnails.cachedEntryCount == 0)
        #expect(detailsThumbnails.cachedEntryCount == 0)
        #expect(surface.thumbnails.inFlightCount == 0)
        #expect(detailsThumbnails.inFlightCount == 0)
    }

    private func memoryHistory() async throws -> SQLiteHistory {
        try await SQLiteHistory.open(configuration: HistoryConfiguration(persistence: .temporary))
    }

    private func capture(_ label: String, png: Data, into history: SQLiteHistory) async throws -> HistoryItemReference {
        let receipt = try await history.perform(.capture(ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "public.png", bytes: png),
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data(label.utf8)),
            ],
            origin: CopyOriginObservation(sourceApplication: nil, lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 700_093_000)
        )))
        guard case let .committed(commit) = receipt, case let .inserted(item) = commit.outcome else {
            throw FixtureFailure.expectedInsert
        }
        return item
    }

    private func complete(_ item: HistoryItemReference, in store: ThumbnailStore) async throws {
        store.prefetch(item)
        try #require(await pollUntil { store.inFlightCount == 0 })
    }

    private func twoPixelPNG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.setColor(.red, atX: 0, y: 0)
        bitmap.setColor(.blue, atX: 1, y: 0)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func measurementDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func records(at file: URL) throws -> [ThumbnailMeasurement.Record] {
        try Data(contentsOf: file).split(separator: 0x0A).map {
            try JSONDecoder().decode(ThumbnailMeasurement.Record.self, from: Data($0))
        }
    }

    private func count(
        _ event: ThumbnailMeasurement.Event, for item: HistoryItemReference,
        in records: [ThumbnailMeasurement.Record]
    ) -> Int {
        records.filter { $0.refID == item.id.rawValue.uuidString && $0.event == event }.count
    }

    private enum FixtureFailure: Error { case expectedInsert }
}
