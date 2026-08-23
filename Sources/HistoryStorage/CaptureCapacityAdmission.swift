/// Stamped-plan capacity admission (docs/05-authority-kernel.md §16).
///
/// Core Data returns no out-of-space error on its external-storage path:
/// creating the `_EXTERNAL_DATA` interim file for a `.externalStorage`
/// payload on a full volume raises an uncaught
/// `NSInternalInconsistencyException` ("Can't create
/// externalDataReference interim file : 28") inside
/// `ModelContext.transaction`, terminating the process before
/// `PersistenceErrorClassification.transactionFailure(for:)` can translate
/// anything — observed on the Card 6B physical-ENOSPC runner (dispatch run
/// 32632262141, 2026-08-23; the retained stderr shows the throw site
/// `+[_PFRoutines writePFExternalReferenceDataToInterimFile:]` and the
/// SIGABRT reap status 134). The single writer therefore refuses a stamped
/// plan whose new external payload provably cannot fit, before any durable
/// write. Unreadable capacity facts fail open: admission then changes
/// nothing relative to the pre-admission behavior.
import Foundation
import HistoryCore

internal enum CaptureCapacityAdmission {
    /// Head-room over the encoded external payload total. Components, all
    /// far below this bound: the inline `canonicalSignatureBlob` (at most
    /// ~32 × (512-byte type identifier + fingerprint framing) ≈ 17 KiB),
    /// title/search-body projection columns (limits-bounded), one
    /// `RetainedBytesRow` and HCR/audit payloads (IDs and scalars only —
    /// the HCR `affectedItemsBlob` is not an `.externalStorage` column),
    /// plus SQLite row and WAL dirty-page growth of a one-plan commit.
    internal static let marginBytes: Int64 = 1_048_576

    /// The exact number of new external-storage payload bytes the executor
    /// will hand Core Data for this plan: the already-encoded
    /// `canonicalBlob`/`revisionStateBlob` values carried by `.create`
    /// mutations, and each `revisionStateBlob` rewrite carried by
    /// `.appendRevision`/`.pruneRevisions`. These are the wire-format
    /// (base64-in-JSON) byte counts Core Data externalizes — roughly 4/3 of
    /// the raw clipboard bytes — so summing raw representation bytes here
    /// would under-count by that factor. Mutations that write no external
    /// payload (occurrence, pin, policy, delete) contribute nothing.
    internal static func externalDemandBytes(
        of plan: StampedCommitPlan
    ) -> Int64 {
        var total: Int64 = 0
        for mutation in plan.mutations {
            switch mutation {
            case .create(let item):
                total &+= Int64(clamping: item.canonicalBlob.count)
                total &+= Int64(clamping: item.revisionStateBlob.count)
            case .appendRevision(let update):
                total &+= Int64(clamping: update.revisionStateBlob.count)
            case .pruneRevisions(_, let revisionStateBlob, _):
                total &+= Int64(clamping: revisionStateBlob.count)
            case .updateOccurrence, .setPinOrdinal, .delete,
                    .setRetentionPolicy, .setRetentionPolicies:
                break
            }
        }
        return total
    }

    /// The typed refusal for a plan whose external demand exceeds the
    /// volume's spare capacity, or `nil` when the plan must proceed:
    /// no new external bytes, or a readable capacity with room for the
    /// demand plus the margin.
    internal static func failure(
        demandBytes: Int64,
        availableCapacity: Int64?
    ) -> HistoryFailure? {
        guard demandBytes > 0, let availableCapacity else {
            return nil
        }
        guard availableCapacity - marginBytes >= demandBytes else {
            return .temporarilyUnavailable(.insufficientDiskSpace)
        }
        return nil
    }
}

// MARK: - Test seam (docs/05-authority-kernel.md §16)

extension HistoryAuthority {
    /// Installs (or clears) the fixed spare-capacity witness that overrides
    /// the volume reader for deterministic admission tests. Test seam —
    /// `nil` in production, compiled in always, set via `@testable`; see
    /// `setTransactionFailureInjection` for the failure-forcing sibling
    /// this mirrors. The Release evidence probe runs only the
    /// initializer-injected reader.
    internal func setVolumeAvailableCapacityOverride(_ capacity: Int64?) {
        volumeAvailableCapacityOverride = capacity
    }
}
