/// SmokeMeasurementTests — the measurement-hook smoke journeys the perf
/// work will hang its budgets on: thumbnail-cache MEMORY EVICTION, corpus
/// MEMORY LOADING, RENDER-SPEED timing capture, and the PREVIEW pane
/// end-to-end. Each test proves the behavioral path against the real
/// composed stack (real `SwiftDataHistory`, real `HistoryViewState`,
/// `ThumbnailStore`, `PreviewPaneState`) and prints its measurements as
/// structured `clipy.smoke.measurement` JSON lines so a later budget lane
/// can mine the CI logs without re-deriving the scenarios.
///
/// Timing discipline follows RenderStormAndMemoryTests: measurements are
/// RECORDED, never asserted — the only assertions are convergence,
/// boundedness with deliberate CI-variance slack, and eviction counts
/// (deterministic: the whole-cache reset makes the entry-count evolution
/// independent of task completion order).
import CoreGraphics
import Darwin
import Foundation
import HistoryCore
import HistoryStorage
import ImageIO
import PresentationUI
import Testing

/// `.serialized`: the RSS probes read PROCESS-wide resident memory, so
/// these tests must not overlap each other (or their seeding phases).
@Suite("Smoke measurement hooks (eviction / loading / render / preview)", .serialized)
struct SmokeMeasurementTests {

    // MARK: - Memory eviction (thumbnail cache)

    /// Memory-eviction smoke (docs/04-coherence.md §9; ThumbnailStore's
    /// whole-cache reset): with the entry ceiling injected at 3, six image
    /// prefetches drive exactly four evictions — the insert sequence
    /// 1,2,3,4→reset→1,2 is order-independent, so completion order of the
    /// fetch tasks cannot flake the assertion. RSS is recorded around the
    /// round for the future memory budget.
    @Test(
        .enabled(
            if: FixtureCatalog.available,
            "requires the clipy-fixtures-v1 tree (CLIPY_FIXTURES_DIR)"
        )
    )
    @MainActor
    func thumbnailCacheEvictionSmoke() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let base = Date(timeIntervalSinceReferenceDate: 700_204_000)
        let imageFixtures: [(path: String, uti: String)] = [
            ("images/photo4k-a.png", "public.png"),
            ("images/photo4k-b.jpg", "public.jpeg"),
            ("images/photo4k-c.tiff", "public.tiff"),
            ("images/photo-1080.bmp", "public.bmp"),
            ("images/huge-8k.png", "public.png"),
            ("images/icon-512.png", "public.png"),
        ]
        var references: [HistoryItemReference] = []
        for (offset, fixture) in imageFixtures.enumerated() {
            let receipt = try await history.perform(.capture(
                ClipboardCapture(
                    representations: [CapturedRepresentation(
                        typeIdentifier: fixture.uti,
                        bytes: try FixtureCatalog.data(fixture.path)
                    )],
                    origin: CopyOriginObservation(
                        sourceApplication: "com.example.evictionsmoke",
                        lineageHint: nil
                    ),
                    observedAt: base.addingTimeInterval(Double(offset))
                )
            ))
            if let reference = ComposedSupport.insertedReference(
                from: receipt, "eviction smoke seed \(fixture.path)"
            ) {
                references.append(reference)
            }
        }
        #expect(references.count == imageFixtures.count)

        let rssBefore = SmokeMemoryProbe.bytes()
        let thumbnails = ThumbnailStore(history: history, maximumEntries: 3)
        for reference in references {
            thumbnails.prefetch(reference)
        }
        let settled = await ComposedSupport.waitFor(timeout: 60) {
            thumbnails.inFlightCount == 0
        }
        #expect(settled, "eviction smoke: every thumbnail fetch settled")
        #expect(
            thumbnails.cachedEntryCount == 2,
            "eviction smoke: 6 inserts against a ceiling of 3 leave exactly 2 entries (4 evicted)"
        )
        SmokeMeasurement.record(
            name: "thumbnailEviction",
            fields: [
                "seededItems": Double(references.count),
                "cacheCeiling": 3,
                "cachedEntriesAfter": Double(thumbnails.cachedEntryCount),
                "rssDeltaBytes": Double(SmokeMemoryProbe.bytes()) - Double(rssBefore),
            ]
        )
    }

    // MARK: - Memory loading (corpus browse)

    /// Memory-loading smoke: 150 distinct ~8 KiB text items (≈1.2 MiB of
    /// stored bodies) paged COMPLETELY through the panel view state, with
    /// RSS recorded before/after — the hook the future "load a large
    /// history into memory" budget hangs on. The growth bound is a
    /// deliberate CI-variance slack, not a budget.
    @Test @MainActor
    func memoryLoadingSmoke() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let base = Date(timeIntervalSinceReferenceDate: 700_204_100)
        let itemCount = 150
        for index in 0..<itemCount {
            let body = "loading-smoke item \(index) "
                + String(repeating: "payload\(index % 10) ", count: 700)
            _ = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    body,
                    observedAt: base.addingTimeInterval(Double(index)),
                    source: "com.example.loadingsmoke"
                )
            ))
        }

        let viewState = HistoryViewState(history: history, pageLimit: 50)
        defer { viewState.deactivate() }
        let rssBefore = SmokeMemoryProbe.bytes()

        viewState.activate()
        let firstPage = await ComposedSupport.waitFor(timeout: 10) {
            viewState.rows.count == 50
        }
        #expect(firstPage, "loading smoke: the first page converges")

        while viewState.hasNextPage {
            let expected = viewState.rows.count + min(50, itemCount - viewState.rows.count)
            viewState.loadNextPage()
            let paged = await ComposedSupport.waitFor(timeout: 10) {
                viewState.rows.count == expected
            }
            #expect(paged, "loading smoke: a page turn converges")
        }
        #expect(viewState.rows.count == itemCount)
        #expect(viewState.failure == nil)

        // Let transient page-turn allocations settle before the RSS read
        // (the RenderStormAndMemoryTests tripwire convention).
        try? await Task.sleep(for: .milliseconds(300))
        let rssAfter = SmokeMemoryProbe.bytes()
        let growth = rssAfter > rssBefore ? rssAfter - rssBefore : 0
        SmokeMeasurement.record(
            name: "memoryLoading",
            fields: [
                "loadedItems": Double(itemCount),
                "rssBeforeBytes": Double(rssBefore),
                "rssAfterBytes": Double(rssAfter),
                "rssGrowthBytes": Double(growth),
            ]
        )
        #expect(
            growth < 512 * 1_048_576,
            "loading smoke: browsing the full corpus grew RSS by \(growth / 1_048_576) MiB (slack bound: 512 MiB)"
        )
    }

    // MARK: - Render speed (record-only timings)

    /// Render-speed smoke: times first-page materialization and every page
    /// turn over a 120-item corpus, then records the samples. Nothing is
    /// asserted beyond convergence — this is the harness the future
    /// render-budget lane reads (Part VI §9 owns hard budgets; the UI-side
    /// NSHostingView frame timing lands with that lane, not here).
    @Test @MainActor
    func renderSpeedSmoke() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let base = Date(timeIntervalSinceReferenceDate: 700_204_200)
        let itemCount = 120
        for index in 0..<itemCount {
            _ = try await history.perform(.capture(
                ComposedSupport.textCapture(
                    "render-speed item \(index)",
                    observedAt: base.addingTimeInterval(Double(index)),
                    source: "com.example.rendersmoke"
                )
            ))
        }

        let viewState = HistoryViewState(history: history, pageLimit: 50)
        defer { viewState.deactivate() }

        let clock = ContinuousClock()
        let activateStart = clock.now
        viewState.activate()
        let firstPage = await ComposedSupport.waitFor(timeout: 10) {
            viewState.rows.count == 50
        }
        let firstPageMs = milliseconds(clock.now - activateStart)
        #expect(firstPage, "render smoke: the first page converges")

        var pageTurnMs: [Double] = []
        while viewState.hasNextPage {
            let expected = viewState.rows.count + min(50, itemCount - viewState.rows.count)
            let turnStart = clock.now
            viewState.loadNextPage()
            let paged = await ComposedSupport.waitFor(timeout: 10) {
                viewState.rows.count == expected
            }
            pageTurnMs.append(milliseconds(clock.now - turnStart))
            #expect(paged, "render smoke: a page turn converges")
        }
        #expect(viewState.rows.count == itemCount)
        #expect(viewState.failure == nil)

        var fields: [String: Double] = [
            "loadedItems": Double(itemCount),
            "firstPageMs": firstPageMs,
        ]
        for (index, sample) in pageTurnMs.enumerated() {
            fields["pageTurnMs.\(index)"] = sample
        }
        SmokeMeasurement.record(name: "renderSpeed", fields: fields)
    }

    // MARK: - Preview pane

    /// Preview smoke: the dwell-driven pane over the REAL facade — a text
    /// item resolves to its Effective-Content text, an image item resolves
    /// to bytes that ImageIO downsamples into a CGImage (the exact decode
    /// `HistoryPreviewView` performs), and the manual toggle suppresses
    /// auto-open until the selection changes.
    @Test(
        .enabled(
            if: FixtureCatalog.available,
            "requires the clipy-fixtures-v1 tree (CLIPY_FIXTURES_DIR)"
        )
    )
    @MainActor
    func previewSmoke() async throws {
        let history = try await ComposedSupport.openMemoryHistory()
        let base = Date(timeIntervalSinceReferenceDate: 700_204_300)
        let textBody = "preview smoke text body — the quick brown fox"
        let textReceipt = try await history.perform(.capture(
            ComposedSupport.textCapture(
                textBody,
                observedAt: base,
                source: "com.example.previewsmoke"
            )
        ))
        let textReference = try #require(
            ComposedSupport.insertedReference(from: textReceipt, "preview smoke text seed")
        )
        let imageReceipt = try await history.perform(.capture(
            ClipboardCapture(
                representations: [CapturedRepresentation(
                    typeIdentifier: "public.png",
                    bytes: try FixtureCatalog.data("images/icon-512.png")
                )],
                origin: CopyOriginObservation(
                    sourceApplication: "com.example.previewsmoke",
                    lineageHint: nil
                ),
                observedAt: base.addingTimeInterval(1)
            )
        ))
        let imageReference = try #require(
            ComposedSupport.insertedReference(from: imageReceipt, "preview smoke image seed")
        )

        let previewState = PreviewPaneState(autoOpenDelay: .milliseconds(20))

        // Text: dwell opens the pane; the Effective Content resolves to the
        // seeded body through the real details read.
        previewState.handleSelectionChange(textReference)
        let textOpened = await ComposedSupport.waitFor(timeout: 5) {
            previewState.isOpen && previewState.previewedItem == textReference
        }
        #expect(textOpened, "preview smoke: the dwell opens the pane on the text item")
        let textDetails = try await history.details(for: textReference.id)
        let textContent = PreviewContent.resolve(effective: textDetails.effective)
        guard case .text(let previewText) = textContent else {
            Issue.record("preview smoke: expected .text, got \(textContent)")
            return
        }
        #expect(previewText.contains(textBody))
        #expect(textDetails.occurrence.lastSource == "com.example.previewsmoke")

        // Image: retargeting dwell swaps the pane to the image item; the
        // resolved bytes downsample through ImageIO exactly as the view
        // does.
        previewState.handleSelectionChange(imageReference)
        let imageOpened = await ComposedSupport.waitFor(timeout: 5) {
            previewState.previewedItem == imageReference
        }
        #expect(imageOpened, "preview smoke: the pane retargets to the image item")
        #expect(previewState.isOpen)
        let imageDetails = try await history.details(for: imageReference.id)
        let imageContent = PreviewContent.resolve(effective: imageDetails.effective)
        guard case .image(let imageBytes) = imageContent else {
            Issue.record("preview smoke: expected .image, got \(imageContent)")
            return
        }
        let downsampled = SmokeImageDecode.downsampled(imageBytes)
        #expect(downsampled != nil, "preview smoke: ImageIO decodes the image preview")

        // Manual toggle closes and suppresses; a selection change re-arms.
        previewState.togglePreview(for: imageReference)
        #expect(!previewState.isOpen)
        previewState.handleSelectionChange(textReference)
        let reopened = await ComposedSupport.waitFor(timeout: 5) {
            previewState.isOpen && previewState.previewedItem == textReference
        }
        #expect(reopened, "preview smoke: the selection change lifts the suppression")

        SmokeMeasurement.record(
            name: "preview",
            fields: [
                "textBytes": Double(textDetails.effective.first?.bytes.count ?? 0),
                "imageBytes": Double(imageBytes.count),
            ]
        )
    }

    // MARK: - Helpers

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1e15
    }
}

/// The smoke suites' structured measurement line: one grep-able
/// `clipy.smoke.measurement` JSON object per record (no "warning"/"error"
/// tokens anywhere — the CI log self-scan fails on those).
private enum SmokeMeasurement {
    static func record(name: String, fields: [String: Double]) {
        var pairs: [String] = [#""name":"\#(name)""#]
        for key in fields.keys.sorted() {
            if let value = fields[key] {
                pairs.append(#""\#(key)":\#(value)"#)
            }
        }
        print("clipy.smoke.measurement {\(pairs.joined(separator: ","))}")
    }
}

/// The file-local resident-memory probe (the RenderStormAndMemoryTests
/// probe duplicated — test files in this target stay self-contained):
/// one `task_info` call returning resident bytes, or 0 on failure.
private enum SmokeMemoryProbe {
    static func bytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size
                / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { taskInfo in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    taskInfo,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }
}

/// The file-local ImageIO downsample twin of
/// `HistoryPreviewView.downsampledImage` (the view's helper is private;
/// the smoke proves the same decode path over the same option set).
private enum SmokeImageDecode {
    static func downsampled(_ bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
