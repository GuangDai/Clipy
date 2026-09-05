/// Thumbnail pagination and scrolling through the running application.
///
/// The journey seeds 60 distinct real PNG captures through the production
/// pasteboard observer (60 > the 50-row page limit, forcing one real
/// pagination), scrolls the real panel list down to the oldest item and back
/// to the newest, and exports the DEBUG-only in-app measurement sink's
/// JSONL (CLIPY_UI_TEST_THUMB_MEASUREMENT_PATH) out of the app process via
/// XCTAttachment (.keepAlways → app.xcresult → the correctness workflow's
/// ci-result-bundles artifact) plus one prefixed log line (os_log is
/// disabled by OS_ACTIVITY_MODE=disable in CI).
///
/// Completion depends on real traversal and per-item decode coverage, not
/// elapsed scrolling time. JSONL/timing summaries remain diagnostic only;
/// this is not a comparable 60-second G1 performance remeasurement.
import AppKit
import XCTest

final class ThumbnailScrollMeasurementJourneyUITests: XCTestCase {
    /// 60 items: above the 50-row first page, requiring real pagination.
    private static let itemCount = 60

    private var temporaryDirectory: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        // A failed journey aborts before its success-path attachments run,
        // so the raw diagnostic JSONL is
        // attached here, on every path, BEFORE the fixture directory is
        // removed. Otherwise the first failure would destroy exactly the
        // data needed to diagnose it.
        if let temporaryDirectory {
            let measurementURL = temporaryDirectory
                .appendingPathComponent("thumb-measure.jsonl")
            if let raw = try? String(contentsOf: measurementURL, encoding: .utf8),
               !raw.isEmpty {
                let attachment = XCTAttachment(string: raw)
                attachment.name = "thumb-measure-teardown.jsonl"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testScrollingAcrossPagesCompletesEveryThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectory = directory
        let measurementURL = directory
            .appendingPathComponent("thumb-measure.jsonl")

        // Startup deliberately captures the current General pasteboard.
        // Remove the previous journey's value before launching, so a late
        // startup text capture cannot acknowledge the first PNG below.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
        defer { pasteboard.clearContents() }

        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CLIPY_RUNNING_UI_TEST"] = "1"
        app.launchEnvironment["CLIPY_UI_TEST_STORE_PATH"] = directory
            .appendingPathComponent("history.store")
            .path
        app.launchEnvironment["CLIPY_UI_TEST_CAPTURE_ACCESS"] = "allowed"
        // PresentationUI self-reads this key (the launch envelope ignores
        // unknown extra keys); only CLIPY_RUNNING_UI_TEST + an absolute
        // path activate the per-surface DEBUG sink.
        app.launchEnvironment["CLIPY_UI_TEST_THUMB_MEASUREMENT_PATH"] =
            measurementURL.path
        app.launch()
        defer { app.terminate() }

        let panel = app.descendants(matching: .any)["clipy.panel.root"]
        XCTAssertTrue(
            panel.waitForExistence(timeout: 20),
            diagnostic(app, context: "measurement journey panel")
        )
        let rows = historyRows(in: app)
        XCTAssertTrue(
            app.staticTexts["No Clipboard History"].waitForExistence(timeout: 20),
            diagnostic(app, context: "fresh History observation completed empty")
        )
        XCTAssertEqual(rows.count, 0, diagnostic(app, context: "empty capture baseline"))

        // —— Seeding: 60 mutually distinct real PNG captures. The unpinned
        //    lane is newest-first (lastCopiedAt descending), so every capture
        //    surfaces as exactly one NEW row identifier in the first page —
        //    the uniform completion signal both below and above the 50-row
        //    page boundary, where `rows.count` saturates at the page limit.
        let seededIdentifiers = try seedThumbnailItems(Self.itemCount, app: app, rows: rows)
        let oldestIdentifier = try XCTUnwrap(seededIdentifiers.first)
        let newestIdentifier = try XCTUnwrap(seededIdentifiers.last)
        let expectedRefs = Set(seededIdentifiers.map {
            String($0.dropFirst("clipy.history.row.".count))
        })
        XCTAssertEqual(expectedRefs.count, Self.itemCount)

        // —— Scrolling: the panel's history list scroll view. The wheel
        //    increments are deliberately SMALL with real dwell between
        //    them: the list is lazy, and a row only materializes (fires
        //    its onAppear pagination trigger and its thumbnail prefetch)
        //    while it passes through the viewport slowly enough to render.
        //    A single large fling bottomed out page one without ever
        //    materializing the page-two tail (observed on CI: exactly the
        //    50 first-page rows).
        // A left-side text preview also has a scroll view. Select the one
        // containing the History outline, independent of preview placement.
        let scrollView = panel.scrollViews.containing(.outline, identifier: nil).firstMatch
        XCTAssertTrue(
            scrollView.waitForExistence(timeout: 10),
            diagnostic(app, context: "history list scroll view")
        )
        let listCenter = scrollView.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )

        // Seeding can already request all 60 thumbnails while each PNG is
        // newest. Prove pagination separately: the oldest seeded row must
        // enter the History viewport, then the newest must be visible again.
        // A finite number of small-step traversals permits deferred List
        // materialization without spending a fixed performance window.
        let scrollStart = Date()
        var passes = 0
        var reachedOldest = false
        var returnedToNewest = false
        while passes < 3 {
            reachedOldest = scroll(
                listCenter, deltaY: -120, steps: 40,
                untilVisible: rows[oldestIdentifier], in: scrollView
            ) || reachedOldest
            returnedToNewest = scroll(
                listCenter, deltaY: 120, steps: 40,
                untilVisible: rows[newestIdentifier], in: scrollView
            )
            passes += 1
            if reachedOldest, returnedToNewest,
               hasCompleteThumbnailCoverage(at: measurementURL, expectedRefs: expectedRefs) {
                break
            }
        }
        let scrollSeconds = Date().timeIntervalSince(scrollStart)
        XCTAssertTrue(
            reachedOldest,
            diagnostic(app, context: "oldest PNG reached across pagination after \(passes) passes")
        )
        XCTAssertTrue(
            returnedToNewest,
            diagnostic(app, context: "returned to newest PNG after \(passes) passes")
        )

        // —— Quiescence: wait until every started flight for every reference
        //    has its completion (the unstructured prefetch task always runs
        //    to its boundary; only its publication can be fenced).
        XCTAssertTrue(
            waitUntil(timeout: 90) {
                self.hasCompleteThumbnailCoverage(at: measurementURL, expectedRefs: expectedRefs)
            },
            diagnostic(app, context: "all seeded thumbnails displayed and flights completed")
        )

        app.terminate()

        // —— Parse and assert ONLY sampling completeness (no thresholds).
        let records = try parseRecords(at: measurementURL)

        // Sink write ordering: seq strictly increases in file order and the
        // monotone timestamp never moves backwards.
        for (previous, record) in zip(records, records.dropFirst()) {
            XCTAssertTrue(
                record.seq > previous.seq,
                "seq regressed at \(record.seq) after \(previous.seq)"
            )
            XCTAssertTrue(
                record.monotonicMs >= previous.monotonicMs,
                "monotonicMs regressed for seq \(record.seq)"
            )
        }

        // Every specific seeded item was requested at least once.
        XCTAssertEqual(
            Set(records.map(\.refID)),
            expectedRefs,
            "expected \(Self.itemCount) distinct requested references"
        )

        var startsPerRef: [String: Int] = [:]
        var completionsPerRef: [String: Int] = [:]
        var firstCompletedSeqPerRef: [String: Int] = [:]
        for record in records {
            switch record.event {
            case "started":
                startsPerRef[record.refID, default: 0] += 1
            case "completed":
                completionsPerRef[record.refID, default: 0] += 1
                if firstCompletedSeqPerRef[record.refID] == nil {
                    firstCompletedSeqPerRef[record.refID] = record.seq
                }
            default:
                break
            }
        }
        XCTAssertEqual(
            startsPerRef,
            completionsPerRef,
            "every started flight must reach one completion per reference"
        )

        // Duplicate requests are OBSERVED, not required: macOS SwiftUI
        // List may keep off-screen row views alive, in which case a
        // scroll-back never re-runs the row's `.task` and the retained-
        // rejection count is legitimately zero. What IS asserted is the
        // ordering invariant of any rejection that did occur: it must
        // follow that reference's first completion.
        for record in records where record.event == "rejectedRetained" {
            guard let firstCompleted = firstCompletedSeqPerRef[record.refID] else {
                XCTFail(
                    "rejectedRetained for \(record.refID) without a prior completion"
                )
                continue
            }
            XCTAssertTrue(
                record.seq > firstCompleted,
                "rejectedRetained for \(record.refID) precedes its first completion"
            )
        }

        // Every seeded item must have a successful display decode; repeated
        // completions of another item cannot substitute for missing coverage.
        let hits = records.filter {
            $0.event == "completed" && $0.outcome == "hit"
        }
        XCTAssertGreaterThanOrEqual(hits.count, Self.itemCount)
        XCTAssertEqual(Set(hits.map(\.refID)), expectedRefs)
        XCTAssertTrue(
            hits.allSatisfy {
                ($0.rasterWidth ?? 0) > 0 && ($0.rasterHeight ?? 0) > 0
            },
            "hit completions must carry non-empty raster dimension samples"
        )
        let fetchSamples = hits.compactMap(\.fetchMs)
        let rasterSamples = hits.compactMap(\.rasterMs)
        let totalSamples = hits.compactMap { record in
            record.fetchMs.flatMap { fetch in
                record.rasterMs.map { fetch + $0 }
            }
        }
        XCTAssertGreaterThanOrEqual(fetchSamples.count, 20)
        XCTAssertGreaterThanOrEqual(rasterSamples.count, 20)
        XCTAssertGreaterThanOrEqual(totalSamples.count, 20)

        // —— Export (design §2.4): raw JSONL + summary JSON into the result
        //    bundle (kept even on success), plus one prefixed log line for
        //    the ci-logs artifact.
        let rawJSONL = try String(contentsOf: measurementURL, encoding: .utf8)
        attach(rawJSONL, name: "thumb-measurement.jsonl")
        let summary = try measurementSummary(
            records: records,
            scrollSeconds: scrollSeconds
        )
        attach(summary.json, name: "thumb-measurement-summary.json")
        print("CLIPY_THUMB_MEASUREMENT \(summary.line)")
    }

    // MARK: - Seeding

    /// Writes one distinct PNG per index to the general pasteboard and waits
    /// for its capture to surface as a new first-page row. The unpinned lane
    /// is newest-first (lastCopiedAt descending), so every capture replaces
    /// the FIRST row's identifier — one bounded-element read per poll. The
    /// previous poll snapshotted every materialized row
    /// (`allElementsBoundByIndex` over 50+ rows) per evaluation: an O(n) AX
    /// round-trip each, slow enough on a loaded CI runner that a mid-seeding
    /// capture outlasted its timeout (observed: capture 46/60 stall).
    @MainActor
    private func seedThumbnailItems(
        _ count: Int,
        app: XCUIApplication,
        rows: XCUIElementQuery
    ) throws -> [String] {
        // The caller joined the authoritative empty-state presentation.
        // There is no row to query until the first PNG capture arrives.
        var lastFirstRowIdentifier = ""
        var identifiers: [String] = []
        for index in 0..<count {
            let png = try encodedPNG(index: index, totalCount: count)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            XCTAssertTrue(
                item.setData(png, forType: .png),
                diagnostic(app, context: "stage PNG representation \(index)")
            )
            XCTAssertTrue(
                pasteboard.writeObjects([item]),
                diagnostic(app, context: "write pasteboard item \(index)")
            )
            XCTAssertTrue(
                waitUntil(timeout: 20) {
                    let firstRow = rows.element(boundBy: 0)
                    guard firstRow.exists else { return false }
                    let identifier = firstRow.identifier
                    return !identifier.isEmpty
                        && identifier != lastFirstRowIdentifier
                },
                diagnostic(
                    app,
                    context: "capture \(index + 1)/\(count) surfaced a new row"
                )
            )
            lastFirstRowIdentifier = rows.element(boundBy: 0).identifier
            identifiers.append(lastFirstRowIdentifier)
        }
        return identifiers
    }

    /// One real, mutually distinct PNG per index (96×96, per-index hue) so
    /// the two-stage byte-exact dedup keeps every seeded capture a separate
    /// item and every thumbnail decode an independent functional sample.
    @MainActor
    private func encodedPNG(index: Int, totalCount: Int) throws -> Data {
        let edge = 96
        guard
            let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: edge,
                pixelsHigh: edge,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .calibratedRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { throw ThumbnailMeasurementFixtureError.bitmapCreationFailed }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(
            bitmapImageRep: representation
        )
        NSColor(
            calibratedHue: CGFloat(index) / CGFloat(totalCount),
            saturation: 0.9,
            brightness: 0.9,
            alpha: 1
        ).setFill()
        NSBezierPath(
            rect: NSRect(x: 0, y: 0, width: edge, height: edge)
        ).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard
            let png = representation.representation(
                using: .png,
                properties: [:]
            )
        else { throw ThumbnailMeasurementFixtureError.pngEncodingFailed }
        return png
    }

    private enum ThumbnailMeasurementFixtureError: Error {
        case bitmapCreationFailed
        case pngEncodingFailed
    }

    // MARK: - Scrolling

    /// Bounded wheel increments in one direction, clamped by the scroll
    /// view's own bounds; stop when the actual endpoint enters the viewport.
    /// A short dwell lets lazy rows publish before the next small gesture.
    @MainActor
    private func scroll(
        _ coordinate: XCUICoordinate,
        deltaY: CGFloat,
        steps: Int,
        untilVisible row: XCUIElement,
        in scrollView: XCUIElement
    ) -> Bool {
        func endpointIsVisible() -> Bool {
            guard row.exists else { return false }
            let rowFrame = row.frame
            return !rowFrame.isEmpty && scrollView.frame.intersects(rowFrame)
        }
        for _ in 0..<steps {
            if endpointIsVisible() { return true }
            coordinate.scroll(byDeltaX: 0, deltaY: deltaY)
            dwell(0.2)
        }
        return endpointIsVisible()
    }

    /// Spins the run loop for `seconds` without a condition (the wait helper
    /// with an always-false condition waits out its full timeout).
    @MainActor
    private func dwell(_ seconds: TimeInterval) {
        _ = waitUntil(timeout: seconds) { false }
    }

    // MARK: - Measurement file

    /// The journey-side mirror of the sink's record shape. ClipyUITests
    /// lives outside the SwiftPM package, so `package` records are decoded
    /// through this local Codable type instead.
    private struct ThumbMeasuredRecord: Codable {
        var seq: Int
        var monotonicMs: Int64
        var event: String
        var refID: String
        var contentVersion: UInt64
        var pixelsWidth: Int
        var pixelsHeight: Int
        var fetchMs: Double?
        var rasterMs: Double?
        var rasterWidth: Int?
        var rasterHeight: Int?
        var outcome: String?
    }

    /// Each seeded reference must have a successful nonempty display raster,
    /// and every started flight must have completed. Tolerate a partial final
    /// JSONL line while polling; the post-terminate parse remains strict.
    @MainActor
    private func hasCompleteThumbnailCoverage(at url: URL, expectedRefs: Set<String>) -> Bool {
        guard
            let data = try? Data(contentsOf: url),
            !data.isEmpty,
            let records = try? decodeRecords(from: data, strict: false),
            !records.isEmpty
        else { return false }
        let displayedRefs = Set(records.filter {
            $0.event == "completed" && $0.outcome == "hit"
                && ($0.rasterWidth ?? 0) > 0 && ($0.rasterHeight ?? 0) > 0
        }.map(\.refID))
        guard displayedRefs == expectedRefs else { return false }
        var delta: [String: Int] = [:]
        for record in records {
            switch record.event {
            case "started":
                delta[record.refID, default: 0] += 1
            case "completed":
                delta[record.refID, default: 0] -= 1
            default:
                break
            }
        }
        return delta.values.allSatisfy { $0 == 0 }
    }

    /// Strict post-terminate parse: every non-empty line must decode.
    private func parseRecords(at url: URL) throws -> [ThumbMeasuredRecord] {
        let data = try Data(contentsOf: url)
        return try decodeRecords(from: data, strict: true)
    }

    private func decodeRecords(
        from data: Data,
        strict: Bool
    ) throws -> [ThumbMeasuredRecord] {
        let decoder = JSONDecoder()
        let lines = data.split(separator: 0x0A)
        if strict {
            return try lines.map { line in
                try decoder.decode(ThumbMeasuredRecord.self, from: line)
            }
        }
        return lines.compactMap { line in
            try? decoder.decode(ThumbMeasuredRecord.self, from: line)
        }
    }

    // MARK: - Summary export

    /// Content-free diagnostics from this functional traversal. Variable
    /// duration makes rates/timings unsuitable for comparison with the
    /// historical fixed-duration G1 performance journey.
    private func measurementSummary(
        records: [ThumbMeasuredRecord],
        scrollSeconds: TimeInterval
    ) throws -> (json: String, line: String) {
        // JSON value for an optional metric: the number, or an explicit null
        // (`?? NSNull()` alone cannot unify Double? with NSNull).
        func jsonValue(_ value: Double?) -> Any {
            if let value {
                return value
            }
            return NSNull()
        }
        func segment(_ samples: [Double], note: String? = nil) -> [String: Any] {
            let sorted = samples.sorted()
            var summary: [String: Any] = [
                "samples": sorted.count,
                "p50Ms": jsonValue(percentile(sorted, 0.5)),
                "p95Ms": jsonValue(percentile(sorted, 0.95)),
            ]
            if let note {
                summary["note"] = note
            }
            return summary
        }
        func rate(_ numerator: Int, _ denominator: Int) -> Any {
            denominator > 0
                ? Double(numerator) / Double(denominator)
                : NSNull()
        }

        let started = records.filter { $0.event == "started" }.count
        let rejectedRetained = records
            .filter { $0.event == "rejectedRetained" }
            .count
        let rejectedInFlight = records
            .filter { $0.event == "rejectedInFlight" }
            .count
        let completions = records.filter { $0.event == "completed" }
        let outcomeCount = { (outcome: String) in
            completions.filter { $0.outcome == outcome }.count
        }
        let hits = completions.filter { $0.outcome == "hit" }
        let fetchSamples = hits.compactMap(\.fetchMs)
        let rasterSamples = hits.compactMap(\.rasterMs)
        let totalSamples = hits.compactMap { record in
            record.fetchMs.flatMap { fetch in
                record.rasterMs.map { fetch + $0 }
            }
        }
        let distinctCompletedRefs = Set(completions.map(\.refID)).count

        let summary: [String: Any] = [
            "purpose": "Functional thumbnail pagination and scrolling coverage; timings are diagnostic, not a comparable 60-second G1 remeasurement",
            "itemCountSeeded": Self.itemCount,
            "scrollWindowSeconds": (scrollSeconds * 10).rounded() / 10,
            "records": records.count,
            "distinctRefsRequested": Set(records.map(\.refID)).count,
            "events": [
                "started": started,
                "rejectedRetained": rejectedRetained,
                "rejectedInFlight": rejectedInFlight,
                "completed": completions.count,
            ],
            "completedOutcomes": [
                "hit": outcomeCount("hit"),
                "miss": outcomeCount("miss"),
                "failure": outcomeCount("failure"),
                "discarded": outcomeCount("discarded"),
            ],
            "repeatRequestRate": rate(
                rejectedRetained + rejectedInFlight,
                started + rejectedRetained + rejectedInFlight
            ),
            "repeatRequestRateDefinition":
                "(rejectedRetained + rejectedInFlight) / (started + rejectedRetained + rejectedInFlight)",
            "repeatDecodeCompletionRate": rate(
                completions.count - distinctCompletedRefs,
                completions.count
            ),
            "repeatDecodeCompletionRateDefinition":
                "(completed - distinct refs with a completion) / completed",
            "fetchMs": segment(fetchSamples),
            "rasterMs": segment(
                rasterSamples,
                note: "includes single decode-slot queueing (ContentPreview)"
            ),
            "totalMs": segment(totalSamples),
            "p99": "not reported by this functional journey",
            "settledRSS": "not covered by this measurement leaf",
            "fixtureNote": "60 distinct 96x96 PNGs; stop after actual oldest/newest traversal and complete per-item display coverage",
        ]
        let json = String(
            data: try JSONSerialization.data(
                withJSONObject: summary,
                options: [.prettyPrinted, .sortedKeys]
            ),
            encoding: .utf8
        ) ?? "{}"
        let line = String(
            data: try JSONSerialization.data(
                withJSONObject: summary,
                options: [.sortedKeys]
            ),
            encoding: .utf8
        ) ?? "{}"
        return (json, line)
    }

    /// Nearest-rank percentile over ascending samples.
    private func percentile(
        _ sorted: [Double],
        _ fraction: Double
    ) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        let index = min(max(rank - 1, 0), sorted.count - 1)
        return sorted[index]
    }

    /// Raw and summary payloads both persist into the result bundle even
    /// when the test passes (`.keepAlways`), riding the existing
    /// `-resultBundlePath app.xcresult` → ci-result-bundles artifact. The
    /// `.jsonl`/`.json` name suffixes carry the format — the attachment's
    /// uniform type stays the default (the modern SDK exposes it read-only).
    @MainActor
    private func attach(_ payload: String, name: String) {
        let attachment = XCTAttachment(string: payload)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Shared journey helpers (existing journey conventions)

    @MainActor
    private func historyRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "clipy.history.row."
            )
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping () -> Bool
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() },
            object: nil
        )
        return XCTWaiter.wait(
            for: [expectation],
            timeout: timeout
        ) == .completed
    }

    @MainActor
    private func diagnostic(
        _ app: XCUIApplication,
        context: String
    ) -> String {
        "\(context)\n\(app.debugDescription)"
    }
}
