/// HistoryPerfRunner — release-like performance runner for the Part VI §9
/// performance proofs (docs/06-cross-cutting.md §9). Drives the PUBLIC
/// ClipboardHistory surface via the production SwiftDataHistory facade over
/// persistent temporary stores. Each workload records fixture data (medians,
/// complexity ratios, bounds) and exits non-zero if any complexity check
/// fails.
///
/// Acceptance (docs/06-cross-cutting.md §9; docs/roadmap/README.md §3 step 8):
/// the proofs are COMPLEXITY claims, not latency targets — "No numeric latency
/// target in a future PR may be declared satisfied by the current repository's
/// implementation" (§9). Every check bound is at least 1.5× the theoretical
/// linear ratio so a noisy shared runner cannot flake within an order of
/// magnitude. Machine metadata accompanies every fixture (§9: "recorded
/// fixtures and machine metadata").
///
/// Import confinement (Part I §8): the runner imports Foundation, HistoryCore,
/// and HistoryStorage — HistoryStorage was added to the HistoryPerfRunner
/// allowlist because the runner drives the public SwiftDataHistory concrete
/// facade (the release-like public path).
import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Fixture types (docs/06-cross-cutting.md §9)

/// Machine context that must accompany any recorded perf fixture
/// (docs/06-cross-cutting.md §9: "machine metadata").
struct MachineMetadata: Codable {
    let osVersion: String
    let processorCount: Int
    let physicalMemory: UInt64
    let hostName: String
}

/// One recorded workload measurement.
struct WorkloadFixture: Codable {
    /// Deterministic workload key (e.g. captureScalesWithRetainedCount).
    let key: String
    /// The §9 bullet(s) this workload proves (e.g. "1-2").
    let bullet: String
    /// Human-readable size labels, one per measurement point.
    let sizes: [String]
    /// Median milliseconds per size point (1 warmup + 5 timed iterations).
    let mediansMs: [Double]
    /// large/small ratio (nil when N/A).
    let ratio: Double?
    /// Complexity bound (nil = record-only, no check).
    let bound: Double?
    /// Whether the complexity claim holds at this bound.
    let pass: Bool
    /// Human-readable note (spec citations, explanation).
    let note: String
}

/// The complete fixture document written as JSON.
struct PerfFixture: Codable {
    let machine: MachineMetadata
    let swiftVersion: String
    let date: String
    let workloads: [WorkloadFixture]
}

// MARK: - Errors

/// Internal runner errors (not HistoryFailure; never crosses the History seam).
enum PerfError: Error, Sendable {
    case captureUnexpectedOutcome
    case searchNoMatch
}

// MARK: - Measurement helpers

/// Converts a Duration to milliseconds as a Double (sub-ms precision).
func durationToMs(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000.0
         + Double(components.attoseconds) / 1_000_000_000_000_000.0
}

/// Median of an array of doubles (middle of the sorted sequence).
func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

/// Safe ratio (returns infinity when the denominator is zero — a zero-time
/// denominator is suspicious and should fail any finite bound).
func safeRatio(_ numerator: Double, _ denominator: Double) -> Double {
    denominator > 0 ? numerator / denominator : .infinity
}

/// Measures the median milliseconds of an async operation across
/// `warmups + iterations` runs (warmups are discarded). 05 §6.1: capture
/// preparation/fingerprinting is off-Authority; the commit interval is the
/// measured perform/browse/details/paste/thumbnail call.
func measureMedian(
    warmups: Int = 1,
    iterations: Int = 5,
    operation: () async throws -> Void
) async throws -> Double {
    for _ in 0..<warmups {
        try await operation()
    }
    let clock = ContinuousClock()
    var samples: [Double] = []
    for _ in 0..<iterations {
        let start = clock.now
        try await operation()
        samples.append(durationToMs(start.duration(to: clock.now)))
    }
    return median(samples)
}

// MARK: - Store helpers

/// A unique temp store URL (parent directory created upfront to suppress
/// CoreData file-status diagnostics — same pattern as WS tests,
/// Tests/HistoryStorageTests/Support/WalkingSkeletonSupport.swift).
func makeStoreURL(_ label: String) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipy-perf-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: dir,
        withIntermediateDirectories: true
    )
    return dir.appendingPathComponent("store.sqlite")
}

/// Removes the store directory created by `makeStoreURL`.
func removeStoreDir(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

/// Opens the public facade over a persistent temp store with a generous
/// initial retention cap (avoids eviction during population). 05 §2: the
/// initial value is written to the durable singleton for a new store.
func openStore(url: URL, maxUnpinned: Int = 5_000) async throws -> SwiftDataHistory {
    try await SwiftDataHistory.open(
        configuration: HistoryConfiguration(
            persistence: .persistent(storeURL: url),
            initialMaximumUnpinnedItems: maxUnpinned
        )
    )
}

// MARK: - Deterministic capture helpers (no UUID/random in the measurement path)

/// A deterministic raw text capture (index-derived text; capture IDs come from
/// receipts, not from UUID/random in the content path).
func deterministicTextCapture(
    index: Int,
    bodyBytes: Int = 64,
    baseTime: Double = 600_000_000
) -> ClipboardCapture {
    let prefix = "perf-item-\(index)-"
    let padding = String(repeating: "a", count: max(0, bodyBytes - prefix.utf8.count))
    return ClipboardCapture(
        representations: [CapturedRepresentation(
            typeIdentifier: "public.utf8-plain-text",
            bytes: Data((prefix + padding).utf8)
        )],
        origin: CopyOriginObservation(
            sourceApplication: "perf-runner",
            lineageHint: nil
        ),
        observedAt: Date(timeIntervalSinceReferenceDate: baseTime + Double(index))
    )
}

/// Captures one distinct item and returns its reference.
func captureItem(
    _ history: SwiftDataHistory,
    index: Int,
    bodyBytes: Int = 64
) async throws -> HistoryItemReference {
    let receipt = try await history.perform(
        .capture(deterministicTextCapture(index: index, bodyBytes: bodyBytes))
    )
    guard case .committed(let commit) = receipt,
          case .inserted(let ref) = commit.outcome else {
        throw PerfError.captureUnexpectedOutcome
    }
    return ref
}

/// Populates a store with `count` distinct unpinned items (untimed).
func populateItems(
    _ history: SwiftDataHistory,
    count: Int,
    bodyBytes: Int = 64
) async throws {
    for i in 0..<count {
        _ = try await captureItem(history, index: i, bodyBytes: bodyBytes)
    }
}

/// Populates a store and returns the first item's reference for later queries.
func populateAndReturnFirstRef(
    _ history: SwiftDataHistory,
    count: Int,
    bodyBytes: Int = 64
) async throws -> HistoryItemReference {
    let firstRef = try await captureItem(history, index: 0, bodyBytes: bodyBytes)
    for i in 1..<count {
        _ = try await captureItem(history, index: i, bodyBytes: bodyBytes)
    }
    return firstRef
}

// MARK: - Output helpers

/// Prints one summary line for a workload result.
func printResult(_ key: String, _ bullet: String, _ ratio: Double, _ bound: Double?, _ passed: Bool) {
    let status = passed ? "PASS" : "FAIL"
    if let bound {
        print(String(format: "  [%@] %@ (§9 bullet %@): ratio %.2f, bound %.1f", status, key, bullet, ratio, bound))
    } else {
        print(String(format: "  [%@] %@ (§9 bullet %@): ratio %.2f, bound n/a (record-only)", status, key, bullet, ratio))
    }
}

/// Builds a failure fixture for a workload that could not complete.
func failureFixture(key: String, bullet: String, error: Error) -> WorkloadFixture {
    print("  [FAIL] \(key) (§9 bullet \(bullet)): workload error: \(error)")
    return WorkloadFixture(
        key: key,
        bullet: bullet,
        sizes: [],
        mediansMs: [],
        ratio: nil,
        bound: nil,
        pass: false,
        note: "workload error: \(error)"
    )
}

// MARK: - Workload 1: capture scales with incoming bytes, not commit shape
//   (§9 bullets 1-2)

func workloadCaptureScaling() async -> [WorkloadFixture] {
    let bullet = "1-2"
    var fixtures: [WorkloadFixture] = []

    // 1a: Retained-count scaling — a single capture's candidate generation is
    // proportional to incoming bytes + posting-set/candidate confirmation
    // work, not all Canonical blobs (§9 bullet 2). Capture commit interval
    // excludes fingerprinting (§9 bullet 1); preparation is off-Authority by
    // construction (05 §6.1).
    do {
        let smallURL = makeStoreURL("wl1a-small")
        let largeURL = makeStoreURL("wl1a-large")
        defer {
            removeStoreDir(smallURL)
            removeStoreDir(largeURL)
        }

        let smallStore = try await openStore(url: smallURL)
        try await populateItems(smallStore, count: 200)
        let largeStore = try await openStore(url: largeURL)
        try await populateItems(largeStore, count: 2000)

        var smallNext = 200
        var largeNext = 2000
        let smallMedian = try await measureMedian {
            _ = try await captureItem(smallStore, index: smallNext)
            smallNext += 1
        }
        let largeMedian = try await measureMedian {
            _ = try await captureItem(largeStore, index: largeNext)
            largeNext += 1
        }

        let ratio = safeRatio(largeMedian, smallMedian)
        let bound = 4.0
        let passed = ratio <= bound
        fixtures.append(WorkloadFixture(
            key: "captureScalesWithRetainedCount",
            bullet: bullet,
            sizes: ["200-retained", "2000-retained"],
            mediansMs: [smallMedian, largeMedian],
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Capture candidate generation ∝ incoming bytes + posting-set/candidate confirmation, not all Canonical blobs (§9 bullet 2). Preparation/fingerprinting off-Authority by construction (05 §6.1)."
        ))
        printResult("captureScalesWithRetainedCount", bullet, ratio, bound, passed)
    } catch {
        fixtures.append(failureFixture(key: "captureScalesWithRetainedCount", bullet: bullet, error: error))
    }

    // 1b: Body-size scaling — RECORDS byte-proportional scaling (no bound;
    // the expected behavior is linear-in-incoming-bytes per §9 bullet 2).
    do {
        let url = makeStoreURL("wl1b-body")
        defer { removeStoreDir(url) }
        let store = try await openStore(url: url)
        try await populateItems(store, count: 200)

        var next = 200
        let median1KiB = try await measureMedian {
            _ = try await captureItem(store, index: next, bodyBytes: 1_024)
            next += 1
        }
        let median256KiB = try await measureMedian {
            _ = try await captureItem(store, index: next, bodyBytes: 256 * 1_024)
            next += 1
        }
        let ratio = safeRatio(median256KiB, median1KiB)
        fixtures.append(WorkloadFixture(
            key: "captureScalesWithIncomingBytes",
            bullet: bullet,
            sizes: ["1KiB-body", "256KiB-body"],
            mediansMs: [median1KiB, median256KiB],
            ratio: ratio,
            bound: nil,
            pass: true,
            note: "Capture candidate work scales with incoming bytes (§9 bullet 2). Record-only: byte-proportional scaling is expected, not a complexity-envelope check."
        ))
        printResult("captureScalesWithIncomingBytes", bullet, ratio, nil, true)
    } catch {
        fixtures.append(failureFixture(key: "captureScalesWithIncomingBytes", bullet: bullet, error: error))
    }

    return fixtures
}

// MARK: - Workload 2: index rebuild linear in retained signature metadata
//   (§9 bullet 3)

func workloadIndexRebuild() async -> [WorkloadFixture] {
    let bullet = "3"
    let bound = 8.0
    let sizes = [1000, 2500, 5000]

    do {
        var medians: [Double] = []
        for size in sizes {
            let url = makeStoreURL("wl2-index-\(size)")

            // Phase 1: populate the store (untimed) in an inner scope so the
            // facade is released before the measurement opens reopen it.
            do {
                let populateStore = try await openStore(url: url)
                try await populateItems(populateStore, count: size)
            }
            await Task.yield()

            // Phase 2: measure fresh SwiftDataHistory.open calls. Each open
            // rebuilds the Signature Index from durable signature metadata
            // (05 §13). §9 bullet 3: O(retained signature metadata), bounded
            // by 5,000 items. Inner scope + yield lets the previous facade's
            // actors and ModelContainer deallocate between iterations.
            let clock = ContinuousClock()
            // Warmup.
            do {
                _ = try await openStore(url: url)
            }
            await Task.yield()
            // Timed.
            var samples: [Double] = []
            for _ in 0..<5 {
                let elapsed: Duration
                do {
                    let start = clock.now
                    _ = try await openStore(url: url)
                    elapsed = start.duration(to: clock.now)
                }
                samples.append(durationToMs(elapsed))
                await Task.yield()
            }
            medians.append(median(samples))
            removeStoreDir(url)
        }

        let ratio = safeRatio(medians[2], medians[0])
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: "indexRebuildLinearInRetainedSignatureMetadata",
            bullet: bullet,
            sizes: sizes.map { "\($0)-items" },
            mediansMs: medians,
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Index rebuild O(retained signature metadata), bounded by 5,000 items (§9 bullet 3). 5× items, 8× bound = 1.6× linear headroom."
        )
        printResult("indexRebuildLinearInRetainedSignatureMetadata", bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: "indexRebuildLinearInRetainedSignatureMetadata", bullet: bullet, error: error)]
    }
}

// MARK: - Workload 3: pin reorder linear in pinned count (§9 bullet 4)

func workloadPinReorder() async -> [WorkloadFixture] {
    let bullet = "4"
    let bound = 6.0

    do {
        var medians: [(Int, Double)] = []
        for pinnedCount in [50, 200] {
            let url = makeStoreURL("wl3-pin-\(pinnedCount)")
            defer { removeStoreDir(url) }
            let store = try await openStore(url: url)

            // Capture items and pin each at .last (ordinal grows 0..<count).
            var refs: [HistoryItemReference] = []
            for i in 0..<pinnedCount {
                let ref = try await captureItem(store, index: i)
                refs.append(ref)
                _ = try await store.perform(.placePinned(ref.id, at: .last))
            }

            // Measure: move a different item to .first each iteration (always
            // a real reorder — item[0] stays at .first after first pin). The
            // placePinned action reorders O(pinned count) ordinals (§9 bullet 4).
            var idx = 1
            let medianMs = try await measureMedian {
                if idx >= refs.count { idx = 1 }
                _ = try await store.perform(.placePinned(refs[idx].id, at: .first))
                idx += 1
            }
            medians.append((pinnedCount, medianMs))
        }

        let ratio = safeRatio(medians[1].1, medians[0].1)
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: "pinReorderLinearInPinnedCount",
            bullet: bullet,
            sizes: medians.map { "\($0.0)-pinned" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Pin reorder O(pinned count), bounded by retained count (§9 bullet 4). 4× pinned, 6× bound = 1.5× headroom."
        )
        printResult("pinReorderLinearInPinnedCount", bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: "pinReorderLinearInPinnedCount", bullet: bullet, error: error)]
    }
}

// MARK: - Workload 4: retention and clear linear in retained scalar (§9 bullet 5)

func workloadRetentionAndClear() async -> [WorkloadFixture] {
    let bullet = "5"
    let bound = 15.0
    var fixtures: [WorkloadFixture] = []

    // --- Retention: setRetentionPolicy(1) mass eviction ---
    // §9 bullet 5: O(retained scalar metadata), bounded by retained count.
    do {
        var medians: [(Int, Double)] = []
        for count in [200, 2000] {
            var samples: [Double] = []
            let clock = ContinuousClock()
            for iteration in 0..<6 {  // 1 warmup + 5 timed
                let url = makeStoreURL("wl4-retention-\(count)-\(iteration)")
                let store = try await openStore(url: url, maxUnpinned: 5_000)
                try await populateItems(store, count: count)
                let start = clock.now
                _ = try await store.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
                let elapsed = start.duration(to: clock.now)
                if iteration > 0 {  // discard warmup
                    samples.append(durationToMs(elapsed))
                }
                removeStoreDir(url)
            }
            medians.append((count, median(samples)))
        }
        let ratio = safeRatio(medians[1].1, medians[0].1)
        let passed = ratio <= bound
        fixtures.append(WorkloadFixture(
            key: "retentionMassEviction",
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Retention O(retained scalar metadata), bounded by retained count (§9 bullet 5). 10× retained, 15× bound = 1.5× headroom."
        ))
        printResult("retentionMassEviction", bullet, ratio, bound, passed)
    } catch {
        fixtures.append(failureFixture(key: "retentionMassEviction", bullet: bullet, error: error))
    }

    // --- Clear: clear(.unpinned) ---
    do {
        var medians: [(Int, Double)] = []
        for count in [200, 2000] {
            var samples: [Double] = []
            let clock = ContinuousClock()
            for iteration in 0..<6 {
                let url = makeStoreURL("wl4-clear-\(count)-\(iteration)")
                let store = try await openStore(url: url, maxUnpinned: 5_000)
                try await populateItems(store, count: count)
                let start = clock.now
                _ = try await store.perform(.clear(.unpinned))
                let elapsed = start.duration(to: clock.now)
                if iteration > 0 {
                    samples.append(durationToMs(elapsed))
                }
                removeStoreDir(url)
            }
            medians.append((count, median(samples)))
        }
        let ratio = safeRatio(medians[1].1, medians[0].1)
        let passed = ratio <= bound
        fixtures.append(WorkloadFixture(
            key: "clearUnpinned",
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Clear O(retained scalar metadata), bounded by retained count (§9 bullet 5). Same bound as retention."
        ))
        printResult("clearUnpinned", bullet, ratio, bound, passed)
    } catch {
        fixtures.append(failureFixture(key: "clearUnpinned", bullet: bullet, error: error))
    }

    return fixtures
}

// MARK: - Workload 5: recent browse independent of retained count (§9 bullet 6)

func workloadRecentBrowse() async -> [WorkloadFixture] {
    let bullet = "6"
    let bound = 3.0

    do {
        var medians: [(Int, Double)] = []
        for count in [200, 2000] {
            let url = makeStoreURL("wl5-recent-\(count)")
            defer { removeStoreDir(url) }
            let store = try await openStore(url: url)
            try await populateItems(store, count: count)
            // §9 bullet 6: recent browse materializes at most limit+1 scalar
            // rows after the storage query/order strategy is proved.
            let medianMs = try await measureMedian {
                _ = try await store.browse(
                    HistoryBrowseRequest(kind: .recent, limit: 50)
                )
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[1].1, medians[0].1)
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: "recentBrowseIndependentOfRetainedCount",
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Recent browse materializes ≤ limit+1 scalar rows (§9 bullet 6). 10× retained, 3× bound = independent of retained count."
        )
        printResult("recentBrowseIndependentOfRetainedCount", bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: "recentBrowseIndependentOfRetainedCount", bullet: bullet, error: error)]
    }
}

// MARK: - Workload 6: search scans bounded projections linearly (§9 bullet 7)

func workloadSearchScan() async -> [WorkloadFixture] {
    let bullet = "7"

    do {
        var medians: [(Int, Double)] = []
        var allMatched = true
        for count in [200, 2000] {
            let url = makeStoreURL("wl6-search-\(count)")
            defer { removeStoreDir(url) }
            let store = try await openStore(url: url)

            // Populate with deterministic items; embed "needle" in item #100.
            for i in 0..<count {
                let text = (i == 100) ? "needle-in-haystack-\(i)" : "perf-search-\(i)"
                let capture = ClipboardCapture(
                    representations: [CapturedRepresentation(
                        typeIdentifier: "public.utf8-plain-text",
                        bytes: Data(text.utf8)
                    )],
                    origin: CopyOriginObservation(
                        sourceApplication: "perf-runner",
                        lineageHint: nil
                    ),
                    observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(i))
                )
                _ = try await store.perform(.capture(capture))
            }

            // §9 bullet 7: v1 search may scan all bounded scalar projections;
            // no cache is added without G2 evidence.
            let medianMs = try await measureMedian {
                _ = try await store.browse(
                    HistoryBrowseRequest(
                        kind: .search(text: "needle", mode: .exact),
                        limit: 50
                    )
                )
            }
            medians.append((count, medianMs))

            // Verify the expected match is returned (completes + match found).
            let page = try await store.browse(
                HistoryBrowseRequest(
                    kind: .search(text: "needle", mode: .exact),
                    limit: 50
                )
            )
            if !page.rows.contains(where: { $0.title.contains("needle") }) {
                allMatched = false
            }
        }

        let ratio = safeRatio(medians[1].1, medians[0].1)
        let passed = allMatched
        let fixture = WorkloadFixture(
            key: "searchScansBoundedProjectionsLinearly",
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: nil,
            pass: passed,
            note: "v1 search may scan all bounded scalar projections; no cache without G2 evidence (§9 bullet 7). Check: completes and returns expected match. Ratio recorded for observability."
        )
        printResult("searchScansBoundedProjectionsLinearly", bullet, ratio, nil, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: "searchScansBoundedProjectionsLinearly", bullet: bullet, error: error)]
    }
}

// MARK: - Workload 7: detail and paste decode one item (§9 bullet 8)

func workloadDetailAndPaste() async -> [WorkloadFixture] {
    let bullet = "8"
    let bound = 3.0
    var fixtures: [WorkloadFixture] = []

    // --- Details ---
    // §9 bullet 8: detail/paste decode one item's bounded lineage.
    do {
        var medians: [(Int, Double)] = []
        for count in [200, 2000] {
            let url = makeStoreURL("wl7-detail-\(count)")
            defer { removeStoreDir(url) }
            let store = try await openStore(url: url)
            let firstRef = try await populateAndReturnFirstRef(store, count: count)
            let medianMs = try await measureMedian {
                _ = try await store.details(for: firstRef.id)
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[1].1, medians[0].1)
        let passed = ratio <= bound
        fixtures.append(WorkloadFixture(
            key: "detailDecodeOneItem",
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Detail decodes one item's bounded lineage (§9 bullet 8). 10× retained, 3× bound = O(1) in retained count."
        ))
        printResult("detailDecodeOneItem", bullet, ratio, bound, passed)
    } catch {
        fixtures.append(failureFixture(key: "detailDecodeOneItem", bullet: bullet, error: error))
    }

    // --- Paste payload ---
    do {
        var medians: [(Int, Double)] = []
        for count in [200, 2000] {
            let url = makeStoreURL("wl7-paste-\(count)")
            defer { removeStoreDir(url) }
            let store = try await openStore(url: url)
            let firstRef = try await populateAndReturnFirstRef(store, count: count)
            let medianMs = try await measureMedian {
                _ = try await store.pastePayload(for: firstRef.id)
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[1].1, medians[0].1)
        let passed = ratio <= bound
        fixtures.append(WorkloadFixture(
            key: "pastePayloadDecodeOneItem",
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Paste payload decodes one item's current Effective Content (§9 bullet 8). O(1) in retained count."
        ))
        printResult("pastePayloadDecodeOneItem", bullet, ratio, bound, passed)
    } catch {
        fixtures.append(failureFixture(key: "pastePayloadDecodeOneItem", bullet: bullet, error: error))
    }

    return fixtures
}

// MARK: - Workload 8: thumbnail single-flight shares decode (§9 bullet 9)

func workloadThumbnailSingleFlight() async -> [WorkloadFixture] {
    let bullet = "9"

    do {
        let url = makeStoreURL("wl8-thumbnail")
        defer { removeStoreDir(url) }
        let store = try await openStore(url: url)

        // Standard 1×1 transparent PNG (base64) — verbatim from the WS15
        // thumbnail fixture (Tests/HistoryStorageTests/WS15ThumbnailFenceTests.swift).
        let pngBase64 =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        guard let pngData = Data(base64Encoded: pngBase64) else {
            return [failureFixture(key: "thumbnailSingleFlightSharesDecode", bullet: bullet, error: PerfError.searchNoMatch)]
        }
        // Capture a text+png item so the thumbnail path has a valid image source.
        let capture = ClipboardCapture(
            representations: [
                CapturedRepresentation(typeIdentifier: "public.utf8-plain-text", bytes: Data("thumbnail-perf-item".utf8)),
                CapturedRepresentation(typeIdentifier: "public.png", bytes: pngData),
            ],
            origin: CopyOriginObservation(sourceApplication: "perf-runner", lineageHint: nil),
            observedAt: Date(timeIntervalSinceReferenceDate: 600_000_000)
        )
        let receipt = try await store.perform(.capture(capture))
        guard case .committed(let commit) = receipt,
              case .inserted(let ref) = commit.outcome else {
            throw PerfError.captureUnexpectedOutcome
        }
        let pixels = PixelSize(width: 32, height: 32)

        // (a) 8 SEQUENTIAL thumbnail calls — record median per-call time.
        // Warmup.
        _ = try await store.thumbnail(for: ref, pixels: pixels)
        let clock = ContinuousClock()
        var seqSamples: [Double] = []
        for _ in 0..<8 {
            let start = clock.now
            _ = try await store.thumbnail(for: ref, pixels: pixels)
            seqSamples.append(durationToMs(start.duration(to: clock.now)))
        }
        let seqMedian = median(seqSamples)

        // (b) 8 CONCURRENT identical-key calls via async let — record total
        // wall time. §9 bullet 9: thumbnail performs one bounded source fetch
        // and one shared concurrent decode for an identical key. With
        // single-flight, concurrent-8 total ≈ 1 decode; without, ≈ 8 decodes.
        // Concurrent warmup (2 calls).
        async let warmA = store.thumbnail(for: ref, pixels: pixels)
        async let warmB = store.thumbnail(for: ref, pixels: pixels)
        _ = try await warmA
        _ = try await warmB

        let concStart = clock.now
        async let c1 = store.thumbnail(for: ref, pixels: pixels)
        async let c2 = store.thumbnail(for: ref, pixels: pixels)
        async let c3 = store.thumbnail(for: ref, pixels: pixels)
        async let c4 = store.thumbnail(for: ref, pixels: pixels)
        async let c5 = store.thumbnail(for: ref, pixels: pixels)
        async let c6 = store.thumbnail(for: ref, pixels: pixels)
        async let c7 = store.thumbnail(for: ref, pixels: pixels)
        async let c8 = store.thumbnail(for: ref, pixels: pixels)
        _ = try await c1
        _ = try await c2
        _ = try await c3
        _ = try await c4
        _ = try await c5
        _ = try await c6
        _ = try await c7
        _ = try await c8
        let concTotal = durationToMs(concStart.duration(to: clock.now))

        let ratio = safeRatio(concTotal, seqMedian)
        let bound = 4.0
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: "thumbnailSingleFlightSharesDecode",
            bullet: bullet,
            sizes: ["sequential-median", "concurrent-8-total"],
            mediansMs: [seqMedian, concTotal],
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Thumbnail performs one bounded source fetch and one shared decode for an identical key (§9 bullet 9). Concurrent-8 total ≤ 4× sequential-1 median proves a single shared decode, not eight."
        )
        printResult("thumbnailSingleFlightSharesDecode", bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: "thumbnailSingleFlightSharesDecode", bullet: bullet, error: error)]
    }
}

// MARK: - Runner entry point

/// Runs all §9 workloads, writes the fixture JSON, and returns an exit code
/// (0 = all checks passed, 1 = one or more checks failed, 2 = fixture write
/// error). All fixtures are recorded even when a check fails.
func runAll() async -> Int {
    let outputPath = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : "ci-logs/perf-fixtures.json"

    let processInfo = ProcessInfo.processInfo
    let metadata = MachineMetadata(
        osVersion: processInfo.operatingSystemVersionString,
        processorCount: processInfo.processorCount,
        physicalMemory: processInfo.physicalMemory,
        hostName: processInfo.hostName
    )

    #if swift(>=6.2)
    let swiftVersion = "Swift >= 6.2 (swift-tools-version 6.2)"
    #elseif swift(>=6.0)
    let swiftVersion = "Swift >= 6.0"
    #else
    let swiftVersion = "Swift < 6.0"
    #endif

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime]
    let dateString = dateFormatter.string(from: Date())

    print("HistoryPerfRunner: starting Part VI §9 performance proofs")
    print("  machine: \(metadata.hostName) — \(metadata.osVersion)")

    var allFixtures: [WorkloadFixture] = []
    allFixtures.append(contentsOf: await workloadCaptureScaling())
    allFixtures.append(contentsOf: await workloadIndexRebuild())
    allFixtures.append(contentsOf: await workloadPinReorder())
    allFixtures.append(contentsOf: await workloadRetentionAndClear())
    allFixtures.append(contentsOf: await workloadRecentBrowse())
    allFixtures.append(contentsOf: await workloadSearchScan())
    allFixtures.append(contentsOf: await workloadDetailAndPaste())
    allFixtures.append(contentsOf: await workloadThumbnailSingleFlight())

    let perfFixture = PerfFixture(
        machine: metadata,
        swiftVersion: swiftVersion,
        date: dateString,
        workloads: allFixtures
    )

    // Write JSON (prettyPrinted + sortedKeys).
    do {
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(perfFixture)
        try data.write(to: outputURL)
        print("HistoryPerfRunner: wrote fixtures to \(outputPath)")
    } catch {
        FileHandle.standardError.write(Data("HistoryPerfRunner: failed to write fixtures: \(error)\n".utf8))
        return 2
    }

    let failures = allFixtures.filter { !$0.pass }
    if failures.isEmpty {
        print("HistoryPerfRunner: all \(allFixtures.count) workload check(s) PASSED")
        return 0
    } else {
        print("HistoryPerfRunner: \(failures.count)/\(allFixtures.count) workload check(s) FAILED")
        return 1
    }
}

// MARK: - @main

@main
struct PerfRunner {
    static func main() async {
        let exitCode = await runAll()
        exit(Int32(exitCode))
    }
}
