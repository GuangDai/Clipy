/// Package-only bounded fixture seeding for the manual performance-admission
/// runner. This is not a second writer: raw captures still pass through the
/// production ingest preparation and codecs, while `HistoryAuthority` remains
/// the only owner of the writable SQLite connection and transaction commits.
///
/// Fixture seeding uses fixed-size physical batches, keeping transient
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

extension SQLiteHistory {
    /// A bounded compromise for the 256 KiB admission rows: at most roughly
    /// tens of MiB of prepared/encoded values are live, while 5,000 rows need
    /// only 79 transactions instead of 5,000. Keep this fixed so fixture JSON
    /// can derive and verify the resulting Change Position.
    package static let performanceFixtureSeedBatchSize = 64

    /// Seeds a new, empty store for performance measurement.
    ///
    /// Every raw value uses the production preparation/projector/fingerprint
    /// and wire codecs. `HistoryAuthority` commits each bounded batch, writes
    /// its durable signature candidates, and advances Change Position once per batch.
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
        guard rowCount > 0 else {
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

// V2-09 §10: measurement-only capacity, leaving the public product cap intact.
// These disposable stores are opened only by the performance runner; no
// alternate schema, writer, durability policy, or content limits are used.
extension SQLiteHistory {
    package static func openPerformanceFixture(
        storeURL: URL,
        retainedRows: Int
    ) async throws -> SQLiteHistory {
        guard (2...1_000_000).contains(retainedRows) else {
            throw PerformanceFixtureSeedError.invalidRowCount
        }
        let standard = HistoryLimits.standard
        guard let limits = HistoryLimits(
            maximumRepresentationsPerCaptureOrRevision: standard.maximumRepresentationsPerCaptureOrRevision,
            maximumTypeIdentifierUTF8Bytes: standard.maximumTypeIdentifierUTF8Bytes,
            maximumRepresentationBytes: standard.maximumRepresentationBytes,
            maximumCaptureBytes: standard.maximumCaptureBytes,
            maximumProposedRevisionBytes: standard.maximumProposedRevisionBytes,
            maximumRevisionsPerItem: standard.maximumRevisionsPerItem,
            maximumTotalRevisionBytesPerItem: standard.maximumTotalRevisionBytesPerItem,
            hardMaximumRetainedItems: retainedRows,
            userMaximumUnpinnedLowerBound: 1,
            userMaximumUnpinnedUpperBound: retainedRows,
            defaultMaximumUnpinnedItems: min(standard.defaultMaximumUnpinnedItems, retainedRows),
            maximumSourceApplicationObservationUTF8Bytes: standard.maximumSourceApplicationObservationUTF8Bytes,
            maximumStoredTitleUTF8Bytes: standard.maximumStoredTitleUTF8Bytes,
            maximumStoredSearchBodyUTF8Bytes: standard.maximumStoredSearchBodyUTF8Bytes,
            pageRowLimitLowerBound: standard.pageRowLimitRange.lowerBound,
            pageRowLimitUpperBound: standard.pageRowLimitRange.upperBound,
            maximumSearchTermUTF8Bytes: standard.maximumSearchTermUTF8Bytes,
            maximumRegexpPatternCharacters: standard.maximumRegexpPatternCharacters,
            maximumFuzzyQueryCharacters: standard.maximumFuzzyQueryCharacters,
            maximumFuzzyTitleBodyPrefixCharacters: standard.maximumFuzzyTitleBodyPrefixCharacters,
            maximumRegexpTitleBodyPrefixCharacters: standard.maximumRegexpTitleBodyPrefixCharacters,
            maximumBodySearchSnippetCharacters: standard.maximumBodySearchSnippetCharacters,
            thumbnailDimensionLowerBound: standard.thumbnailDimensionRange.lowerBound,
            thumbnailDimensionUpperBound: standard.thumbnailDimensionRange.upperBound,
            maximumEncodedThumbnailBytes: standard.maximumEncodedThumbnailBytes
        ) else {
            throw PerformanceFixtureSeedError.invalidRowCount
        }
        return try await open(
            configuration: HistoryConfiguration(
                persistence: .persistent(storeURL: storeURL),
                initialMaximumUnpinnedItems: retainedRows
            ),
            limits: limits,
            makeCandidateID: { HistoryItemID(rawValue: UUID()) }
        )
    }
}
