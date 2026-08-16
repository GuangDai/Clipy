/// §9 V2-02 R-active retention workloads: the Record 3 measurement halves
/// (`docs/v2/V2-02-retention.md` Record 3) that the projection-maintenance
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
/// R2's budget is twice the steady-state footprint (per item: 64 Canonical +
/// 2 × 32 revision bytes), so the lane always runs its O(retained) scalar
/// sweep (`RET-PERF-1` revise half: RetainedBytesRow fetch + sweep + the
/// revised item's row restamp) yet never retires anything — the measured
/// revise cost is the expansion pass plus the R3 prune, not eviction noise.
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
/// ZERO revisions), so PHASE A's scalar exceedance pass detects nothing and
/// decodes no lineage — the measured construct is exactly the O(retained)
/// scalar pass (inventory + projection columns + planner) plus the one
/// config-row commit. `revisionCountLimit` alternates 100/99 between
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
    // §9 bullets 1-2: the capture commit's composition cost with the
    // expansion pass live. The planning path reads `RetainedBytesRow` scalar
    // columns and decodes ZERO revisionStateBlobs (V2-02 §3.3b/§4.2;
    // RET-PERF-3's adopted-projection posture), so the measured delta over
    // WL1a is the projection-maintenance overhead: the inserted item's row
    // create + the O(retained) scalar sweep + one R2 retirement per capture.
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
            note: "Capture composition with R1+R2 active (V2-02 §4.2/§7; Record 3 RET-PERF-1/RET-PERF-3): the planning path reads RetainedBytesRow scalar columns and decodes zero revisionStateBlobs, so the delta over WL1a is projection maintenance — the inserted item's row create, the O(retained) scalar sweep, and exactly one R2 retirement per capture (budget pinned at the seeded footprint; R1 maxAge 3,600 s §8.3 never fires on the 60-s-fresh seeds). §9 bullets 1-2. \(captureEnvelope.scaleSpan)× retained and \(captureEnvelope.bound)× bound leave \(captureEnvelope.headroomFactor)× linear headroom while rejecting quadratic scaling."
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
    // §9 bullets 1-2: the revise-path expansion reuses the same O(retained)
    // scalar sweep (V2-02 §4.3: RetainedBytesRow fetch + sweep + the revised
    // item's row restamp) and is measured in RET-PERF-1 alongside capture.
    // R2 active (generous budget, retires nothing) keeps the sweep on every
    // commit; R3 count 2 prunes exactly one oldest inactive revision per
    // measured append — steady-state churn over DISTINCT items round-robin,
    // each item's lineage small (2 revisions pre-warm, 2 after each prune).
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
            note: "Revise-path expansion with R2+R3 active (V2-02 §4.3/§7; Record 3 RET-PERF-1 revise half): the revision append runs the same O(retained) scalar sweep as capture — RetainedBytesRow fetch, planner pass, and the revised item's row restamp, zero blob decodes for the non-primary items (RET-PLATFORM-2) — and R3 maxRevisionsPerItem 2 (§8.3) prunes exactly one oldest inactive revision per measured append over distinct round-robin items. R2's twice-footprint budget retires nothing, so eviction noise stays out of the measurement. §9 bullets 1-2. \(reviseEnvelope.scaleSpan)× retained and \(reviseEnvelope.bound)× bound leave \(reviseEnvelope.headroomFactor)× linear headroom while rejecting quadratic scaling."
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
    // §9 bullet 5: the full-sweep scalar pass is O(retained). Exceedance is
    // detected from the RetainedBytesRow projection (V2-02 §3.3b), so the
    // sweep decodes a lineage ONLY for an exceeding item — none here — while
    // the R1/R2 scalar sweep over the inventory and the PHASE-A per-item
    // threshold walk still touch every retained row. A fresh store per
    // iteration (the WL4 mass-eviction discipline) keeps each sample's
    // corpus identical; the alternating in-range value commits every time.
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
            note: "The .setRetentionPolicies full sweep's scalar pass is O(retained), bounded by retained count (§9 bullet 5; V2-02 §4.4, Record 3 RET-PERF-2): the R1/R2 inventory sweep and the R3 per-item threshold walk touch every retained row while PHASE A decodes a lineage only for an EXCEEDING item — the zero-revision seeds exceed nothing (threshold 99/100, §8.3), so zero blob decodes and zero retirements/prunes; the alternating satisfied-but-different value commits the config row every iteration instead of the same-value .unchanged no-op. Five timed samples on a fresh store per iteration; \(sweepEnvelope.scaleSpan)× retained and \(sweepEnvelope.bound)× bound leave \(sweepEnvelope.headroomFactor)× linear headroom while rejecting quadratic scaling."
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
