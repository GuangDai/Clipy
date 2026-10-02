/// §9 workloads 1–5: capture, open, reorder, retention, recent browse.
/// Split out of PerformanceSuite.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Workload 1: capture timing by retained count and incoming bytes

func workloadCaptureScaling() async -> [WorkloadFixture] {
    let bullet = "1-2"
    var fixtures: [WorkloadFixture] = []
    let retainedKey = "captureScalesWithRetainedCount"
    let retainedEnvelope = complexityEnvelope(for: retainedKey)
    let smallRetainedCount = retainedEnvelope.measurementScales[0]
    let largeRetainedCount = retainedEnvelope.measurementScales[
        retainedEnvelope.measurementScales.count - 1
    ]

    // 1a: time public capture after independently populating each store.
    // Preparation/fingerprinting and commit all contribute to elapsed time;
    // this measurement does not isolate a serialized commit interval.
    do {
        let smallStore = try await openMemoryStore()
        try await populateItems(smallStore, count: smallRetainedCount)
        let largeStore = try await openMemoryStore()
        try await populateItems(largeStore, count: largeRetainedCount)

        var smallNext = smallRetainedCount
        var largeNext = largeRetainedCount
        let smallMedian = try await measureMedian {
            _ = try await captureItem(smallStore, index: smallNext)
            smallNext += 1
        }
        let largeMedian = try await measureMedian {
            _ = try await captureItem(largeStore, index: largeNext)
            largeNext += 1
        }

        let ratio = safeRatio(largeMedian, smallMedian)
        let bound = retainedEnvelope.bound
        let passed = ratio <= bound
        fixtures.append(WorkloadFixture(
            key: retainedKey,
            bullet: bullet,
            sizes: [
                "\(smallRetainedCount)-retained",
                "\(largeRetainedCount)-retained",
            ],
            mediansMs: [smallMedian, largeMedian],
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Public capture timing over short distinct text after populating each retained-row scale. One warmup and five timed inserts include preparation, fingerprinting and commit; each insert must return a new item reference. The \(retainedEnvelope.bound)× bound checks the observed median ratio over the \(retainedEnvelope.scaleSpan)× retained-row span. No internal candidate/retention work or commit-only interval is measured, and the ratio does not establish asymptotic complexity."
        ))
        printResult(retainedKey, bullet, ratio, bound, passed)
    } catch {
        fixtures.append(failureFixture(
            key: retainedKey,
            bullet: bullet,
            error: error
        ))
    }

    // 1b: record capture timings at two prebuilt body sizes without a bound.
    do {
        let store = try await openMemoryStore()
        try await populateItems(store, count: 200)

        let captures1KiB = (200..<206).map {
            deterministicTextCapture(index: $0, bodyBytes: 1_024)
        }
        let captures256KiB = (206..<212).map {
            deterministicTextCapture(index: $0, bodyBytes: 256 * 1_024)
        }
        var next1KiB = 0
        let median1KiB = try await measureMedian(warmups: 1, iterations: 5) {
            _ = try await capturePreparedItem(
                store,
                capture: captures1KiB[next1KiB]
            )
            next1KiB += 1
        }
        var next256KiB = 0
        let median256KiB = try await measureMedian(warmups: 1, iterations: 5) {
            _ = try await capturePreparedItem(
                store,
                capture: captures256KiB[next256KiB]
            )
            next256KiB += 1
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
            note: "Public capture timing for prebuilt 1 KiB and 256 KiB text values. The timer includes History preparation/fingerprint/commit and excludes fixture String/Data construction. Each size has one warmup and five timed inserts. The observed ratio is record-only and does not establish byte-proportional scaling."
        ))
        printResult("captureScalesWithIncomingBytes", bullet, ratio, nil, true)
    } catch {
        fixtures.append(failureFixture(key: "captureScalesWithIncomingBytes", bullet: bullet, error: error))
    }

    return fixtures
}

// MARK: - Workload 2: warm persistent-store open timing by retained count
//   (§9 bullet 3)

func workloadPersistentStoreOpenScaling() async -> [WorkloadFixture] {
    let bullet = "3"
    let key = "persistentStoreOpenScalesWithRetainedMetadata"
    let envelope = complexityEnvelope(for: key)
    let bound = envelope.bound
    let sizes = envelope.measurementScales

    do {
        let executableURL = try performanceRunnerExecutableURL()
        var medians: [Double] = []
        for size in sizes {
            let url = makeStoreURL("wl2-open-\(size)")
            defer { removeStoreDir(url) }

            // Phase 1: a dedicated untimed child populates through the public
            // facade and exits. The parent never owns this workload's
            // database owner, so no best-effort lexical teardown can overlap a
            // measured open.
            // Phase 2: one discarded warmup and all five samples run in fresh
            // child processes. Each child clocks only its public
            // `SQLiteHistory.open`; parent-observed launch and teardown time
            // never enters the sample value.
            let samples = try runPersistentOpenChildSequence(populate: {
                try populatePersistentOpenStoreInChild(
                    executableURL: executableURL,
                    storeURL: url,
                    rowCount: size
                )
            }, measure: {
                try measurePersistentOpenInChild(
                    executableURL: executableURL,
                    storeURL: url
                )
            })
            medians.append(median(samples))
        }

        let ratio = safeRatio(medians[medians.count - 1], medians[0])
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: sizes.map { "\($0)-items" },
            mediansMs: medians,
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Persistent-store opens run in fresh child processes after a separate population child exits. Each child reports only its internal public SQLiteHistory.open duration, excluding process launch and teardown. One discarded warmup and five samples are recorded at each scale. The \(bound)× bound checks the observed median ratio over a \(envelope.scaleSpan)× retained-row span. OS page caches remain warm; these timings establish neither cold-start latency nor asymptotic complexity.",
            medium: ".persistent"
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(
            key: key,
            bullet: bullet,
            error: error
        )]
    }
}

// MARK: - Workload 3: pin reorder timing by pinned count

func workloadPinReorder() async -> [WorkloadFixture] {
    let bullet = "4"
    let key = "pinReorderLinearInPinnedCount"
    let envelope = complexityEnvelope(for: key)
    let bound = envelope.bound

    do {
        var medians: [(Int, Double)] = []
        for pinnedCount in envelope.measurementScales {
            let store = try await openMemoryStore()

            // Capture items and pin each at .last (ordinal grows 0..<count).
            var refs: [HistoryItemReference] = []
            for i in 0..<pinnedCount {
                let ref = try await captureItem(store, index: i)
                refs.append(ref)
                _ = try await store.perform(.placePinned(ref.id, at: .last))
            }

            // Measure: move a different item to .first each iteration (always
            // a real reorder — item[0] stays at .first after first pin). The
            var idx = 1
            let medianMs = try await measureMedian {
                if idx >= refs.count { idx = 1 }
                _ = try await store.perform(.placePinned(refs[idx].id, at: .first))
                idx += 1
            }
            medians.append((pinnedCount, medianMs))
        }

        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-pinned" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Move a different pinned item to first on each invocation, after creating and pinning the selected population. One warmup and five samples are recorded per pinned-row scale. The \(bound)× bound checks the observed median ratio over a \(envelope.scaleSpan)× pinned-row span; this does not establish an asymptotic pin-reorder complexity."
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: key, bullet: bullet, error: error)]
    }
}

// MARK: - Workload 4: mass retention and clear timing by retained count

func workloadRetentionAndClear() async -> [WorkloadFixture] {
    let bullet = "5"
    let retentionKey = "retentionMassEviction"
    let retentionEnvelope = complexityEnvelope(for: retentionKey)
    let clearKey = "clearUnpinned"
    let clearEnvelope = complexityEnvelope(for: clearKey)
    // Every sample gets a fresh corpus; one warmup and five timed operations
    // use the existing observed-ratio bounds.
    var fixtures: [WorkloadFixture] = []

    // --- Retention: setRetentionPolicy(1) mass eviction ---
    do {
        var medians: [(Int, Double)] = []
        for count in retentionEnvelope.measurementScales {
            var samples: [Double] = []
            let clock = ContinuousClock()
            for iteration in 0..<6 {  // 1 warmup + 5 timed
                let store = try await openMemoryStore(maxUnpinned: 5_000)
                try await populateItems(store, count: count)
                let start = clock.now
                _ = try await store.perform(.setRetentionPolicy(maximumUnpinnedItems: 1))
                let elapsed = start.duration(to: clock.now)
                if iteration > 0 {  // discard warmup
                    samples.append(durationToMs(elapsed))
                }
            }
            medians.append((count, median(samples)))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= retentionEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: retentionKey,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: retentionEnvelope.bound,
            pass: passed,
            note: "Set maximumUnpinnedItems to one on a freshly populated unpinned store for each invocation. One warmup and five timed operations are recorded per retained-row scale. The \(retentionEnvelope.bound)× bound checks the observed median ratio over a \(retentionEnvelope.scaleSpan)× span. No internal sweep/sort work is measured, so this ratio does not establish an asymptotic retention complexity."
        ))
        printResult(
            retentionKey,
            bullet,
            ratio,
            retentionEnvelope.bound,
            passed
        )
    } catch {
        fixtures.append(failureFixture(
            key: retentionKey,
            bullet: bullet,
            error: error
        ))
    }

    // --- Clear: clear(.unpinned) ---
    do {
        var medians: [(Int, Double)] = []
        for count in clearEnvelope.measurementScales {
            var samples: [Double] = []
            let clock = ContinuousClock()
            for iteration in 0..<6 {  // 1 warmup + 5 timed
                let store = try await openMemoryStore(maxUnpinned: 5_000)
                try await populateItems(store, count: count)
                let start = clock.now
                _ = try await store.perform(.clear(.unpinned))
                let elapsed = start.duration(to: clock.now)
                if iteration > 0 {
                    samples.append(durationToMs(elapsed))
                }
            }
            medians.append((count, median(samples)))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= clearEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: clearKey,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: clearEnvelope.bound,
            pass: passed,
            note: "Clear all unpinned items from a freshly populated store for each invocation. One warmup and five timed operations are recorded per retained-row scale. The \(clearEnvelope.bound)× bound checks the observed median ratio over a \(clearEnvelope.scaleSpan)× span. No internal sweep/sort work is measured, so this ratio does not establish an asymptotic clear complexity."
        ))
        printResult(clearKey, bullet, ratio, clearEnvelope.bound, passed)
    } catch {
        fixtures.append(failureFixture(
            key: clearKey,
            bullet: bullet,
            error: error
        ))
    }

    return fixtures
}

// MARK: - Workload 5: first-page browse timing by retained count

func workloadRecentBrowse() async -> [WorkloadFixture] {
    let bullet = "6"
    let key = "recentBrowseIndependentOfRetainedCount"
    let envelope = complexityEnvelope(for: key)
    let bound = envelope.bound

    do {
        var medians: [(Int, Double)] = []
        for count in envelope.measurementScales {
            let store = try await openMemoryStore()
            try await populateItems(store, count: count)
            // Time the first recent page at a fixed returned-row limit.
            let medianMs = try await measureMedian {
                _ = try await store.browse(
                    HistoryBrowseRequest(kind: .recent, limit: 50)
                )
            }
            medians.append((count, medianMs))
        }
        let ratio = safeRatio(medians[medians.count - 1].1, medians[0].1)
        let passed = ratio <= bound
        let fixture = WorkloadFixture(
            key: key,
            bullet: bullet,
            sizes: medians.map { "\($0.0)-retained" },
            mediansMs: medians.map { $0.1 },
            ratio: ratio,
            bound: bound,
            pass: passed,
            note: "Time the first recent page with limit 50 after populating each retained-row scale. One warmup and five samples are recorded per scale. The \(bound)× bound checks the observed median ratio over a \(envelope.scaleSpan)× retained-row span. No internal decoded-row count is recorded; these timings do not establish retained-count independence for arbitrary stores."
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: key, bullet: bullet, error: error)]
    }
}
