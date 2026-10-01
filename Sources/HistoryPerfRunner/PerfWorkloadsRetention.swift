/// §9 V2-02 R-active retention workloads: the Record 3 measurement halves
/// (`docs/storage.md` Record 3) that the projection-maintenance
/// push lanes (WL1a capture scaling, WL4 mass eviction) do not cover —
/// capture composition with R1+R2 active (`RET-PERF-1`/`RET-PERF-3`), the
/// revise-path expansion with R2+R3 active (`RET-PERF-1`'s revise half,
/// §4.3), and the `.setRetentionPolicies` scalar sweep (`RET-PERF-2`, §4.4).
/// Same file-size-hygiene split as PerfWorkloadsCapture.swift; same target,
/// and the existing workloads' semantics are unchanged.
///
/// Every policy value below is §8.3-in-range and deterministic: R1 maxAge
/// 3,600 s (admitted range 1 s … 3,650 d), R2 budgets far inside
/// 5,000 × 384 MiB, R3 count thresholds inside 1 … 100. Fixture items are
/// single-representation ASCII (V2-02 §3.2 content-byte measure), so one
/// 64-byte capture contributes exactly 64 Canonical bytes and one 32-byte
/// revision exactly 32 revision bytes — the arithmetic behind each budget.
import Foundation
import HistoryCore
import HistoryStorage

// MARK: - Shared fixture constants and §8.3 policy builders

/// Canonical-body width of every seeded capture (see the file header's
/// content-byte arithmetic).
private let retentionCaptureBodyBytes = 64

/// Revision-body width of every seeded append (see the file header's
/// content-byte arithmetic).
private let retentionReviseBodyBytes = 32

/// R1 maxAge = 3,600 s — §8.3 admits 1 s … 3,650 d. Seeded `observedAt`
/// stamps sit a fixed 60 s behind the wall clock and spread at most one
/// second per item, so the oldest seed is < 60 s + scale + population drift
/// old (≪ 3,600 s): R1 stays active on every sweep (the scalar walk the
/// gate measures) yet never retires anything in-fixture, at the one-time
/// policy-set sweep (the lane's only real-clock read, §6.4) and on every
/// capture-lane pass (`now` = the capture's own `observedAt`, §4.2/DC-28).
private let retentionR1MaxAgeSeconds: TimeInterval = 3_600

/// The seed-stamp origin: 60 s behind the wall clock. One read per store,
/// outside every timed interval; contents stay index-derived (no
/// UUID/random in the measurement path). A fixed 2001-epoch base would
/// instead make R1 an accidental mass retirement once wall-clock time drifts
/// far enough past it (DC-28's accepted exposure, deliberately not reproduced
/// in a fixture).
private func wallClockSeedBase() -> Double {
    Date().timeIntervalSinceReferenceDate - 60
}

/// The R-active capture-lane policy (V2-02 §4.2/§7: capture fires R1+R2
/// only). `seedFootprintBytes` = per-item Canonical bytes × item count, set
/// EXACTLY at the seeded footprint: the store sits at the budget, so every
/// 64-byte measured capture pushes the projected total one item over and R2
/// retires exactly ONE oldest unpinned item — bounded per-commit churn, the
/// steady-state `RET-PERF-1` capture-composition shape.
private func activeCaptureLanePolicies(
    seedFootprintBytes: Int
) -> HistoryRetentionPolicies {
    HistoryRetentionPolicies(
        age: AgeRetention(maxAge: retentionR1MaxAgeSeconds),
        storage: StorageRetention(maxTotalBytes: seedFootprintBytes),
        revisions: nil
    )
}

/// The R-active revise-lane policy (V2-02 §4.3/§7: revise fires R2+R3 only).
/// The storage budget is twice the seeded footprint (per item: 64 Canonical +
/// 2 × 32 revision bytes), keeping these fixtures below that byte limit.
/// This setup does not establish which inventory/planning work a production
/// commit performs; the workload records only its public elapsed time.
/// R3 maxRevisionsPerItem = 2 (§8.3 admits 1 … 100): a pre-warmed item
/// holds exactly 2 revisions, so every measured append makes the post-append
/// count 3 > 2 and prunes exactly ONE oldest inactive revision (§5; D3 keeps
/// the active revision).
private func activeReviseLanePolicies(
    itemFootprintBytes: Int,
    itemCount: Int
) -> HistoryRetentionPolicies {
    HistoryRetentionPolicies(
        age: nil,
        storage: StorageRetention(
            maxTotalBytes: 2 * itemFootprintBytes * itemCount
        ),
        revisions: RevisionRetention(
            maxRevisionsPerItem: 2,
            maxRevisionBytesPerItem: nil
        )
    )
}

/// The satisfied `.setRetentionPolicies` sweep policy (V2-02 §4.4;
/// `RET-PERF-2`). All three lanes active with nothing to do: R1's cutoff
/// spares the 60-s-fresh seeds, R2's budget is twice the seeded footprint,
/// and the R3 count threshold exceeds every stored count (the seeds carry
/// zero revisions). The public operation timer does not attribute cost to
/// inventory reads, planning, decoding or the configuration commit.
/// `revisionCountLimit` alternates 100/99 between
/// iterations (both §8.3-in-range) so the swept VALUE always differs from the
/// persisted one and the sweep commits rather than collapsing to the
/// same-value `.unchanged` no-op.
private func satisfiedSweepPolicies(
    seedFootprintBytes: Int,
    revisionCountLimit: Int
) -> HistoryRetentionPolicies {
    HistoryRetentionPolicies(
        age: AgeRetention(maxAge: retentionR1MaxAgeSeconds),
        storage: StorageRetention(maxTotalBytes: 2 * seedFootprintBytes),
        revisions: RevisionRetention(
            maxRevisionsPerItem: revisionCountLimit,
            maxRevisionBytesPerItem: nil
        )
    )
}

// MARK: - R-active workload: capture composition with R1+R2 active
//   (§9 bullets 1-2; V2-02 §4.2, Record 3 RET-PERF-1/RET-PERF-3)

func workloadActiveRetentionExpansion() async -> [WorkloadFixture] {
    var fixtures: [WorkloadFixture] = []

    // --- Capture with R1+R2 active (RET-PERF-1 capture half / RET-PERF-3) ---
    // Time public capture with age/storage retention configured. A difference
    // from the separate capture workload cannot isolate one internal phase.
    do {
        let captureKey = "retentionExpansionCapture"
        let captureEnvelope = complexityEnvelope(for: captureKey)
        let smallRetainedCount = captureEnvelope.measurementScales[0]
        let largeRetainedCount = captureEnvelope.measurementScales[
            captureEnvelope.measurementScales.count - 1
        ]

        let smallBase = wallClockSeedBase()
        let smallStore = try await openMemoryStore()
        try await populateItems(
            smallStore,
            count: smallRetainedCount,
            baseTime: smallBase
        )
        _ = try await smallStore.perform(.setRetentionPolicies(
            activeCaptureLanePolicies(
                seedFootprintBytes: retentionCaptureBodyBytes * smallRetainedCount
            )
        ))
        let largeBase = wallClockSeedBase()
        let largeStore = try await openMemoryStore()
        try await populateItems(
            largeStore,
            count: largeRetainedCount,
            baseTime: largeBase
        )
        _ = try await largeStore.perform(.setRetentionPolicies(
            activeCaptureLanePolicies(
                seedFootprintBytes: retentionCaptureBodyBytes * largeRetainedCount
            )
        ))

        var smallNext = smallRetainedCount
        let smallMedian = try await measureMedian {
            _ = try await captureItem(
                smallStore,
                index: smallNext,
                baseTime: smallBase
            )
            smallNext += 1
        }
        var largeNext = largeRetainedCount
        let largeMedian = try await measureMedian {
            _ = try await captureItem(
                largeStore,
                index: largeNext,
                baseTime: largeBase
            )
            largeNext += 1
        }

        let captureRatio = safeRatio(largeMedian, smallMedian)
        let capturePassed = captureRatio <= captureEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: captureKey,
            bullet: "1-2",
            sizes: [
                "\(smallRetainedCount)-retained",
                "\(largeRetainedCount)-retained",
            ],
            mediansMs: [smallMedian, largeMedian],
            ratio: captureRatio,
            bound: captureEnvelope.bound,
            pass: capturePassed,
            note: "Capture distinct short text with age/storage retention enabled: maxAge is 3,600 seconds, seeds begin 60 seconds old, and the storage budget equals the seeded payload footprint. One warmup and five inserts are timed per retained-row scale. The \(captureEnvelope.bound)× bound checks the observed median ratio over a \(captureEnvelope.scaleSpan)× span. This timer includes preparation and commit; it records no internal sweep, sort, decode or retirement counts and does not attribute a difference from the separate capture workload to one internal phase."
        ))
        printResult(
            captureKey,
            "1-2",
            captureRatio,
            captureEnvelope.bound,
            capturePassed
        )
    } catch {
        fixtures.append(failureFixture(
            key: "retentionExpansionCapture",
            bullet: "1-2",
            error: error
        ))
    }

    // --- Revise with R2+R3 active (RET-PERF-1 revise half, §4.3) ---
    // Time a third revision append over distinct round-robin items after
    // seeding two revisions each, with a count limit of two and a generous
    // storage budget. Internal planning/decode/prune work is not instrumented.
    do {
        let reviseKey = "retentionExpansionRevise"
        let reviseEnvelope = complexityEnvelope(for: reviseKey)
        var reviseMedians: [(Int, Double)] = []
        for count in reviseEnvelope.measurementScales {
            let store = try await openMemoryStore()
            var refs: [HistoryItemReference] = []
            refs.reserveCapacity(count)
            for i in 0..<count {
                refs.append(try await captureItem(store, index: i))
            }
            // Untimed steady-state construction: two distinct appends per
            // item while the config is still all-disabled (the pure v1
            // revise route — post-append counts 1 and 2 never prune under
            // the later threshold 2 either, §5).
            for i in 0..<count {
                refs[i] = try await reviseItem(
                    store,
                    reference: refs[i],
                    itemIndex: i,
                    appendSequence: 0
                )
                refs[i] = try await reviseItem(
                    store,
                    reference: refs[i],
                    itemIndex: i,
                    appendSequence: 1
                )
            }
            _ = try await store.perform(.setRetentionPolicies(
                activeReviseLanePolicies(
                    itemFootprintBytes: retentionCaptureBodyBytes
                        + 2 * retentionReviseBodyBytes,
                    itemCount: count
                )
            ))
            // Round-robin over distinct items: every measured append is some
            // item's THIRD — post-append count 3 > 2 prunes exactly one
            // oldest inactive revision (the pruned byte total equals the
            // appended one, so the R2 footprint — and the budget margin —
            // stay flat across iterations).
            var nextItem = 0
            let medianMs = try await measureMedian {
                let i = nextItem
                nextItem += 1
                refs[i] = try await reviseItem(
                    store,
                    reference: refs[i],
                    itemIndex: i,
                    appendSequence: 2
                )
            }
            reviseMedians.append((count, medianMs))
        }
        let reviseRatio = safeRatio(
            reviseMedians[reviseMedians.count - 1].1,
            reviseMedians[0].1
        )
        let revisePassed = reviseRatio <= reviseEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: reviseKey,
            bullet: "1-2",
            sizes: reviseMedians.map { "\($0.0)-retained" },
            mediansMs: reviseMedians.map { $0.1 },
            ratio: reviseRatio,
            bound: reviseEnvelope.bound,
            pass: revisePassed,
            note: "Append a third revision to a different item on each invocation after seeding two revisions per item. The per-item revision count limit is two and the storage budget is twice the seeded footprint. One warmup and five appends are timed per retained-row scale. The \(reviseEnvelope.bound)× bound checks the observed median ratio over a \(reviseEnvelope.scaleSpan)× span. No internal sweep, sort, decode or prune counts are recorded, and the timings do not establish asymptotic complexity."
        ))
        printResult(
            reviseKey,
            "1-2",
            reviseRatio,
            reviseEnvelope.bound,
            revisePassed
        )
    } catch {
        fixtures.append(failureFixture(
            key: "retentionExpansionRevise",
            bullet: "1-2",
            error: error
        ))
    }

    // --- .setRetentionPolicies scalar sweep (RET-PERF-2, §4.4) ---
    // A fresh store per invocation keeps the corpus identical. Time the
    // public policy change without assuming which rows an optimized storage
    // path needs to inspect or attributing cost to a specific internal phase.
    do {
        let sweepKey = "retentionPolicySweep"
        let sweepEnvelope = complexityEnvelope(for: sweepKey)
        var sweepMedians: [(Int, Double)] = []
        for count in sweepEnvelope.measurementScales {
            var samples: [Double] = []
            let clock = ContinuousClock()
            for iteration in 0..<6 {  // 1 warmup + 5 timed
                let store = try await openMemoryStore()
                try await populateItems(
                    store,
                    count: count,
                    baseTime: wallClockSeedBase()
                )
                let revisionCountLimit = iteration.isMultiple(of: 2) ? 100 : 99
                let start = clock.now
                _ = try await store.perform(.setRetentionPolicies(
                    satisfiedSweepPolicies(
                        seedFootprintBytes: retentionCaptureBodyBytes * count,
                        revisionCountLimit: revisionCountLimit
                    )
                ))
                let elapsed = start.duration(to: clock.now)
                if iteration > 0 {  // discard warmup
                    samples.append(durationToMs(elapsed))
                }
            }
            sweepMedians.append((count, median(samples)))
        }
        let sweepRatio = safeRatio(
            sweepMedians[sweepMedians.count - 1].1,
            sweepMedians[0].1
        )
        let sweepPassed = sweepRatio <= sweepEnvelope.bound
        fixtures.append(WorkloadFixture(
            key: sweepKey,
            bullet: "5",
            sizes: sweepMedians.map { "\($0.0)-retained" },
            mediansMs: sweepMedians.map { $0.1 },
            ratio: sweepRatio,
            bound: sweepEnvelope.bound,
            pass: sweepPassed,
            note: "Set age/storage/revision policies on a fresh short-text store without revisions for each invocation. The chosen budgets exceed the seeded footprint, and the revision count limit alternates between 99 and 100. One warmup and five policy changes are timed per retained-row scale. The \(sweepEnvelope.bound)× bound checks the observed median ratio over a \(sweepEnvelope.scaleSpan)× span. No internal sweep, sort, decode or pruning work is counted; these timings do not establish asymptotic complexity."
        ))
        printResult(
            sweepKey,
            "5",
            sweepRatio,
            sweepEnvelope.bound,
            sweepPassed
        )
    } catch {
        fixtures.append(failureFixture(
            key: "retentionPolicySweep",
            bullet: "5",
            error: error
        ))
    }

    return fixtures
}
