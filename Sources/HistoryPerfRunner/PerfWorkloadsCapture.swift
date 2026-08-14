/// §9 workloads 1–5: capture, open, reorder, retention, recent browse.
/// Split out of PerformanceSuite.swift (file-size hygiene); same target, unchanged semantics.
import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Workload 1: capture scales with incoming bytes, not commit shape
//   (§9 bullets 1-2)

func workloadCaptureScaling() async -> [WorkloadFixture] {
    let bullet = "1-2"
    var fixtures: [WorkloadFixture] = []
    let retainedKey = "captureScalesWithRetainedCount"
    let retainedEnvelope = complexityEnvelope(for: retainedKey)
    let smallRetainedCount = retainedEnvelope.measurementScales[0]
    let largeRetainedCount = retainedEnvelope.measurementScales[
        retainedEnvelope.measurementScales.count - 1
    ]

    // 1a: Retained-count envelope — a single capture's candidate generation
    // is proportional to incoming bytes + posting-set/candidate confirmation
    // work, not all Canonical blobs (§9 bullet 2). Capture ALSO performs the
    // sanctioned O(retained scalar) retention-inventory load (05 §7.1 step 5:
    // scalar summaries only, no blob decode), so the ratio sits AT the size
    // span asymptotically; the bound is span × 1.2 so only a super-linear
    // regression (per-item blob decode, O(n²)) breaks the envelope. Capture
    // commit interval excludes fingerprinting (§9 bullet 1); this end-to-end
    // timer includes it, while its exclusion from the serialized interval is
    // proven structurally by the separate preparation actor (05 §6.1).
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
            note: "Envelope: ratio ≤ \(retainedEnvelope.headroomFactor)× the \(retainedEnvelope.scaleSpan)× span. Candidate generation ∝ incoming bytes + posting-set work, not all Canonical blobs (§9 bullet 2); the sanctioned O(retained scalar) retention-inventory load (05 §7.1 step 5) puts the ratio AT the span asymptotically, so only a super-linear regression breaks the envelope. Preparation/fingerprinting off-Authority (05 §6.1)."
        ))
        printResult(retainedKey, bullet, ratio, bound, passed)
    } catch {
        fixtures.append(failureFixture(
            key: retainedKey,
            bullet: bullet,
            error: error
        ))
    }

    // 1b: Body-size scaling — RECORDS byte-proportional scaling (no bound;
    // the expected behavior is linear-in-incoming-bytes per §9 bullet 2).
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
            note: "End-to-end History capture work scales with incoming bytes (§9 bullet 2). Capture fixtures are prebuilt outside the timer, so the measurement covers History preparation/fingerprint/commit rather than harness String/Data construction. Record-only: byte-proportional scaling is expected."
        ))
        printResult("captureScalesWithIncomingBytes", bullet, ratio, nil, true)
    } catch {
        fixtures.append(failureFixture(key: "captureScalesWithIncomingBytes", bullet: bullet, error: error))
    }

    return fixtures
}

// MARK: - Workload 2: warm persistent-store open scales with retained metadata
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
            // ModelContainer, so no best-effort lexical teardown can overlap a
            // measured open.
            // Phase 2: one discarded warmup and all five samples run in fresh
            // child processes. Each child clocks only its public
            // `SwiftDataHistory.open`; parent-observed launch and teardown time
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
            note: "Warm persistent-store opens over retained metadata run in fresh child processes; each child reports only its internal public SwiftDataHistory.open duration, excluding launch and teardown. The sample includes ModelContainer/SQLite open, singleton/startup validation, scalar metadata reads, and Signature Index rebuild (§9 bullet 3; 05 §13). This is not an isolated rebuild, cold-start, or G5 absolute-latency proof. \(envelope.scaleSpan)× items, \(bound)× bound = \(envelope.headroomFactor)× linear headroom.",
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

// MARK: - Workload 3: pin reorder linear in pinned count (§9 bullet 4)

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
            // placePinned action reorders O(pinned count) ordinals (§9 bullet 4).
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
            note: "Pin reorder O(pinned count), bounded by retained count (§9 bullet 4). \(envelope.scaleSpan)× pinned, \(bound)× bound = \(envelope.headroomFactor)× linear headroom."
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: key, bullet: bullet, error: error)]
    }
}

// MARK: - Workload 4: retention and clear linear in retained scalar (§9 bullet 5)

func workloadRetentionAndClear() async -> [WorkloadFixture] {
    let bullet = "5"
    let retentionKey = "retentionMassEviction"
    let retentionEnvelope = complexityEnvelope(for: retentionKey)
    let clearKey = "clearUnpinned"
    let clearEnvelope = complexityEnvelope(for: clearKey)
    // Five timed samples remove the old max-of-two noise rationale. A 6×
    // envelope over a 3× corpus still leaves 2× linear headroom while failing
    // the 9× ratio expected from an accidental quadratic path.
    var fixtures: [WorkloadFixture] = []

    // --- Retention: setRetentionPolicy(1) mass eviction ---
    // §9 bullet 5: O(retained scalar metadata), bounded by retained count.
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
            note: "Retention O(retained scalar metadata), bounded by retained count (§9 bullet 5). Five timed samples; \(retentionEnvelope.scaleSpan)× retained and \(retentionEnvelope.bound)× bound leave \(retentionEnvelope.headroomFactor)× linear headroom while rejecting quadratic scaling."
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
            note: "Clear O(retained scalar metadata), bounded by retained count (§9 bullet 5). Five timed samples; \(clearEnvelope.scaleSpan)× retained and \(clearEnvelope.bound)× bound leave \(clearEnvelope.headroomFactor)× linear headroom while rejecting quadratic scaling."
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

// MARK: - Workload 5: recent browse independent of retained count (§9 bullet 6)

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
            // §9 bullet 6: recent browse materializes at most limit+1 scalar
            // rows after the storage query/order strategy is proved.
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
            note: "Recent browse materializes ≤ limit+1 scalar rows (§9 bullet 6). \(envelope.scaleSpan)× retained, theoretical ratio \(envelope.theoreticalRatio)×, \(bound)× bound = \(envelope.headroomFactor)× headroom for retained-count independence."
        )
        printResult(key, bullet, ratio, bound, passed)
        return [fixture]
    } catch {
        return [failureFixture(key: key, bullet: bullet, error: error)]
    }
}

