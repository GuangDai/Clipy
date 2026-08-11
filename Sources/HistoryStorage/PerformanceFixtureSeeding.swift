/// Package-only bounded fixture seeding for the manual performance-admission
/// runner. This is not a second writer: raw captures still pass through the
/// production ingest preparation and codecs, while `HistoryAuthority` remains
/// the only owner of writable ModelContexts and transaction commits.
///
/// The seam exists because replaying 5,000 public captures is intentionally
/// proportional to the retained scalar inventory on every call. That is the
/// production semantic path, but it makes untimed corpus construction
/// cumulative O(N²) and creates thousands of short-lived SwiftData contexts.
/// Fixture seeding instead uses fixed-size physical batches, keeping transient
/// space O(batch × bounded item bytes) and transaction count O(N / batch).
import Foundation
import HistoryCore

/// Failures specific to the trusted package-only performance fixture seam.
/// They never cross the public `ClipboardHistory` boundary.
package enum PerformanceFixtureSeedError: Error, Sendable, Equatable {
    case invalidRowCount
    case invalidCaptureShape
    case storeNotEmpty
    case capacityExceeded
    case stateChanged
}

/// Structural receipt used by the runner to record exactly what setup did.
package struct PerformanceFixtureSeedReceipt: Sendable, Equatable {
    package let position: ChangePosition
    package let retainedRows: Int
    package let transactionCount: Int
    package let batchSize: Int
}

extension SwiftDataHistory {
    /// A bounded compromise for the 256 KiB admission rows: at most roughly
    /// tens of MiB of prepared/encoded values are live, while 5,000 rows need
    /// only 79 transactions instead of 5,000. Keep this fixed so fixture JSON
    /// can derive and verify the resulting Change Position.
    internal static let performanceFixtureSeedBatchSize = 64

    /// Seeds a new, empty store for performance measurement.
    ///
    /// Every raw value uses the production preparation/projector/fingerprint
    /// and wire codecs. `HistoryAuthority` commits each bounded batch, updates
    /// its real Signature Index, and advances Change Position once per batch.
    /// Callers should finish with one ordinary public capture; that validates
    /// the seeded index and high-retained-count capture path before measuring.
    ///
    /// This is a trusted fixture API for a new, disposable, unexposed store:
    /// captures must have no lineage hint and their Canonical values must be
    /// pairwise distinct and containment-disjoint. The admission generator
    /// constructs exactly that shape. Public capture remains the only path
    /// for arbitrary product input because it runs the Domain dedup planner.
    /// A later batch failure can leave earlier complete batches committed;
    /// callers discard that disposable store instead of retrying in place.
    package func seedPerformanceFixture(
        rowCount: Int,
        makeCapture: @Sendable (Int) -> ClipboardCapture,
        progress: @Sendable (Int) -> Void = { _ in }
    ) async throws -> PerformanceFixtureSeedReceipt {
        guard rowCount > 0,
              rowCount <= HistoryLimits.standard.hardMaximumRetainedItems
        else {
            throw PerformanceFixtureSeedError.invalidRowCount
        }

        var position = try await authority.beginPerformanceFixtureSeed(
            finalRetainedCount: rowCount
        )
        var retainedCount = 0
        var transactionCount = 0
        var batch: [PreparedCaptureBundle] = []
        batch.reserveCapacity(Self.performanceFixtureSeedBatchSize)

        for index in 0..<rowCount {
            batch.append(try await ingestPreparation.prepare(makeCapture(index)))

            let isFull = batch.count == Self.performanceFixtureSeedBatchSize
            let isFinal = index == rowCount - 1
            guard isFull || isFinal else { continue }

            position = try await authority.commitPerformanceFixtureSeedBatch(
                batch,
                expectedPreviousPosition: position,
                expectedRetainedCount: retainedCount
            )
            retainedCount += batch.count
            transactionCount += 1
            progress(retainedCount)
            batch.removeAll(keepingCapacity: true)
        }

        return PerformanceFixtureSeedReceipt(
            position: position,
            retainedRows: retainedCount,
            transactionCount: transactionCount,
            batchSize: Self.performanceFixtureSeedBatchSize
        )
    }
}
