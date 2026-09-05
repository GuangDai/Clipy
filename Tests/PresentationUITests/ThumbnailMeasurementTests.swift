/// ThumbnailMeasurementTests — owner suite for the DEC-THUMB-CACHE G1
/// evidence sink (docs/06-cross-cutting.md §3 G1; docs/reviews/
/// 2026-08-22-clipy-maccy-deep-review/05-evidence-and-open-questions.md §6
/// "Completed thumbnail cache" row; 11 §4.7). The sink lives in
/// ThumbnailStore.swift, DEBUG-only and package-scoped (Batch 39 posture);
/// these tests prove its RECORDING semantics through the same scripted
/// doubles as ThumbnailStoreTests: one started/completed pair per flight,
/// duplicate requests recorded as rejections without new flights, the
/// Card 9B discarded boundary, whole-store eviction as the repeat-decode
/// input, and the envelope gate.
///
/// Every duration assertion is presence/non-negativity only — this suite
/// never adjudicates a threshold (G1 stays with 06 §3 G1 + docs/v2/V2-07).
import Foundation
import HistoryCore
import PresentationUI
import Testing

/// Real ImageIO materialization shares one owner-local native slot; mirror
/// ThumbnailStoreTests' serialization discipline rather than racing sibling
/// stores under the full lane.
@Suite("ThumbnailStore measurement sink", .serialized)
@MainActor
struct ThumbnailMeasurementTests {

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

    /// One fresh measurement file in its own pre-created directory (the
    /// repo's CI-noise rule for on-disk test stores). The caller owns
    /// removing `directory`.
    private func makeMeasurementFile() throws -> (directory: URL, fileURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (
            directory,
            directory.appendingPathComponent("thumb-measure.jsonl")
        )
    }

    /// Decodes the sink's JSONL back through the real `Record` Codable
    /// implementation — the same bytes the running-app journey will parse.
    private func readRecords(
        at fileURL: URL
    ) throws -> [ThumbnailMeasurement.Record] {
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { line in
            try decoder.decode(ThumbnailMeasurement.Record.self, from: line)
        }
    }

    /// A store with the sink injected through the owner-test package seam.
    private func measuredStore(
        history: any ClipboardHistory,
        fileURL: URL,
        maximumEntries: Int = 500,
        maximumDecodedBytes: Int = 64 * 1_048_576
    ) -> ThumbnailStore {
        ThumbnailStore(
            history: history,
            maximumEntries: maximumEntries,
            maximumDecodedBytes: maximumDecodedBytes,
            measurement: ThumbnailMeasurement(fileURL: fileURL)
        )
    }

    // MARK: - Per-flight recording

    /// One prefetch produces one `.started` then one `.completed` with the
    /// exact reference identity, the store's requested pixel size, a
    /// display-side raster sample, and non-negative segment durations.
    @Test func recordsStartedAndCompletedPerFlight() async throws {
        let (directory, fileURL) = try makeMeasurementFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = reference(
            "00000000-0000-0000-0000-0000000000A1",
            version: 3
        )
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = measuredStore(history: history, fileURL: fileURL)

        store.prefetch(item)

        #expect(await pollUntil {
            store.inFlightCount == 0 && store.cachedEntryCount == 1
        })
        let records = try readRecords(at: fileURL)
        #expect(records.count == 2)
        #expect(records.map(\.seq) == [1, 2])
        #expect(records[0].event == .started)
        #expect(records[1].event == .completed)
        #expect(records.allSatisfy { $0.refID == "00000000-0000-0000-0000-0000000000A1" })
        #expect(records.allSatisfy { $0.contentVersion == 3 })
        #expect(records.allSatisfy { $0.pixelsWidth == 72 && $0.pixelsHeight == 72 })
        // The start event carries no segments or outcome.
        #expect(records[0].fetchMs == nil)
        #expect(records[0].rasterMs == nil)
        #expect(records[0].rasterWidth == nil)
        #expect(records[0].outcome == nil)
        // The completed event: hit outcome, display-side raster sample,
        // present and non-negative durations (never threshold-checked).
        #expect(records[1].outcome == .hit)
        #expect(records[1].rasterWidth == 1)
        #expect(records[1].rasterHeight == 1)
        let fetchMs = try #require(records[1].fetchMs)
        let rasterMs = try #require(records[1].rasterMs)
        #expect(fetchMs >= 0)
        #expect(rasterMs >= 0)
        // Monotone sink timestamps (ordering evidence, not wall clock).
        #expect(records[0].monotonicMs <= records[1].monotonicMs)
    }

    // MARK: - Duplicate request recording (G1 numerator input)

    /// After a completed flight, a repeat prefetch records ONE
    /// `.rejectedRetained` and starts no second history request — the
    /// countable proof behind the journey's repeat-request rate.
    @Test func repeatPrefetchRecordsRetainedHitWithoutNewFlight() async throws {
        let (directory, fileURL) = try makeMeasurementFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = reference(
            "00000000-0000-0000-0000-0000000000A2",
            version: 1
        )
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = measuredStore(history: history, fileURL: fileURL)

        store.prefetch(item)
        #expect(await pollUntil { store.imagePixelSize(for: item) != nil })

        store.prefetch(item)

        #expect(await pollUntil { (try? readRecords(at: fileURL))?.count == 3 })
        let records = try readRecords(at: fileURL)
        #expect(records.map(\.event) == [.started, .completed, .rejectedRetained])
        #expect(await history.requestCount(for: item) == 1)
        // A rejection is not a completion: no segments, no outcome.
        #expect(records[2].fetchMs == nil)
        #expect(records[2].outcome == nil)
    }

    /// While a flight is parked, a duplicate prefetch records
    /// `.rejectedInFlight`; releasing the park yields exactly one
    /// `.completed` for the one real flight.
    @Test func inFlightDuplicateRecordsRejectedInFlight() async throws {
        let (directory, fileURL) = try makeMeasurementFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = reference(
            "00000000-0000-0000-0000-0000000000A3",
            version: 1
        )
        let history = PausableThumbnailHistory()
        let store = measuredStore(history: history, fileURL: fileURL)

        store.prefetch(item)
        #expect(await pollUntil {
            guard await history.requestCount == 1 else { return false }
            return store.inFlightCount == 1
        })

        store.prefetch(item)

        #expect(await pollUntil { (try? readRecords(at: fileURL))?.count == 2 })
        var records = try readRecords(at: fileURL)
        #expect(records.map(\.event) == [.started, .rejectedInFlight])
        // Still exactly one flight for the reference.
        #expect(store.inFlightCount == 1)

        #expect(
            await history.completeRequest(for: item, with: .success(fixturePNGData))
        )
        #expect(await pollUntil {
            store.inFlightCount == 0 && (try? readRecords(at: fileURL))?.count == 3
        })
        records = try readRecords(at: fileURL)
        #expect(records.map(\.event) == [.started, .rejectedInFlight, .completed])
        #expect(records[2].outcome == .hit)
        #expect(await history.requestCount == 1)
    }

    // MARK: - Repeat flights (reset / eviction inputs)

    /// `reset()` clears retention, so a re-prefetch produces a SECOND
    /// `.started` + `.completed` pair — the repeat-decode input a purge
    /// actually causes, as opposed to a duplicate request the cache served.
    @Test func resetThenReprefetchProducesSecondCompletedFlight() async throws {
        let (directory, fileURL) = try makeMeasurementFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = reference(
            "00000000-0000-0000-0000-0000000000A4",
            version: 1
        )
        let history = ThumbnailScriptHistory(pngByReference: [item: fixturePNGData])
        let store = measuredStore(history: history, fileURL: fileURL)

        store.prefetch(item)
        #expect(await pollUntil { store.imagePixelSize(for: item) != nil })

        store.reset()
        store.prefetch(item)
        #expect(await pollUntil { store.imagePixelSize(for: item) != nil })

        let records = try readRecords(at: fileURL)
        #expect(records.map(\.event) == [.started, .completed, .started, .completed])
        let completions = records.filter { $0.event == .completed }
        #expect(completions.allSatisfy { $0.outcome == .hit })
        #expect(await history.requestCount(for: item) == 2)
    }

    /// Card 9B on the measurement surface: a flight whose reference was
    /// reset mid-flight still records `.completed`, classified
    /// `.discarded`, with no entry published.
    @Test func lateCompletionAfterResetRecordsDiscarded() async throws {
        let (directory, fileURL) = try makeMeasurementFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = reference(
            "00000000-0000-0000-0000-0000000000A5",
            version: 1
        )
        let history = PausableThumbnailHistory()
        let store = measuredStore(history: history, fileURL: fileURL)

        store.prefetch(item)
        #expect(await pollUntil {
            guard await history.requestCount == 1 else { return false }
            return store.inFlightCount == 1
        })

        store.reset()
        #expect(await history.completeRequest(for: item, with: .success(fixturePNGData)))

        #expect(await pollUntil {
            store.debugFetchCompletionCount == 1
                && (try? readRecords(at: fileURL))?.count == 2
        })
        let records = try readRecords(at: fileURL)
        #expect(records.map(\.event) == [.started, .completed])
        #expect(records[1].outcome == .discarded)
        // History completed, but reset retired the request before display
        // decoding. Record the fetch without inventing a raster sample.
        let fetchMs = try #require(records[1].fetchMs)
        #expect(fetchMs >= 0)
        #expect(records[1].rasterMs == nil)
        #expect(records[1].rasterWidth == nil)
        #expect(records[1].rasterHeight == nil)
        #expect(store.debugFetchCompletionCount == 1)
        #expect(store.debugDiscardedFetchCompletionCount == 1)
        #expect(store.inFlightCount == 0)
        #expect(store.imagePixelSize(for: item) == nil)
        #expect(store.cachedEntryCount == 0)
        #expect(store.cachedDecodedBytes == 0)
    }

    /// The double-bound whole-store reset (ThumbnailStore's insert-then-evict
    /// discipline) is the repeat-decode input at capacity: after the second
    /// completion clears the store, the FIRST reference's next prefetch is a
    /// fresh `.started` — the measurement-side mirror of the bound-crossing
    /// reset behavior.
    @Test func evictionRepeatAfterBoundReset() async throws {
        let (directory, fileURL) = try makeMeasurementFile()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = reference(
            "00000000-0000-0000-0000-0000000000A6",
            version: 1
        )
        let second = reference(
            "00000000-0000-0000-0000-0000000000A7",
            version: 1
        )
        let history = ThumbnailScriptHistory(
            pngByReference: [first: fixturePNGData, second: fixturePNGData]
        )
        let store = measuredStore(
            history: history,
            fileURL: fileURL,
            maximumEntries: 1
        )

        store.prefetch(first)
        store.prefetch(second)
        #expect(await pollUntil {
            guard store.inFlightCount == 0 else { return false }
            guard await history.requestCount(for: first) == 1 else { return false }
            return await history.requestCount(for: second) == 1
        })
        // The second completion crossed the 1-entry bound: whole-store reset.
        #expect(store.cachedEntryCount == 0)

        store.prefetch(first)
        #expect(await pollUntil { store.imagePixelSize(for: first) != nil })

        let records = try readRecords(at: fileURL)
        let refID = first.id.rawValue.uuidString
        let starts = records.filter { $0.refID == refID && $0.event == .started }
        let completions = records.filter {
            $0.refID == refID && $0.event == .completed
        }
        #expect(starts.count == 2)
        #expect(completions.count == 2)
        #expect(completions.allSatisfy { $0.outcome == .hit })
        #expect(await history.requestCount(for: first) == 2)
    }

    // MARK: - Envelope gate

    /// The sink activates only under the DEBUG running-app journey envelope
    /// AND an absolute path — literal environment dictionaries, mirroring
    /// `RunningUITestConfiguration`'s two gates.
    @Test func sinkDisabledWithoutEnvelope() {
        #expect(ThumbnailMeasurement.makeIfRequested(environment: [:]) == nil)
        #expect(
            ThumbnailMeasurement.makeIfRequested(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_THUMB_MEASUREMENT_PATH": "relative-thumb.jsonl",
            ]) == nil
        )
        #expect(
            ThumbnailMeasurement.makeIfRequested(environment: [
                "CLIPY_RUNNING_UI_TEST": "0",
                "CLIPY_UI_TEST_THUMB_MEASUREMENT_PATH": "/tmp/thumb-measure.jsonl",
            ]) == nil
        )
        // The two gates together activate it (creation is lazy: no file is
        // touched until the first record).
        #expect(
            ThumbnailMeasurement.makeIfRequested(environment: [
                "CLIPY_RUNNING_UI_TEST": "1",
                "CLIPY_UI_TEST_THUMB_MEASUREMENT_PATH": "/tmp/thumb-measure.jsonl",
            ]) != nil
        )
    }
}
